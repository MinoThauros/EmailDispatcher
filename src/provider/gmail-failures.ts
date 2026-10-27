import { sanitizeProviderError } from "./errors";

// Gmail API error reasons, lowercased. Anything not listed is provider_rejected.
const RATE_LIMIT_REASONS = new Set([
  "globallimitexceeded",
  "quotaexceeded",
  "ratelimitexceeded",
  "sharingratelimitexceeded",
  "toomanyrequests",
  "userratelimitexceeded",
]);
const REAUTH_REASONS = new Set(["autherror", "invalidcredentials", "insufficientpermissions"]);
const OPERATOR_ACTION_REASONS = new Set([
  "accessnotconfigured",
  "apidisabled",
  "billingnotenabled",
  "dailylimitexceeded",
  "dailylimitexceededunreg",
  "domainpolicy",
  "servicedisabled",
]);
const AMBIGUOUS_REASONS = new Set(["backenderror", "internalerror"]);
const OAUTH_REAUTH_SUBTYPES = new Set(["invalid_rapt"]);

/**
 * What a failure means for the recipient:
 * - auth_refreshable: the access token expired; refresh once and resend.
 * - reauth_required: the sender must reconnect; the credential is parked.
 * - rate_limited: retry after the provider's Retry-After.
 * - provider_rejected: this email will never send as-is; fail it.
 * - provider_ambiguous: the provider may or may not have sent it; send_unknown.
 * - operator_action: a human must fix the integration; safety-pause the scope.
 */
export type GmailFailureCategory =
  | "auth_refreshable"
  | "reauth_required"
  | "rate_limited"
  | "provider_rejected"
  | "provider_ambiguous"
  | "operator_action";

export type GmailFailureClassification = {
  category: GmailFailureCategory;
  providerMessage: string | null;
  reason: string;
  retryAfterSeconds: number | null;
  statusCode: number;
};

type FailureResponse = Pick<Response, "headers" | "status">;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJsonRecord(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = text.trim() ? JSON.parse(text) : null;
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export function stringField(record: Record<string, unknown> | null | undefined, key: string): string | null {
  const value = record?.[key];
  return typeof value === "string" && value.trim() ? value : null;
}

function normalizedReason(value: string | null, statusCode: number): string {
  const reason = sanitizeProviderError(value ?? "")
    .replace(/[^A-Za-z0-9._:-]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 120);

  return reason || `http_${statusCode}`;
}

function reasonKey(value: string | null, statusCode: number): string {
  return normalizedReason(value, statusCode).toLowerCase();
}

function classify(
  category: GmailFailureCategory,
  statusCode: number,
  reason: string | null,
  providerMessage: string | null,
  retryAfterSeconds: number | null = null
): GmailFailureClassification {
  return {
    category,
    providerMessage: providerMessage ? sanitizeProviderError(providerMessage) : null,
    reason: normalizedReason(reason, statusCode),
    retryAfterSeconds,
    statusCode,
  };
}

// Retry-After may be delta-seconds or an HTTP date.
function retryAfterSeconds(headers: Headers, now: () => Date, fallback: number): number {
  const retryAfter = headers.get("retry-after")?.trim();

  if (!retryAfter) {
    return fallback;
  }

  const seconds = Number(retryAfter);

  if (Number.isFinite(seconds) && seconds > 0) {
    return Math.ceil(seconds);
  }

  const retryAtMs = Date.parse(retryAfter);

  return Number.isNaN(retryAtMs) ? fallback : Math.max(1, Math.ceil((retryAtMs - now().getTime()) / 1000));
}

function parseGmailError(bodyText: string): { message: string | null; reason: string | null } {
  const body = parseJsonRecord(bodyText);
  const errorValue = body?.error;

  if (typeof errorValue === "string") {
    return { message: stringField(body, "message"), reason: errorValue };
  }

  const error = isRecord(errorValue) ? errorValue : null;
  const errors = error?.errors;
  const first = Array.isArray(errors) && isRecord(errors[0]) ? errors[0] : null;

  return {
    message: stringField(first, "message") ?? stringField(error, "message") ?? stringField(body, "message"),
    reason: stringField(first, "reason"),
  };
}

export function classifyGmailSendFailure({
  authFailureCategory = "auth_refreshable",
  bodyText,
  defaultRetryDelaySeconds,
  now,
  response,
}: {
  // After one refresh-and-resend, a second 401 means reconnect, not refresh again.
  authFailureCategory?: "auth_refreshable" | "reauth_required";
  bodyText: string;
  defaultRetryDelaySeconds: number;
  now: () => Date;
  response: FailureResponse;
}): GmailFailureClassification {
  const { message, reason } = parseGmailError(bodyText);
  const statusCode = response.status;
  const key = reasonKey(reason, statusCode);

  if (statusCode === 401) {
    return classify(authFailureCategory, statusCode, reason, message);
  }

  if (statusCode === 429 || (statusCode === 403 && RATE_LIMIT_REASONS.has(key))) {
    return classify(
      "rate_limited",
      statusCode,
      reason,
      message,
      retryAfterSeconds(response.headers, now, defaultRetryDelaySeconds)
    );
  }

  if (statusCode === 408 || statusCode >= 500 || AMBIGUOUS_REASONS.has(key)) {
    return classify("provider_ambiguous", statusCode, reason, message);
  }

  if (OPERATOR_ACTION_REASONS.has(key)) {
    return classify("operator_action", statusCode, reason, message);
  }

  if (REAUTH_REASONS.has(key)) {
    return classify("reauth_required", statusCode, reason, message);
  }

  return classify("provider_rejected", statusCode, reason, message);
}

export function classifyOAuthRefreshFailure({
  bodyText,
  defaultRetryDelaySeconds,
  now,
  response,
}: {
  bodyText: string;
  defaultRetryDelaySeconds: number;
  now: () => Date;
  response: FailureResponse;
}): GmailFailureClassification {
  const body = parseJsonRecord(bodyText);
  const error = stringField(body, "error");
  const subtype = stringField(body, "error_subtype");
  const description = stringField(body, "error_description");
  const statusCode = response.status;
  const reason = error && subtype ? `${error}.${subtype}` : error ?? subtype ?? `http_${statusCode}`;

  if (statusCode === 429) {
    return classify(
      "rate_limited",
      statusCode,
      reason,
      description,
      retryAfterSeconds(response.headers, now, defaultRetryDelaySeconds)
    );
  }

  if (reasonKey(error, statusCode) === "invalid_grant" || OAUTH_REAUTH_SUBTYPES.has(reasonKey(subtype, statusCode))) {
    return classify("reauth_required", statusCode, reason, description);
  }

  if (statusCode >= 500 || reasonKey(error, statusCode) === "temporarily_unavailable") {
    return classify("provider_ambiguous", statusCode, reason, description, defaultRetryDelaySeconds);
  }

  // Any other 4xx from the token endpoint is our OAuth client's problem.
  return classify(
    statusCode >= 400 && statusCode < 500 ? "operator_action" : "provider_rejected",
    statusCode,
    reason,
    description
  );
}
