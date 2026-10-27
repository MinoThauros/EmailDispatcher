import type { ProviderConfig } from "../config";
import { log } from "../log";
import { formatRpcError, type RpcClient } from "../rpc";
import type {
  FailedReceipt,
  ProviderReceipt,
  ReceiptClient,
  ResolveSenderCredentialsRow,
  ResolvedSenderCredentials,
  SentReceipt,
  TokenIssuedSendContext,
  UnknownReceipt,
} from "../types";
import { sanitizeProviderError } from "./errors";
import {
  classifyGmailSendFailure,
  classifyOAuthRefreshFailure,
  stringField,
  type GmailFailureCategory,
  type GmailFailureClassification,
} from "./gmail-failures";
import {
  applyMergeFields,
  assertMessageAddresses,
  base64UrlEncode,
  buildMimeMessage,
  buildUnsubscribeUrl,
  createMimeBoundary,
} from "./mime";

export const GMAIL_SEND_ENDPOINT = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send";
export const GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";

export type Fetcher = (input: string, init?: RequestInit) => Promise<Response>;

type Outcome =
  | { kind: "sent"; providerMessageId: string | null }
  | { kind: "failed"; errorMessage: string; failureCategory?: GmailFailureCategory }
  | { kind: "retry"; errorMessage: string; failureCategory?: GmailFailureCategory; retryAfter: string }
  | { kind: "unknown"; errorMessage: string };

type Failure = Omit<GmailFailureClassification, "statusCode"> & {
  errorMessage: string;
  statusCode: number | null;
};

type Operation = "gmail send" | "oauth refresh";

type Deps = {
  config: ProviderConfig;
  context: TokenIssuedSendContext;
  fetcher: Fetcher;
  now: () => Date;
  rpc: RpcClient;
};

function addSeconds(now: () => Date, seconds: number): string {
  return new Date(now().getTime() + seconds * 1000).toISOString();
}

function failed(errorMessage: unknown, failureCategory?: GmailFailureCategory): Outcome {
  return { kind: "failed", errorMessage: sanitizeProviderError(errorMessage), failureCategory };
}

function retry(errorMessage: unknown, seconds: number, now: () => Date, failureCategory?: GmailFailureCategory): Outcome {
  return { kind: "retry", errorMessage: sanitizeProviderError(errorMessage), failureCategory, retryAfter: addSeconds(now, seconds) };
}

function unknown(errorMessage: unknown): Outcome {
  return { kind: "unknown", errorMessage: sanitizeProviderError(errorMessage) };
}

function makeFailure({
  category,
  detail,
  operation,
  providerMessage = null,
  reason,
  retryAfterSeconds = null,
  statusCode = null,
}: {
  category: GmailFailureCategory;
  detail?: unknown;
  operation: Operation;
  providerMessage?: string | null;
  reason: string;
  retryAfterSeconds?: number | null;
  statusCode?: number | null;
}): Failure {
  const parts = [
    `google.${category}: ${operation}`,
    statusCode === null ? null : `status=${statusCode}`,
    `reason=${reason}`,
    retryAfterSeconds === null ? null : `retry_after=${retryAfterSeconds}s`,
    providerMessage ? `message=${providerMessage}` : null,
    detail === undefined ? null : sanitizeProviderError(detail),
  ].filter((part): part is string => Boolean(part));

  return {
    category,
    errorMessage: sanitizeProviderError(parts.join("; ")),
    providerMessage,
    reason,
    retryAfterSeconds,
    statusCode,
  };
}

type TimedFetch = { kind: "response"; response: Response } | { kind: "timeout" | "network_error"; errorMessage: string };

async function fetchWithTimeout(
  fetcher: Fetcher,
  url: string,
  init: RequestInit,
  timeoutMs: number,
  timeoutMessage: string
): Promise<TimedFetch> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return { kind: "response", response: await fetcher(url, { ...init, signal: controller.signal }) };
  } catch (error) {
    const isAbort = typeof error === "object" && error !== null && (error as { name?: unknown }).name === "AbortError";
    return isAbort
      ? { kind: "timeout", errorMessage: timeoutMessage }
      : { kind: "network_error", errorMessage: sanitizeProviderError(error) };
  } finally {
    clearTimeout(timer);
  }
}

async function readText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch (error) {
    return sanitizeProviderError(error);
  }
}

