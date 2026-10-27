import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import type { SimulationConfig } from "../config";
import { log } from "../log";
import { GMAIL_SEND_ENDPOINT, GOOGLE_TOKEN_ENDPOINT, type Fetcher } from "./gmail";

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

function readHeader(raw: string, name: string): string | null {
  const mime = Buffer.from(raw.replaceAll("-", "+").replaceAll("_", "/"), "base64").toString("utf-8");
  const match = mime.match(new RegExp(`^${name}: (.*)$`, "mi"));
  return match ? match[1].trim() : null;
}

/**
 * Stands in for Gmail and Google OAuth so the whole pipeline (admission,
 * MIME, receipts, retries, unknowns) runs without a real mailbox. Rates
 * come from SIMULATED_RATE_LIMIT_RATE and SIMULATED_SERVER_ERROR_RATE; a
 * 500 is ambiguous on purpose, so you can watch send_unknown happen.
 */
export function createSimulatedFetcher(config: SimulationConfig, random: () => number = Math.random): Fetcher {
  return async (url, init) => {
    if (config.sendDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, config.sendDelayMs));
    }

    if (url === GOOGLE_TOKEN_ENDPOINT) {
      return json(200, { access_token: `simulated-${randomUUID()}`, expires_in: 3600 });
    }

    if (url !== GMAIL_SEND_ENDPOINT) {
      return json(404, { error: "not_found" });
    }

    const raw = String(JSON.parse(String(init?.body ?? "{}")).raw ?? "");
    const to = readHeader(raw, "To");
    const roll = random();

    if (roll < config.rateLimitRate) {
      log("info", "dispatcher.simulated.rate_limited", { to });
      return json(429, { error: { code: 429, message: "Simulated rate limit", errors: [{ reason: "rateLimitExceeded" }] } }, {
        "retry-after": "60",
      });
    }

    if (roll < config.rateLimitRate + config.serverErrorRate) {
      log("info", "dispatcher.simulated.server_error", { to });
      return json(500, { error: { code: 500, message: "Simulated backend error", errors: [{ reason: "backendError" }] } });
    }

    const id = `sim-${randomUUID()}`;
    log("info", "dispatcher.simulated.sent", { to, subject: readHeader(raw, "Subject"), providerMessageId: id });
    return json(200, { id, threadId: id, labelIds: ["SENT"] });
  };
}
