import assert from "node:assert/strict";
import { test } from "node:test";
import {
  applyMergeFields,
  assertSingleEmailAddress,
  buildMimeMessage,
  buildUnsubscribeUrl,
  createTextFallbackFromHtml,
  encodeRfc2047,
} from "../src/provider/mime";
import { sanitizeProviderError } from "../src/provider/errors";
import { sendContext } from "./helpers";

test("headers are single-line and non-ASCII is RFC 2047 encoded", () => {
  const mime = buildMimeMessage(
    sendContext({ subject: "Café\r\nBcc: victim@example.com", from_name: "Équipe" }),
    "b",
    { listUnsubscribeUrl: "https://example.test/u/1" }
  );
  const headerBlock = mime.split("\r\n\r\n")[0];

  assert.doesNotMatch(headerBlock, /^Bcc:/m, "a CRLF in the subject cannot inject a header");
  assert.match(headerBlock, /^Subject: =\?UTF-8\?B\?/m);
  assert.match(headerBlock, /^From: =\?UTF-8\?B\?.+\?= <ops@acme\.test>$/m);
  assert.match(headerBlock, /^List-Unsubscribe: <https:\/\/example\.test\/u\/1>$/m);
  assert.match(headerBlock, /^List-Unsubscribe-Post: List-Unsubscribe=One-Click$/m);
  assert.equal(encodeRfc2047("plain"), "plain");
});

test("addresses that could smuggle recipients are rejected", () => {
  for (const bad of ["a@b.com, c@d.com", "<a@b.com>", "a@b", "a b@c.com", "a..b@c.com", "a@-b.com"]) {
    assert.throws(() => assertSingleEmailAddress(bad, "to_email"), /Invalid to_email/, bad);
  }
  assert.doesNotThrow(() => assertSingleEmailAddress("first.last+tag@example.co.uk", "to_email"));
});

test("merge fields are filled and HTML-escaped", () => {
  const message = applyMergeFields(sendContext({ recipient_first_name: "<Ada>" }), {
    firstName: "<Ada>",
    unsubscribeUrl: "https://example.test/u?token=1&x=2",
  });

  assert.equal(
    message.body_html,
    '<p>Hi &lt;Ada&gt;</p><a href="https://example.test/u?token=1&amp;x=2">Unsubscribe</a>'
  );
  assert.equal(applyMergeFields(sendContext(), { firstName: null, unsubscribeUrl: null }).body_html.startsWith("<p>Hi there</p>"), true);
});

test("unsubscribe URLs support a {token} placeholder or a path segment", () => {
  assert.equal(buildUnsubscribeUrl("https://x.test/u?token={token}", "abc"), "https://x.test/u?token=abc");
  assert.equal(buildUnsubscribeUrl("https://x.test/u/", "abc"), "https://x.test/u/abc");
  assert.equal(buildUnsubscribeUrl(null, "abc"), null);
});

test("a plain-text part is derived from HTML when none is given", () => {
  assert.equal(createTextFallbackFromHtml("<style>p{}</style><p>One</p><ul><li>Two</li></ul>"), "One\n\n- Two");
});

test("provider errors never carry tokens", () => {
  const cleaned = sanitizeProviderError('Authorization: Bearer ya29.abc refresh_token=xyz {"access_token":"secret"}');
  assert.doesNotMatch(cleaned, /ya29|xyz|secret/);
});
