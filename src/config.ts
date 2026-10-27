import type { EmailProvider } from "./types";

type Env = Record<string, string | undefined>;

export const DEFAULT_DRAIN_BUDGET_MS = 270_000;
export const DEFAULT_SHUTDOWN_MARGIN_MS = 30_000;
export const DEFAULT_RECIPIENT_LEASE_SECONDS = 300;
export const DEFAULT_SENDER_MIN_INTERVAL_SECONDS = 180;
export const DEFAULT_TOKEN_CANDIDATE_LIMIT = 50;
export const DEFAULT_PROVIDER_SEND_TIMEOUT_MS = 30_000;
export const DEFAULT_PROVIDER_REFRESH_TIMEOUT_MS = 15_000;
export const DEFAULT_RETRY_DELAY_SECONDS = 300;

/**
 * Shapes one cron invocation and the inputs to token admission. The sender
 * interval is a floor: the warmup policy in Postgres can make it stricter.
 */
export type WorkerConfig = {
  drainBudgetMs: number;
  shutdownMarginMs: number;
  recipientLeaseSeconds: number;
  senderMinIntervalSeconds: number;
  tokenCandidateLimit: number;
};

/**
 * Controls what happens after Postgres issues a token: Gmail/OAuth request
 * behavior and fallback retry timing. None of this chooses recipients or
 * paces senders.
 */
export type ProviderConfig = {
  enabledProviders: EmailProvider[];
  googleClientId: string | null;
  googleClientSecret: string | null;
  providerSendTimeoutMs: number;
  providerRefreshTimeoutMs: number;
  defaultRetryDelaySeconds: number;
  unsubscribeUrlBase: string | null;
};

export type SimulationConfig = {
  enabled: boolean;
  sendDelayMs: number;
  rateLimitRate: number;
  serverErrorRate: number;
};

export type RuntimeConfig = {
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  loopCycles: number;
  loopDelayMs: number;
};

function readString(env: Env, key: string): string | null {
  const value = env[key]?.trim();
  return value ? value : null;
}

function readPositive(env: Env, key: string, fallback: number, integer = true): number {
  const raw = readString(env, key);

  if (!raw) {
    return fallback;
  }

  const parsed = Number(raw);
  const valid = Number.isFinite(parsed) && parsed > 0 && (!integer || Number.isInteger(parsed));

  return valid ? parsed : fallback;
}

function readRate(env: Env, key: string, fallback: number): number {
  const parsed = Number(readString(env, key) ?? fallback);
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 1 ? parsed : fallback;
}

function readBool(env: Env, key: string, fallback: boolean): boolean {
  const value = readString(env, key)?.toLowerCase();

  if (!value) {
    return fallback;
  }

  if (["1", "true", "yes", "on"].includes(value)) {
    return true;
  }

  if (["0", "false", "no", "off"].includes(value)) {
    return false;
  }

  return fallback;
}

export function getWorkerConfig(env: Env = process.env): WorkerConfig {
  const drainBudgetMs = readPositive(env, "WORKER_DRAIN_BUDGET_MS", DEFAULT_DRAIN_BUDGET_MS, false);
  const shutdownMarginMs = readPositive(env, "WORKER_SHUTDOWN_MARGIN_MS", DEFAULT_SHUTDOWN_MARGIN_MS, false);
  const timingIsValid = shutdownMarginMs < drainBudgetMs;

  if (!timingIsValid) {
    console.warn(
      "[dispatcher] WORKER_SHUTDOWN_MARGIN_MS must be less than WORKER_DRAIN_BUDGET_MS; using the defaults for both."
    );
  }

  return {
    drainBudgetMs: timingIsValid ? drainBudgetMs : DEFAULT_DRAIN_BUDGET_MS,
    shutdownMarginMs: timingIsValid ? shutdownMarginMs : DEFAULT_SHUTDOWN_MARGIN_MS,
    recipientLeaseSeconds: readPositive(env, "WORKER_RECIPIENT_LEASE_SECONDS", DEFAULT_RECIPIENT_LEASE_SECONDS),
    senderMinIntervalSeconds: readPositive(
      env,
      "WORKER_SENDER_MIN_INTERVAL_SECONDS",
      DEFAULT_SENDER_MIN_INTERVAL_SECONDS
    ),
    tokenCandidateLimit: readPositive(env, "WORKER_TOKEN_CANDIDATE_LIMIT", DEFAULT_TOKEN_CANDIDATE_LIMIT),
  };
}

export function getProviderConfig(env: Env = process.env): ProviderConfig {
  const enabledProviders = (readString(env, "WORKER_ENABLED_PROVIDERS") ?? "google")
    .split(",")
    .map((provider) => provider.trim().toLowerCase())
    .filter((provider): provider is EmailProvider => provider === "google");

  return {
    enabledProviders: enabledProviders.length > 0 ? Array.from(new Set(enabledProviders)) : ["google"],
    googleClientId: readString(env, "GOOGLE_CLIENT_ID"),
    googleClientSecret: readString(env, "GOOGLE_CLIENT_SECRET"),
    providerSendTimeoutMs: readPositive(
      env,
      "WORKER_PROVIDER_SEND_TIMEOUT_MS",
      DEFAULT_PROVIDER_SEND_TIMEOUT_MS,
      false
    ),
    providerRefreshTimeoutMs: readPositive(
      env,
      "WORKER_PROVIDER_REFRESH_TIMEOUT_MS",
      DEFAULT_PROVIDER_REFRESH_TIMEOUT_MS,
      false
    ),
    defaultRetryDelaySeconds: readPositive(env, "WORKER_DEFAULT_RETRY_DELAY_SECONDS", DEFAULT_RETRY_DELAY_SECONDS),
    unsubscribeUrlBase: readString(env, "UNSUBSCRIBE_URL_BASE"),
  };
}

// Simulation is on unless explicitly turned off, so a fresh checkout never
// sends real email by accident.
export function getSimulationConfig(env: Env = process.env): SimulationConfig {
  return {
    enabled: readBool(env, "SIMULATE_SENDS", true),
    sendDelayMs: readPositive(env, "SIMULATED_SEND_DELAY_MS", 150, false),
    rateLimitRate: readRate(env, "SIMULATED_RATE_LIMIT_RATE", 0.05),
    serverErrorRate: readRate(env, "SIMULATED_SERVER_ERROR_RATE", 0.02),
  };
}

export function getRuntimeConfig(env: Env = process.env): RuntimeConfig {
  const supabaseUrl = readString(env, "SUPABASE_URL");
  const supabaseServiceRoleKey = readString(env, "SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    throw new Error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (see .env.example).");
  }

  return {
    supabaseUrl,
    supabaseServiceRoleKey,
    loopCycles: readPositive(env, "WORKER_LOOP_CYCLES", 1),
    loopDelayMs: readPositive(env, "WORKER_LOOP_DELAY_MS", 0, false),
  };
}
