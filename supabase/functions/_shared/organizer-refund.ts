// Organizer-initiated refunds (exos-refund). Pure helpers so the Stripe call
// is built the same way on the first try and on every retry: Stripe returns
// the first refund for a reused idempotency key only when the parameters are
// identical, and rejects the key otherwise.
//
// Charge model: destination charges with an application fee (exos-checkout).
//   reverse_transfer: true  -> the refunded share of the transfer is pulled
//                              back from the organizer's connected account, so
//                              the organizer (who got the money) pays for the
//                              refund, not the platform balance.
//   refund_application_fee  -> default TRUE: the platform returns its fee in
//                              proportion to the refund, so the organizer's net
//                              cost is exactly what they received and the buyer
//                              gets back what they paid. Stripe keeps its own
//                              processing fee either way (the platform absorbs
//                              it). Set EXOS_REFUND_KEEP_PLATFORM_FEE=true to
//                              keep the fee instead (the organizer then covers
//                              it out of their balance). Matches the auto-refund
//                              in _shared/auto-refund.ts by default.

export function organizerRefundIdempotencyKey(requestId: string): string {
  return `exos_refund_${requestId}`;
}

export interface ClaimedRequest {
  request_id: string;
  amount_cents: number;
  payment_intent: string;
  session_id: string;
  scope: string;
}

export function organizerRefundParams(req: ClaimedRequest, keepPlatformFee: boolean) {
  return {
    payment_intent: req.payment_intent,
    amount: req.amount_cents,
    reason: "requested_by_customer" as const,
    reverse_transfer: true,
    refund_application_fee: !keepPlatformFee,
    metadata: {
      exos_refund_request_id: req.request_id,
      exos_session_id: req.session_id,
      exos_scope: req.scope,
    },
  };
}

// Stripe said no and nothing was created: release the reservation. Anything
// else (network, 5xx, rate limit, idempotency conflict) might have created a
// refund, so the request stays claimed and the caller retries with the same key.
export function isDefinitiveStripeRejection(err: unknown): boolean {
  const t = (err as { type?: string } | null)?.type ?? "";
  return t === "StripeInvalidRequestError" || t === "StripeCardError" || t === "StripePermissionError";
}

// Stripe refund status -> the request/ledger status set.
export function requestStatusFromStripe(status: string | null | undefined): string {
  switch (status) {
    case "succeeded": return "succeeded";
    case "failed": return "failed";
    case "canceled": return "canceled";
    default: return "pending"; // pending, requires_action
  }
}

export const NONCE_RE = /^[A-Za-z0-9:_.-]{8,200}$/;
