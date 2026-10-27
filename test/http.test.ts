import assert from "node:assert/strict";
import { test } from "node:test";
import { checkCronAuthorization } from "../src/http";

const request = (authorization?: string) =>
  new Request("https://example.test/api/cron/email-dispatcher", {
    headers: authorization ? { authorization } : {},
  });

test("the cron route fails closed without CRON_SECRET", () => {
  assert.equal(checkCronAuthorization(request("Bearer anything"), "")?.status, 500);
});

test("the cron route requires the exact bearer secret", () => {
  assert.equal(checkCronAuthorization(request(), "s3cret")?.status, 401);
  assert.equal(checkCronAuthorization(request("Bearer wrong"), "s3cret")?.status, 401);
  assert.equal(checkCronAuthorization(request("Bearer s3cret"), "s3cret"), null);
});
