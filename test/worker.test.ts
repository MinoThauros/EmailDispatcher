import assert from "node:assert/strict";
import { test } from "node:test";
import { drainQueue, runWorkerCycle } from "../src/worker";
import type { WorkerConfig } from "../src/config";
import { fakeRpc } from "./helpers";

const config: WorkerConfig = {
  drainBudgetMs: 10_000,
  shutdownMarginMs: 1_000,
  recipientLeaseSeconds: 300,
  senderMinIntervalSeconds: 180,
  tokenCandidateLimit: 50,
};

function issuedRow(n: number) {
  return {
    state: "token_issued",
    next_eligible_at: null,
    worker_id: "w",
    sender_id: "s",
    sender_min_interval_seconds: 600,
    campaign_contact_id: `cc-${n}`,
    campaign_id: "c",
    contact_id: `ct-${n}`,
    to_email: `r${n}@example.com`,
    recipient_first_name: null,
    lease_token: `lease-${n}`,
    send_token_id: `tok-${n}`,
    attempt_id: `att-${n}`,
    attempt_no: 1,
    subject: "s",
    preview_text: null,
    body_html: "<p>x</p>",
    body_text: null,
    from_name: null,
    from_email: "ops@acme.test",
    reply_to_email: null,
    unsubscribe_token: null,
  };
}

test("sweeps expired leases first, then spends tokens one at a time until no_work", async () => {
  let claims = 0;
  const { rpc, calls } = fakeRpc({
    dispatcher_mark_expired_sends_unknown: () => ({ data: 0, error: null }),
    dispatcher_claim_next_send_token: () => {
      claims += 1;
      return {
        data: [claims <= 2 ? issuedRow(claims) : { ...issuedRow(0), state: "no_work", campaign_contact_id: null }],
        error: null,
      };
    },
  });

  const spent: string[] = [];
  let inFlight = 0;
  const tokens = await drainQueue({
    config,
    context: { workerId: "w", drainDeadlineMs: Infinity, shutdownDeadlineMs: Infinity },
    rpc,
    handleTokenIssued: async (context) => {
      inFlight += 1;
      assert.equal(inFlight, 1, "never two sends at once in one worker");
      spent.push(context.lease_token);
      await new Promise((resolve) => setTimeout(resolve, 5));
      inFlight -= 1;
    },
  });

  assert.equal(tokens, 2);
  assert.deepEqual(spent, ["lease-1", "lease-2"]);
  assert.equal(calls[0].fn, "dispatcher_mark_expired_sends_unknown");
  assert.equal(calls.filter((call) => call.fn === "dispatcher_claim_next_send_token").length, 3);
});

test("stops claiming at the shutdown deadline", async () => {
  let clock = 0;
  const { rpc } = fakeRpc({
    dispatcher_mark_expired_sends_unknown: () => ({ data: 0, error: null }),
    dispatcher_claim_next_send_token: () => ({ data: [issuedRow(1)], error: null }),
  });

  const tokens = await drainQueue({
    config,
    context: { workerId: "w", drainDeadlineMs: 100, shutdownDeadlineMs: 50 },
    rpc,
    now: () => clock,
    handleTokenIssued: async () => {
      clock += 20;
    },
  });

  assert.equal(tokens, 3, "claims at t=0, 20, 40; none at 60");
});

test("a malformed token_issued row is refused instead of sent", async () => {
  const { rpc } = fakeRpc({
    dispatcher_mark_expired_sends_unknown: () => ({ data: 0, error: null }),
    dispatcher_claim_next_send_token: () => ({ data: [{ ...issuedRow(1), lease_token: null }], error: null }),
  });

  await assert.rejects(
    drainQueue({
      config,
      context: { workerId: "w", drainDeadlineMs: Infinity, shutdownDeadlineMs: Infinity },
      rpc,
      handleTokenIssued: async () => assert.fail("must not send"),
    }),
    /without lease_token/
  );
});

test("runWorkerCycle reports the stop reason against its budget", async () => {
  let clock = 0;
  const summary = await runWorkerCycle({
    config,
    now: () => clock,
    createWorkerId: () => "worker-x",
    drain: async (context) => {
      assert.equal(context.shutdownDeadlineMs, 9_000);
      clock = 9_500;
      return 4;
    },
  });

  assert.deepEqual(summary, { workerId: "worker-x", stopReason: "shutdown_margin_reached", elapsedMs: 9_500, tokensIssued: 4 });
});