function parseObject(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = text.trim() ? JSON.parse(text) : null;
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

type SendResult = { kind: "accepted"; providerMessageId: string | null } | { kind: "failure"; failure: Failure };

// A timeout or dropped connection after the request left is ambiguous: Gmail
// may have accepted the message. That is what send_unknown exists for.
async function sendGmailMessage(
  { config, fetcher, now }: Pick<Deps, "config" | "fetcher" | "now">,
  accessToken: string,
  raw: string,
  authFailureCategory: "auth_refreshable" | "reauth_required" = "auth_refreshable"
): Promise<SendResult> {
  const result = await fetchWithTimeout(
    fetcher,
    GMAIL_SEND_ENDPOINT,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ raw }),
    },
    config.providerSendTimeoutMs,
    "Gmail send request timed out"
  );

  if (result.kind !== "response") {
    return {
      kind: "failure",
      failure: makeFailure({ category: "provider_ambiguous", detail: result.errorMessage, operation: "gmail send", reason: result.kind }),
    };
  }

  const bodyText = await readText(result.response);

  if (result.response.ok) {
    return { kind: "accepted", providerMessageId: stringField(parseObject(bodyText), "id") };
  }

  const classification = classifyGmailSendFailure({
    authFailureCategory,
    bodyText,
    defaultRetryDelaySeconds: config.defaultRetryDelaySeconds,
    now,
    response: result.response,
  });

  return { kind: "failure", failure: makeFailure({ ...classification, operation: "gmail send" }) };
}

type RefreshResult =
  | { kind: "refreshed"; accessToken: string; accessTokenExpiresAt: string | null; refreshToken: string | null }
  | { kind: "failure"; failure: Failure };

async function refreshAccessToken(
  { config, fetcher, now }: Pick<Deps, "config" | "fetcher" | "now">,
  refreshToken: string | null
): Promise<RefreshResult> {
  if (!refreshToken) {
    return {
      kind: "failure",
      failure: makeFailure({
        category: "reauth_required",
        detail: "access token was rejected and no refresh token is stored",
        operation: "oauth refresh",
        reason: "missing_refresh_token",
      }),
    };
  }

  if (!config.googleClientId || !config.googleClientSecret) {
    return {
      kind: "failure",
      failure: makeFailure({
        category: "operator_action",
        detail: "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are not configured",
        operation: "oauth refresh",
        reason: "oauth_client_not_configured",
      }),
    };
  }

  const result = await fetchWithTimeout(
    fetcher,
    GOOGLE_TOKEN_ENDPOINT,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: config.googleClientId,
        client_secret: config.googleClientSecret,
        grant_type: "refresh_token",
        refresh_token: refreshToken,
      }),
    },
    config.providerRefreshTimeoutMs,
    "Google OAuth refresh request timed out"
  );

  if (result.kind !== "response") {
    return {
      kind: "failure",
      failure: makeFailure({
        category: "provider_ambiguous",
        detail: result.errorMessage,
        operation: "oauth refresh",
        reason: result.kind,
        retryAfterSeconds: config.defaultRetryDelaySeconds,
      }),
    };
  }

  const text = await readText(result.response);
  const body = parseObject(text);

  if (result.response.ok) {
    const accessToken = stringField(body, "access_token");

    if (!accessToken) {
      return {
        kind: "failure",
        failure: makeFailure({
          category: "operator_action",
          detail: "OAuth refresh succeeded without an access token",
          operation: "oauth refresh",
          reason: "missing_access_token",
          statusCode: result.response.status,
        }),
      };
    }

    const expiresIn = body?.expires_in;

    return {
      kind: "refreshed",
      accessToken,
      accessTokenExpiresAt:
        typeof expiresIn === "number" && Number.isFinite(expiresIn) && expiresIn > 0 ? addSeconds(now, expiresIn) : null,
      refreshToken: stringField(body, "refresh_token"),
    };
  }

  const classification = classifyOAuthRefreshFailure({
    bodyText: text,
    defaultRetryDelaySeconds: config.defaultRetryDelaySeconds,
    now,
    response: result.response,
  });

  return { kind: "failure", failure: makeFailure({ ...classification, operation: "oauth refresh" }) };
}

type CredentialResult = { ok: true; credentials: ResolvedSenderCredentials } | { ok: false; outcome: Outcome };

/**
 * Reads the sender's tokens from Vault through the resolve RPC. Missing,
 * parked, or mismatched credentials become a failed receipt rather than a
 * send with the wrong identity.
 */
