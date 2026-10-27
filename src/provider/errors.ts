const MAX_PROVIDER_ERROR_LENGTH = 512;

const SENSITIVE_KEYS =
  "access_token|refresh_token|client_secret|id_token|lease_token|provider_access_token|provider_refresh_token";

function errorToString(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return typeof error === "string" ? error : "Email provider error";
}

/**
 * Every provider message that reaches the database or a log passes through
 * here first: bearer tokens and token-shaped fields are redacted, whitespace
 * is collapsed, and the result is bounded.
 */
export function sanitizeProviderError(error: unknown): string {
  const message = errorToString(error)
    .replace(/authorization\s*:\s*bearer\s+[^\s,;]+/gi, "Authorization: Bearer [REDACTED]")
    .replace(/bearer\s+[^\s,;]+/gi, "Bearer [REDACTED]")
    .replace(new RegExp(`(${SENSITIVE_KEYS})=([^&\\s]+)`, "gi"), "$1=[REDACTED]")
    .replace(new RegExp(`"(${SENSITIVE_KEYS})"\\s*:\\s*"[^"]*"`, "gi"), '"$1":"[REDACTED]"')
    .replace(new RegExp(`\\b(${SENSITIVE_KEYS})\\s*:\\s*[^\\s,;]+`, "gi"), "$1: [REDACTED]")
    .replace(/\s+/g, " ")
    .trim();

  const bounded =
    message.length <= MAX_PROVIDER_ERROR_LENGTH ? message : `${message.slice(0, MAX_PROVIDER_ERROR_LENGTH - 3)}...`;

  return bounded || "Email provider error";
}
