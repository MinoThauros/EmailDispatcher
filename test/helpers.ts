import type { ProviderConfig } from "../src/config";
import type { RpcClient, RpcResult } from "../src/rpc";
import type { ReceiptClient, ProviderReceipt, TokenIssuedSendContext } from "../src/types";

export type RpcCall = { fn: string; args: Record<string, unknown> | undefined };

/** Fake RPC client: answers from a handler map and records every call. */
export function fakeRpc(handlers: Record<string, (args: Record<string, unknown> | undefined) => RpcResult<unknown>>) {
  const calls: RpcCall[] = [];
  const rpc: RpcClient = {
    rpc<Data>(fn: string, args?: Record<string, unknown>) {
      calls.push({ fn, args });
      const handler = handlers[fn];
      const result = handler ? handler(args) : { data: null, error: { message: `no fake for ${fn}` } };
      return Promise.resolve(result as RpcResult<Data>);
    },
  };

  return { rpc, calls };
}

export function recordingReceipts() {
  const recorded: ProviderReceipt[] = [];
  const receipts: ReceiptClient = {
    async sent(receipt) {
      recorded.push(receipt);
    },
    async failed(receipt) {
      recorded.push(receipt);
    },
    async unknown(receipt) {
      recorded.push(receipt);
    },
  };

  return { receipts, recorded };
}

export const providerConfig: ProviderConfig = {
  enabledProviders: ["google"],
  googleClientId: "client-id",
  googleClientSecret: "client-secret",
  providerSendTimeoutMs: 1_000,
  providerRefreshTimeoutMs: 1_000,
  defaultRetryDelaySeconds: 300,
  unsubscribeUrlBase: "https://example.test/unsubscribe?token={token}",
};

export function sendContext(overrides: Partial<TokenIssuedSendContext> = {}): TokenIssuedSendContext {
  return {
    state: "token_issued",
    worker_id: "worker-1",
    sender_id: "sender-1",
    sender_min_interval_seconds: 600,
    campaign_contact_id: "cc-1",
    campaign_id: "campaign-1",
    contact_id: "contact-1",
    to_email: "candidate@example.com",
    recipient_first_name: "Ada",
    lease_token: "lease-1",
    send_token_id: "token-1",
    attempt_id: "attempt-1",
    attempt_no: 1,
    subject: "Hello {{first_name}}",
    preview_text: null,
    body_html: '<p>Hi {{first_name}}</p><a href="{{unsubscribe_url}}">Unsubscribe</a>',
    body_text: null,
    from_name: "Maya at Acme Talent",
    from_email: "maya@acme.test",
    reply_to_email: null,
    unsubscribe_token: "11111111-1111-1111-1111-111111111111",
    ...overrides,
  };
}

export function credentialRow(accessToken = "access-1", refreshToken: string | null = "refresh-1") {
  return {
    data: [
      {
        sender_id: "sender-1",
        provider: "google",
        provider_email: "maya@acme.test",
        access_token: accessToken,
        refresh_token: refreshToken,
        access_token_expires_at: null,
        status: "active",
      },
    ],
    error: null,
  };
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

export const fixedNow = () => new Date("2026-01-01T00:00:00.000Z");
