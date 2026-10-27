import { formatRpcError, type RpcClient, type RpcResult } from "./rpc";
import type { FailedReceipt, ReceiptClient, SentReceipt, UnknownReceipt } from "./types";

async function requireSuccess(fn: string, result: PromiseLike<RpcResult<unknown>>): Promise<void> {
  const { error } = await result;

  if (error) {
    const details = formatRpcError(error);
    throw new Error(details ? `Receipt RPC ${fn} failed: ${details}` : `Receipt RPC ${fn} failed`);
  }
}

/**
 * Hands provider outcomes back to Postgres. Each RPC checks the lease token
 * and the recipient's current state before changing anything, so a stale or
 * duplicate receipt is rejected rather than applied.
 */
export function createReceiptClient(rpc: RpcClient): ReceiptClient {
  return {
    sent(receipt: SentReceipt) {
      return requireSuccess(
        "dispatcher_receipt_sent",
        rpc.rpc("dispatcher_receipt_sent", {
          p_campaign_contact_id: receipt.campaign_contact_id,
          p_lease_token: receipt.lease_token,
          p_provider_message_id: receipt.provider_message_id,
          p_completed_at: receipt.completed_at,
        })
      );
    },
    failed(receipt: FailedReceipt) {
      return requireSuccess(
        "dispatcher_receipt_failed",
        rpc.rpc("dispatcher_receipt_failed", {
          p_campaign_contact_id: receipt.campaign_contact_id,
          p_lease_token: receipt.lease_token,
          p_error_message: receipt.error_message,
          p_retry_after: receipt.status === "retry" ? receipt.retry_after : null,
          p_completed_at: receipt.completed_at,
          p_failure_category: receipt.failure_category,
        })
      );
    },
    unknown(receipt: UnknownReceipt) {
      return requireSuccess(
        "dispatcher_receipt_unknown",
        rpc.rpc("dispatcher_receipt_unknown", {
          p_campaign_contact_id: receipt.campaign_contact_id,
          p_lease_token: receipt.lease_token,
          p_error_message: receipt.error_message,
          p_completed_at: receipt.completed_at,
        })
      );
    },
  };
}
