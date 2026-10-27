import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyGmailSendFailure, classifyOAuthRefreshFailure } from "../src/provider/gmail-failures";
import { fixedNow } from "./helpers";

function gmail(status: number, reason: string | null, headers: Record<string, string> = {}) {
  const body = reason ? JSON.stringify({ error: { code: status, message: "m", errors: [{ reason }] } }) : "";
  return classifyGmailSendFailure({
    bodyText: body,
    defaultRetryDelaySeconds: 300,
    now: fixedNow,
    response: { status, headers: new Headers(headers) },
  });
}

function oauth(status: number, body: Record<string, string>) {
  return classifyOAuthRefreshFailure({
    bodyText: JSON.stringify(body),
    defaultRetryDelaySeconds: 300,
    now: fixedNow,
    response: { status, headers: new Headers() },
  });
}

test("401 is refreshable on the first send and reauth after a refresh", () => {
  assert.equal(gmail(401, "authError").category, "auth_refreshable");
  assert.equal(
    classifyGmailSendFailure({
      authFailureCategory: "reauth_required",
      bodyText: "",
      defaultRetryDelaySeconds: 300,
      now: fixedNow,
      response: { status: 401, headers: new Headers() },
    }).category,
    "reauth_required"
  );
});

test("rate limits honor Retry-After seconds and dates", () => {
  assert.deepEqual(
    [gmail(429, null, { "retry-after": "42" }).retryAfterSeconds, gmail(429, null).retryAfterSeconds],
    [42, 300]
  );
  assert.equal(gmail(403, "userRateLimitExceeded").category, "rate_limited");
  assert.equal(gmail(429, null, { "retry-after": "Thu, 01 Jan 2026 00:01:00 GMT" }).retryAfterSeconds, 60);
});

test("5xx and timeouts are ambiguous, never retried as if unsent", () => {
  assert.equal(gmail(500, "backendError").category, "provider_ambiguous");
  assert.equal(gmail(503, null).category, "provider_ambiguous");
  assert.equal(gmail(408, null).category, "provider_ambiguous");
});

test("integration problems need an operator; bad messages are rejected", () => {
  assert.equal(gmail(403, "accessNotConfigured").category, "operator_action");
  assert.equal(gmail(403, "domainPolicy").category, "operator_action");
  assert.equal(gmail(403, "insufficientPermissions").category, "reauth_required");
  assert.equal(gmail(400, "invalidArgument").category, "provider_rejected");
});

test("OAuth refresh failures map to reauth, retry, or operator action", () => {
  assert.equal(oauth(400, { error: "invalid_grant" }).category, "reauth_required");
  assert.equal(oauth(400, { error: "invalid_grant", error_subtype: "invalid_rapt" }).reason, "invalid_grant.invalid_rapt");
  assert.equal(oauth(503, { error: "temporarily_unavailable" }).category, "provider_ambiguous");
  assert.equal(oauth(401, { error: "invalid_client" }).category, "operator_action");
});
