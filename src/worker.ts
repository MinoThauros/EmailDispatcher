import { randomUUID } from "node:crypto";
import type { WorkerConfig } from "./config";
import { formatRpcError, type RpcClient } from "./rpc";
import type { ClaimNextSendTokenRow, ClaimResult, ScopeDeferralRollup, TokenIssuedSendContext } from "./types";

export type WorkerCycleStopReason = "completed" | "drain_budget_reached" | "shutdown_margin_reached";

export type WorkerCycleSummary = {
  workerId: string;
  stopReason: WorkerCycleStopReason;
  elapsedMs: number;
  tokensIssued: number;
};

export type DrainContext = {
  workerId: string;
  drainDeadlineMs: number;
  shutdownDeadlineMs: number;
};

/**
 * Spends one issued token. The worker awaits it before claiming the next one,
 * so within a worker sends are strictly sequential. It should record exactly
 * one receipt, or throw and leave the lease to expire into send_unknown.
 */
export type HandleTokenIssued = (context: TokenIssuedSendContext) => Promise<unknown>;

function requireField<Value>(value: Value | null, field: keyof TokenIssuedSendContext): Value {
  if (value === null) {
    throw new Error(`Claim RPC returned token_issued without ${field}`);
  }

  return value;
}

export function normalizeClaimRow(row: ClaimNextSendTokenRow): ClaimResult {
  if (row.state === "no_work") {
    return { state: "no_work", next_eligible_at: row.next_eligible_at, worker_id: row.worker_id };
  }

  if (row.state !== "token_issued") {
    throw new Error(`Claim RPC returned unknown state: ${row.state}`);
  }

  return {
    state: "token_issued",
    worker_id: row.worker_id,
    sender_id: requireField(row.sender_id, "sender_id"),
    sender_min_interval_seconds: row.sender_min_interval_seconds,
    campaign_contact_id: requireField(row.campaign_contact_id, "campaign_contact_id"),
    campaign_id: requireField(row.campaign_id, "campaign_id"),
    contact_id: requireField(row.contact_id, "contact_id"),
    to_email: requireField(row.to_email, "to_email"),
    recipient_first_name: row.recipient_first_name,
    lease_token: requireField(row.lease_token, "lease_token"),
    send_token_id: requireField(row.send_token_id, "send_token_id"),
    attempt_id: requireField(row.attempt_id, "attempt_id"),
    attempt_no: requireField(row.attempt_no, "attempt_no"),
    subject: requireField(row.subject, "subject"),
    preview_text: row.preview_text,
    body_html: requireField(row.body_html, "body_html"),
    body_text: row.body_text,
    from_name: row.from_name,
    from_email: requireField(row.from_email, "from_email"),
    reply_to_email: row.reply_to_email,
    unsubscribe_token: row.unsubscribe_token,
  };
}

/**
 * Asks Postgres to admit one send. All locking, pacing and warmup decisions
 * happen inside `dispatcher_claim_next_send_token`; see the admission
 * migration for the full rules.
 */
export async function claimNextSendToken(
  rpc: RpcClient,
  config: WorkerConfig,
  workerId: string,
  now: () => number = Date.now
): Promise<ClaimResult> {
  const { data, error } = await rpc.rpc<ClaimNextSendTokenRow[]>("dispatcher_claim_next_send_token", {
    p_worker_id: workerId,
    p_recipient_lease_seconds: config.recipientLeaseSeconds,
    p_sender_min_interval_seconds: config.senderMinIntervalSeconds,
    p_now: new Date(now()).toISOString(),
    p_candidate_limit: config.tokenCandidateLimit,
  });

  if (error) {
    throw new Error(`Token claim failed: ${formatRpcError(error)}`);
  }

  const row = data?.[0];

  if (!row) {
    throw new Error("Claim RPC returned no rows");
  }

  return normalizeClaimRow(row);
}

/**
 * Sweeps leases whose worker never reported back. Those recipients become
 * send_unknown, because the provider may already have delivered the email.
 */
export async function markExpiredSendsUnknown(rpc: RpcClient, now: () => number = Date.now): Promise<number> {
  const { data, error } = await rpc.rpc<number>("dispatcher_mark_expired_sends_unknown", {
    p_now: new Date(now()).toISOString(),
  });

  if (error) {
    throw new Error(`Expired lease sweep failed: ${formatRpcError(error)}`);
  }

  return data ?? 0;
}

/** Returns, and deletes, why this worker's candidates were deferred. */
export async function collectScopeDeferrals(rpc: RpcClient, workerId: string): Promise<ScopeDeferralRollup[]> {
  const { data, error } = await rpc.rpc<ScopeDeferralRollup[]>("dispatcher_collect_scope_deferrals", {
    p_worker_id: workerId,
  });

  if (error) {
    throw new Error(`Scope deferral collection failed: ${formatRpcError(error)}`);
  }

  return data ?? [];
}

/**
 * The admission loop for one worker: sweep expired leases, then claim and
 * spend tokens one at a time until Postgres says no_work or the shutdown
 * deadline arrives. Returns the number of tokens spent.
 */
export async function drainQueue({
  config,
  context,
  handleTokenIssued,
  now = Date.now,
  rpc,
}: {
  config: WorkerConfig;
  context: DrainContext;
  handleTokenIssued: HandleTokenIssued;
  now?: () => number;
  rpc: RpcClient;
}): Promise<number> {
  await markExpiredSendsUnknown(rpc, now);

  let tokensIssued = 0;

  while (now() < context.shutdownDeadlineMs) {
    const result = await claimNextSendToken(rpc, config, context.workerId, now);

    if (result.state === "no_work") {
      break;
    }

    tokensIssued += 1;
    await handleTokenIssued(result);
  }

  return tokensIssued;
}

/**
 * Gives one invocation an identity and a time budget, then runs `drain`.
 * The shutdown margin leaves room for the last in-flight send and its
 * receipt to finish before the platform kills the function.
 */
export async function runWorkerCycle({
  config,
  drain,
  now = Date.now,
  createWorkerId = randomUUID,
}: {
  config: Pick<WorkerConfig, "drainBudgetMs" | "shutdownMarginMs">;
  drain: (context: DrainContext) => Promise<number>;
  now?: () => number;
  createWorkerId?: () => string;
}): Promise<WorkerCycleSummary> {
  const workerId = createWorkerId();
  const startedAtMs = now();
  const drainDeadlineMs = startedAtMs + config.drainBudgetMs;
  const shutdownDeadlineMs = drainDeadlineMs - config.shutdownMarginMs;

  if (shutdownDeadlineMs <= startedAtMs) {
    return { workerId, stopReason: "shutdown_margin_reached", elapsedMs: 0, tokensIssued: 0 };
  }

  const tokensIssued = await drain({ workerId, drainDeadlineMs, shutdownDeadlineMs });
  const elapsedMs = Math.max(0, now() - startedAtMs);

  let stopReason: WorkerCycleStopReason = "completed";

  if (elapsedMs >= config.drainBudgetMs) {
    stopReason = "drain_budget_reached";
  } else if (config.drainBudgetMs - elapsedMs <= config.shutdownMarginMs) {
    stopReason = "shutdown_margin_reached";
  }

  return { workerId, stopReason, elapsedMs, tokensIssued };
}
