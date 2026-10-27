import type { GmailFailureCategory } from "./provider/gmail-failures";

export type EmailProvider = "google";

export type SenderCredentialStatus = "active" | "reauth_required" | "disabled";

/**
 * One row from `dispatcher_claim_next_send_token`. Every column except the
 * first few is null when `state` is `no_work`.
 */
export type ClaimNextSendTokenRow = {
  state: string;
  next_eligible_at: string | null;
  worker_id: string;
  sender_id: string | null;
  sender_min_interval_seconds: number;
  campaign_contact_id: string | null;
  campaign_id: string | null;
  contact_id: string | null;
  to_email: string | null;
  recipient_first_name: string | null;
  lease_token: string | null;
  send_token_id: string | null;
  attempt_id: string | null;
  attempt_no: number | null;
  subject: string | null;
  preview_text: string | null;
  body_html: string | null;
  body_text: string | null;
  from_name: string | null;
  from_email: string | null;
  reply_to_email: string | null;
  unsubscribe_token: string | null;
};

/**
 * Permission to attempt exactly one send. Postgres has already leased the
 * recipient and written the token log and attempt ledger row; the holder
 * must hand back exactly one receipt for `lease_token`.
 */
export type TokenIssuedSendContext = {
  state: "token_issued";
  worker_id: string;
  sender_id: string;
  sender_min_interval_seconds: number;
  campaign_contact_id: string;
  campaign_id: string;
  contact_id: string;
  to_email: string;
  recipient_first_name: string | null;
  lease_token: string;
  send_token_id: string;
  attempt_id: string;
  attempt_no: number;
  subject: string;
  preview_text: string | null;
  body_html: string;
  body_text: string | null;
  from_name: string | null;
  from_email: string;
  reply_to_email: string | null;
  unsubscribe_token: string | null;
};

/** No admissible recipient right now; `next_eligible_at` is the earliest known unblock time. */
export type NoWorkResult = {
  state: "no_work";
  next_eligible_at: string | null;
  worker_id: string;
};

export type ClaimResult = TokenIssuedSendContext | NoWorkResult;

export type ScopeDeferralRollup = {
  worker_id: string;
  scope_id: string;
  scope_key_type: string;
  deferral_reason: string;
  tier: string;
  deferred_count: number;
};

export type ResolveSenderCredentialsRow = {
  sender_id: string;
  provider: string | null;
  provider_email: string | null;
  access_token: string | null;
  refresh_token: string | null;
  access_token_expires_at: string | null;
  status: string | null;
};

export type ResolvedSenderCredentials = {
  sender_id: string;
  provider: EmailProvider;
  provider_email: string;
  access_token: string;
  refresh_token: string | null;
  access_token_expires_at: string | null;
};

/** Fields that tie a provider result back to the exact token that was issued. */
export type ReceiptBase = {
  attempt_id: string;
  campaign_contact_id: string;
  completed_at: string;
  lease_token: string;
  send_token_id: string;
  worker_id: string;
};

export type SentReceipt = ReceiptBase & {
  status: "sent";
  provider_message_id: string | null;
};

export type FailedReceipt = ReceiptBase & {
  status: "failed" | "retry";
  error_message: string;
  failure_category: GmailFailureCategory | null;
  retry_after: string | null;
};

export type UnknownReceipt = ReceiptBase & {
  status: "unknown";
  error_message: string;
};

export type ProviderReceipt = SentReceipt | FailedReceipt | UnknownReceipt;

/** Provider code reports outcomes through this; it never updates recipient rows directly. */
export type ReceiptClient = {
  sent: (receipt: SentReceipt) => Promise<void>;
  failed: (receipt: FailedReceipt) => Promise<void>;
  unknown: (receipt: UnknownReceipt) => Promise<void>;
};
