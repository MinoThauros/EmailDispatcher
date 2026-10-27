import assert from "node:assert/strict";
import { test } from "node:test";
import { executeGmailSend, GMAIL_SEND_ENDPOINT, GOOGLE_TOKEN_ENDPOINT, type Fetcher } from "../src/provider/gmail";
import { createSimulatedFetcher } from "../src/provider/simulated-fetch";
import { credentialRow, fakeRpc, fixedNow, json, providerConfig, recordingReceipts, sendContext } from "./helpers";

function sequenceFetcher(responses: Array<Response | Error>) {
  const requests: Array<{ url: string; authorization: string | null }> = [];
  const fetcher: Fetcher = async (url, init) => {
    requests.push({ url, authorization: new Headers(init?.headers).get("authorization") });
    const next = responses.shift();

    if (!next) {
      throw new Error(`unexpected request to ${url}`);
    }

    if (next instanceof Error) {
      throw next;
    }

    return next;
  };

  return { fetcher, requests };
}

async function send(fetcher: Fetcher, rpcHandlers = {}) {
  const { rpc, calls } = fakeRpc({
    dispatcher_resolve_sender_credentials: () => credentialRow(),
    dispatcher_mark_sender_reauth_required: () => ({ data: null, error: null }),
    dispatcher_store_refreshed_access_token: () => ({ data: null, error: null }),
    ...rpcHandlers,
  });
  const { receipts, recorded } = recordingReceipts();
  const receipt = await executeGmailSend({
    config: providerConfig,
    context: sendContext(),
    createBoundary: () => "boundary",
    fetcher,
    now: fixedNow,
    receipts,
    rpc,
  });

  assert.equal(recorded.length, 1, "exactly one receipt per token");
  return { receipt, calls };
}

test("an accepted send records a sent receipt with the Gmail id", async () => {
  const { fetcher, requests } = sequenceFetcher([json(200, { id: "gmail-1" })]);
  const { receipt } = await send(fetcher);

  assert.deepEqual([receipt.status, receipt.status === "sent" && receipt.provider_message_id], ["sent", "gmail-1"]);
  assert.equal(requests[0].authorization, "Bearer access-1");
});

test("the raw message carries merge fields and the one-click header", async () => {
  let raw = "";
  await send(async (_url, init) => {
    raw = Buffer.from(JSON.parse(String(init?.body)).raw.replaceAll("-", "+").replaceAll("_", "/"), "base64").toString("utf-8");
    return json(200, { id: "gmail-1" });
  });

  assert.match(raw, /^Subject: Hello Ada$/m);
  assert.match(raw, /<p>Hi Ada<\/p>/);
  assert.match(raw, /List-Unsubscribe: <https:\/\/example\.test\/unsubscribe\?token=11111111-1111-1111-1111-111111111111>/);
});

test("a rate limit schedules a retry at Retry-After", async () => {
  const { fetcher } = sequenceFetcher([json(429, { error: { errors: [{ reason: "rateLimitExceeded" }] } }, { "retry-after": "120" })]);
  const { receipt } = await send(fetcher);

  assert.equal(receipt.status, "retry");
  assert.equal(receipt.status === "retry" && receipt.retry_after, "2026-01-01T00:02:00.000Z");
});

test("a 5xx or a timeout is unknown, not a retry", async () => {
  for (const response of [json(500, { error: { errors: [{ reason: "backendError" }] } }), new Error("socket hang up")]) {
    const { fetcher } = sequenceFetcher([response]);
    const { receipt } = await send(fetcher);
    assert.equal(receipt.status, "unknown");
  }
});

test("a 401 refreshes once, stores the new token, and resends", async () => {
  const { fetcher, requests } = sequenceFetcher([
    json(401, { error: { errors: [{ reason: "authError" }] } }),
    json(200, { access_token: "access-2", expires_in: 3600 }),
    json(200, { id: "gmail-2" }),
  ]);
  const { receipt, calls } = await send(fetcher);

  assert.equal(receipt.status, "sent");
  assert.deepEqual(
    requests.map((request) => request.url),
    [GMAIL_SEND_ENDPOINT, GOOGLE_TOKEN_ENDPOINT, GMAIL_SEND_ENDPOINT]
  );
  assert.equal(requests[2].authorization, "Bearer access-2");
  const stored = calls.find((call) => call.fn === "dispatcher_store_refreshed_access_token");
  assert.equal(stored?.args?.p_access_token, "access-2");
});

test("a 401 after refreshing parks the credential instead of looping", async () => {
  const { fetcher } = sequenceFetcher([
    json(401, {}),
    json(200, { access_token: "access-2", expires_in: 3600 }),
    json(401, {}),
  ]);
  const { receipt, calls } = await send(fetcher);

  assert.equal(receipt.status, "failed");
  assert.ok(calls.some((call) => call.fn === "dispatcher_mark_sender_reauth_required"));
});

test("a token another worker already refreshed is reused, not refreshed again", async () => {
  let resolves = 0;
  const { fetcher, requests } = sequenceFetcher([json(401, {}), json(200, { id: "gmail-3" })]);
  const { receipt } = await send(fetcher, {
    dispatcher_resolve_sender_credentials: () => credentialRow((resolves += 1) === 1 ? "access-1" : "access-fresh"),
  });

  assert.equal(receipt.status, "sent");
  assert.deepEqual(requests.map((request) => request.authorization), ["Bearer access-1", "Bearer access-fresh"]);
});

test("invalid_grant parks the credential", async () => {
  const { fetcher } = sequenceFetcher([json(401, {}), json(400, { error: "invalid_grant" })]);
  const { receipt, calls } = await send(fetcher);

  assert.equal(receipt.status, "failed");
  assert.ok(calls.some((call) => call.fn === "dispatcher_mark_sender_reauth_required"));
});

test("an operator-action failure is reported with its category", async () => {
  const { fetcher } = sequenceFetcher([json(403, { error: { errors: [{ reason: "accessNotConfigured" }] } })]);
  const { receipt } = await send(fetcher);

  assert.equal(receipt.status === "failed" && receipt.failure_category, "operator_action");
});

test("a mailbox that changed since admission is not sent from", async () => {
  const { fetcher, requests } = sequenceFetcher([]);
  const { receipt } = await send(fetcher, {
    dispatcher_resolve_sender_credentials: () => ({
      data: [{ ...credentialRow().data[0], provider_email: "someone-else@acme.test" }],
      error: null,
    }),
  });

  assert.equal(receipt.status, "failed");
  assert.equal(requests.length, 0);
});

test("the simulator returns sent, rate-limited, and ambiguous outcomes by rate", async () => {
  const outcomes = [];
  for (const roll of [0.01, 0.06, 0.5]) {
    const { receipt } = await send(
      createSimulatedFetcher({ enabled: true, sendDelayMs: 0, rateLimitRate: 0.05, serverErrorRate: 0.02 }, () => roll)
    );
    outcomes.push(receipt.status);
  }

  assert.deepEqual(outcomes, ["retry", "unknown", "sent"]);
});