async function resolveCredentials(rpc: RpcClient, senderId: string): Promise<CredentialResult> {
  const { data, error } = await rpc.rpc<ResolveSenderCredentialsRow[]>("dispatcher_resolve_sender_credentials", {
    p_sender_id: senderId,
  });

  if (error) {
    return { ok: false, outcome: failed(`Sender credentials could not be resolved: ${formatRpcError(error)}`) };
  }

  const row = data?.[0];

  if (!row) {
    return { ok: false, outcome: failed("Sender credentials are missing") };
  }

  if (row.sender_id !== senderId) {
    return { ok: false, outcome: failed("Credentials resolved for the wrong sender") };
  }

  if (row.provider !== "google") {
    return { ok: false, outcome: failed("Unsupported sender provider") };
  }

  if (row.status !== "active") {
    return { ok: false, outcome: failed(`Sender credentials are ${row.status ?? "invalid"}`) };
  }

  if (!row.provider_email?.trim() || !row.access_token?.trim()) {
    return { ok: false, outcome: failed("Sender credentials are incomplete") };
  }

  return {
    ok: true,
    credentials: {
      sender_id: row.sender_id,
      provider: "google",
      provider_email: row.provider_email,
      access_token: row.access_token,
      refresh_token: row.refresh_token?.trim() || null,
      access_token_expires_at: row.access_token_expires_at,
    },
  };
}

async function markReauthRequired({ context, rpc }: Pick<Deps, "context" | "rpc">, failure: Failure): Promise<Outcome> {
  const { error } = await rpc.rpc("dispatcher_mark_sender_reauth_required", {
    p_sender_id: context.sender_id,
    p_provider: "google",
    p_reason: failure.errorMessage,
  });
  const suffix = error ? `; credentials could not be parked: ${formatRpcError(error)}` : "";

  return failed(`${failure.errorMessage}${suffix}`, failure.category);
}

function reportOperatorAction(context: TokenIssuedSendContext, failure: Failure): void {
  if (failure.category === "operator_action") {
    log("error", "dispatcher.provider.operator_action", {
      workerId: context.worker_id,
      sendTokenId: context.send_token_id,
      reason: failure.reason,
      statusCode: failure.statusCode,
    });
  }
}

async function outcomeForSendFailure(deps: Deps, failure: Failure): Promise<Outcome> {
  reportOperatorAction(deps.context, failure);

  switch (failure.category) {
    case "rate_limited":
      return retry(failure.errorMessage, failure.retryAfterSeconds ?? deps.config.defaultRetryDelaySeconds, deps.now, failure.category);
    case "provider_ambiguous":
      return unknown(failure.errorMessage);
    case "auth_refreshable":
    case "reauth_required":
      return markReauthRequired(deps, failure);
    default:
      return failed(failure.errorMessage, failure.category);
  }
}

async function resendOnce(deps: Deps, accessToken: string, raw: string): Promise<Outcome> {
  const result = await sendGmailMessage(deps, accessToken, raw, "reauth_required");

  return result.kind === "accepted"
    ? { kind: "sent", providerMessageId: result.providerMessageId }
    : outcomeForSendFailure(deps, result.failure);
}

/**
 * The 401 path. Another worker may already have refreshed this sender's
 * token, so re-read before refreshing. After one refresh the message is sent
 * once more; a second 401 parks the credential instead of looping.
 */
async function handleUnauthorized(deps: Deps, used: ResolvedSenderCredentials, raw: string): Promise<Outcome> {
  const current = await resolveCredentials(deps.rpc, deps.context.sender_id);

  if (!current.ok) {
    return current.outcome;
  }

  if (current.credentials.access_token !== used.access_token) {
    return resendOnce(deps, current.credentials.access_token, raw);
  }

  const usedRefreshToken = current.credentials.refresh_token;
  const refresh = await refreshAccessToken(deps, usedRefreshToken);

  if (refresh.kind === "failure") {
    const { failure } = refresh;
    reportOperatorAction(deps.context, failure);

    if (failure.category === "rate_limited" || failure.category === "provider_ambiguous") {
      // Nothing was sent yet, so a refresh hiccup is safely retryable.
      return retry(failure.errorMessage, failure.retryAfterSeconds ?? deps.config.defaultRetryDelaySeconds, deps.now, failure.category);
    }

    if (failure.category !== "reauth_required") {
      return failed(failure.errorMessage, failure.category);
    }

    // invalid_grant can mean a concurrent refresh rotated the refresh token.
    if (failure.reason.startsWith("invalid_grant")) {
      const latest = await resolveCredentials(deps.rpc, deps.context.sender_id);

      if (latest.ok && latest.credentials.refresh_token && latest.credentials.refresh_token !== usedRefreshToken) {
        return resendOnce(deps, latest.credentials.access_token, raw);
      }
    }

    return markReauthRequired(deps, failure);
  }

  const { error } = await deps.rpc.rpc("dispatcher_store_refreshed_access_token", {
    p_sender_id: deps.context.sender_id,
    p_provider: "google",
    p_access_token: refresh.accessToken,
    p_access_token_expires_at: refresh.accessTokenExpiresAt,
    p_refresh_token: refresh.refreshToken,
  });

  if (error) {
    // Don't send with a token we failed to persist; try again later.
    return retry(`Refreshed access token could not be stored: ${formatRpcError(error)}`, deps.config.defaultRetryDelaySeconds, deps.now);
  }

  return resendOnce(deps, refresh.accessToken, raw);
}

