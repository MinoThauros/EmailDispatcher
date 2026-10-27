import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";

export type MimeMessage = {
  from_email: string;
  from_name: string | null;
  to_email: string;
  reply_to_email: string | null;
  subject: string;
  body_html: string;
  body_text: string | null;
};

export type MimeOptions = {
  /** RFC 8058 one-click unsubscribe target. */
  listUnsubscribeUrl?: string | null;
};

export function createMimeBoundary(): string {
  return `dispatcher_${randomUUID().replaceAll("-", "")}`;
}

// Header injection guard: a header value is always a single line.
function sanitizeHeaderValue(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F]+/g, " ").trim();
}

function hasOnlyAscii(value: string): boolean {
  return /^[\x00-\x7F]*$/.test(value);
}

export function encodeRfc2047(input: string): string {
  const sanitized = sanitizeHeaderValue(input);

  if (hasOnlyAscii(sanitized)) {
    return sanitized;
  }

  return `=?UTF-8?B?${Buffer.from(sanitized, "utf-8").toString("base64")}?=`;
}

/**
 * Rejects anything that is not exactly one plain address, including the
 * header syntax (commas, angle brackets, quotes) that would let a value
 * smuggle in extra recipients.
 */
export function assertSingleEmailAddress(email: string, field: string): void {
  if (!email) {
    throw new Error(`Invalid ${field}: email address is empty`);
  }

  if (/[\x00-\x1F\x7F\s,<>()[\]":;]/.test(email)) {
    throw new Error(`Invalid ${field}: email address contains unsafe header syntax`);
  }

  const parts = email.split("@");

  if (parts.length !== 2) {
    throw new Error(`Invalid ${field}: email address must contain one @`);
  }

  const [localPart, domain] = parts;

  if (
    !localPart ||
    email.length > 254 ||
    localPart.length > 64 ||
    localPart.startsWith(".") ||
    localPart.endsWith(".") ||
    localPart.includes("..") ||
    !/^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$/.test(localPart)
  ) {
    throw new Error(`Invalid ${field}: email local part is malformed`);
  }

  const labels = domain.split(".");

  if (
    domain.length > 253 ||
    labels.length < 2 ||
    labels.some(
      (label) =>
        !label || label.length > 63 || label.startsWith("-") || label.endsWith("-") || !/^[A-Za-z0-9-]+$/.test(label)
    )
  ) {
    throw new Error(`Invalid ${field}: email domain is malformed`);
  }
}

export function assertMessageAddresses(message: MimeMessage): void {
  assertSingleEmailAddress(message.from_email, "from_email");
  assertSingleEmailAddress(message.to_email, "to_email");

  if (message.reply_to_email) {
    assertSingleEmailAddress(message.reply_to_email, "reply_to_email");
  }
}

function formatAddress(email: string, displayName?: string | null): string {
  const name = sanitizeHeaderValue(displayName ?? "");

  if (!name) {
    return `<${email}>`;
  }

  const encoded = hasOnlyAscii(name) ? `"${name.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"` : encodeRfc2047(name);

  return `${encoded} <${email}>`;
}

function decodeHtmlEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#(\d+);/g, (_match, codepoint: string) => {
      const parsed = Number(codepoint);
      return Number.isFinite(parsed) ? String.fromCodePoint(parsed) : "";
    });
}

export function createTextFallbackFromHtml(html: string): string {
  const text = decodeHtmlEntities(
    html
      .replace(/<\s*(script|style)\b[^>]*>[\s\S]*?<\s*\/\s*\1\s*>/gi, "")
      .replace(/<\s*(br|\/p|\/div|\/li|\/h[1-6])\s*\/?>/gi, "\n")
      .replace(/<\s*li\b[^>]*>/gi, "\n- ")
      .replace(/<[^>]+>/g, "")
  )
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return text || " ";
}

function crlf(value: string): string {
  return value.replace(/\r\n|\r|\n/g, "\r\n");
}

export function buildMimeMessage(
  message: MimeMessage,
  boundary: string = createMimeBoundary(),
  options: MimeOptions = {}
): string {
  assertMessageAddresses(message);

  const safeBoundary = boundary.replace(/[^A-Za-z0-9'()+_,./:=?-]/g, "_") || createMimeBoundary();
  const unsubscribeUrl = options.listUnsubscribeUrl ? sanitizeHeaderValue(options.listUnsubscribeUrl) : null;
  const plainText = message.body_text?.trim() ? message.body_text : createTextFallbackFromHtml(message.body_html);

  const headers = [
    `From: ${formatAddress(message.from_email, message.from_name)}`,
    `To: ${formatAddress(message.to_email)}`,
    message.reply_to_email ? `Reply-To: ${formatAddress(message.reply_to_email)}` : null,
    `Subject: ${encodeRfc2047(message.subject)}`,
    unsubscribeUrl ? `List-Unsubscribe: <${unsubscribeUrl}>` : null,
    unsubscribeUrl ? "List-Unsubscribe-Post: List-Unsubscribe=One-Click" : null,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${safeBoundary}"`,
  ].filter((header): header is string => header !== null);

  return [
    ...headers,
    "",
    `--${safeBoundary}`,
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: 8bit",
    "",
    crlf(plainText),
    `--${safeBoundary}`,
    'Content-Type: text/html; charset="UTF-8"',
    "Content-Transfer-Encoding: 8bit",
    "",
    crlf(message.body_html),
    `--${safeBoundary}--`,
    "",
  ].join("\r\n");
}

export function base64UrlEncode(input: string): string {
  return Buffer.from(input, "utf-8").toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Fills the two merge fields campaigns may use in the subject and body:
 * {{first_name}} (falls back to "there") and {{unsubscribe_url}}. Values are
 * HTML-escaped in the HTML part.
 */
export function applyMergeFields(
  message: MimeMessage,
  fields: { firstName: string | null; unsubscribeUrl: string | null }
): MimeMessage {
  const firstName = fields.firstName?.trim() || "there";
  const unsubscribeUrl = fields.unsubscribeUrl ?? "";
  const fill = (value: string, escape: (input: string) => string) =>
    value.replace(/\{\{\s*first_name\s*\}\}/g, escape(firstName)).replace(/\{\{\s*unsubscribe_url\s*\}\}/g, escape(unsubscribeUrl));
  const plain = (input: string) => input;

  return {
    ...message,
    subject: fill(message.subject, plain),
    body_html: fill(message.body_html, escapeHtml),
    body_text: message.body_text === null ? null : fill(message.body_text, plain),
  };
}

export function buildUnsubscribeUrl(base: string | null, token: string | null): string | null {
  if (!base || !token) {
    return null;
  }

  return base.includes("{token}") ? base.replace("{token}", encodeURIComponent(token)) : `${base.replace(/\/+$/, "")}/${token}`;
}