async function recordReceipt(
  context: TokenIssuedSendContext,
  outcome: Outcome,
  receipts: ReceiptClient,
  now: () => Date
): Promise<ProviderReceipt> {
  const base = {
    attempt_id: context.attempt_id,
    campaign_contact_id: context.campaign_contact_id,
    completed_at: now().toISOString(),
    lease_token: context.lease_token,
    send_token_id: context.send_token_id,
    worker_id: context.worker_id,
  };

  let receipt: ProviderReceipt;

  try {
    if (outcome.kind === "sent") {
      const sent: SentReceipt = { ...base, status: "sent", provider_message_id: outcome.providerMessageId };
      receipt = sent;
      await receipts.sent(sent);
    } else if (outcome.kind === "unknown") {
      const unknownReceipt: UnknownReceipt = { ...base, status: "unknown", error_message: outcome.errorMessage };
      receipt = unknownReceipt;
      await receipts.unknown(unknownReceipt);
    } else {
      const failedReceipt: FailedReceipt = {
        ...base,
        status: outcome.kind,
        error_message: outcome.errorMessage,
        failure_category: outcome.failureCategory ?? null,
        retry_after: outcome.kind === "retry" ? outcome.retryAfter : null,
      };
      receipt = failedReceipt;
      await receipts.failed(failedReceipt);
    }
  } catch (error) {
    // The lease will expire into send_unknown; surface the handoff failure.
    log("error", "dispatcher.receipt.rejected", {
      workerId: context.worker_id,
      sendTokenId: context.send_token_id,
      outcome: outcome.kind,
      error: sanitizeProviderError(error),
    });
    throw error;
  }

  return receipt;
}

/**
 * Spends one issued token through Gmail and records exactly one receipt.
 * This never chooses work or paces senders; it turns provider certainty
 * into sent, failed, retry, or unknown.
 */
export async function executeGmailSend({
  config,
  context,
  createBoundary = createMimeBoundary,
  fetcher = (input, init) => fetch(input, init),
  now = () => new Date(),
  receipts,
  rpc,
}: {
  config: ProviderConfig;
  context: TokenIssuedSendContext;
  createBoundary?: () => string;
  fetcher?: Fetcher;
  now?: () => Date;
  receipts: ReceiptClient;
  rpc: RpcClient;
}): Promise<ProviderReceipt> {
  const deps: Deps = { config, context, fetcher, now, rpc };

  if (!config.enabledProviders.includes("google")) {
    return recordReceipt(context, failed("Google provider is not enabled for this worker"), receipts, now);
  }

  try {
    assertMessageAddresses(context);
  } catch (error) {
    return recordReceipt(context, failed(error, "provider_rejected"), receipts, now);
  }

  const resolved = await resolveCredentials(rpc, context.sender_id);

  if (!resolved.ok) {
    return recordReceipt(context, resolved.outcome, receipts, now);
  }

  if (resolved.credentials.provider_email.trim().toLowerCase() !== context.from_email.trim().toLowerCase()) {
    return recordReceipt(context, failed(`Provider mailbox changed for sender ${context.sender_id}`), receipts, now);
  }

  const unsubscribeUrl = buildUnsubscribeUrl(config.unsubscribeUrlBase, context.unsubscribe_token);
  const message = applyMergeFields(context, { firstName: context.recipient_first_name, unsubscribeUrl });
  const raw = base64UrlEncode(buildMimeMessage(message, createBoundary(), { listUnsubscribeUrl: unsubscribeUrl }));
  const first = await sendGmailMessage(deps, resolved.credentials.access_token, raw);

  let outcome: Outcome;

  if (first.kind === "accepted") {
    outcome = { kind: "sent", providerMessageId: first.providerMessageId };
  } else if (first.failure.category === "auth_refreshable") {
    outcome = await handleUnauthorized(deps, resolved.credentials, raw);
  } else {
    outcome = await outcomeForSendFailure(deps, first.failure);
  }

  return recordReceipt(context, outcome, receipts, now);
}
