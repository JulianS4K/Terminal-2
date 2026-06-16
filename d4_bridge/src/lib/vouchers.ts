// Vouchers (pretix-style access tokens) — distinct from discount codes.
//
// Buyers validate a code (checkVoucher) before checkout; a valid voucher may
// unlock a sold-out tier and/or pin a price. Organizers mint/list/delete codes.
// Codes are org-secret (staff RLS); the buyer path only ever gets a yes/no + the
// grant, never the code list.

import { supabase } from './supabase';

export interface VoucherCheck {
  valid: boolean;
  voucherId: string | null;
  restrictTierId: string | null;
  canBypass: boolean;
  overridePrice: number | null;
  reason: string | null;
}

export interface Voucher {
  id: string;
  code: string;
  tierId: string | null;
  maxUses: number;
  usedCount: number;
  bypassCapacity: boolean;
  priceOverride: number | null;
  reservedEmail: string | null;
  validUntil: string | null;
  comment: string | null;
  createdAt: string;
}

/** Buyer-facing validation (no consume). */
export async function checkVoucher(eventId: string, code: string, email?: string | null): Promise<VoucherCheck> {
  const { data, error } = await supabase.rpc('exos_check_voucher', {
    p_event_id: eventId, p_code: code.trim(), p_email: email ?? null,
  });
  if (error) throw error;
  const r = Array.isArray(data) ? data[0] : data;
  return {
    valid: r?.is_valid === true,
    voucherId: r?.voucher_id ?? null,
    restrictTierId: r?.restrict_tier_id ?? null,
    canBypass: r?.can_bypass === true,
    overridePrice: r?.override_price != null ? Number(r.override_price) : null,
    reason: r?.reason ?? null,
  };
}

/** Organizer: mint a voucher; returns the generated code. */
export async function issueVoucher(input: {
  eventId: string;
  tierId?: string | null;
  reservedEmail?: string | null;
  bypassCapacity?: boolean;
  priceOverride?: number | null;
  maxUses?: number;
  validHours?: number | null;
  comment?: string | null;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_issue_voucher', {
    p_event_id: input.eventId,
    p_tier_id: input.tierId ?? null,
    p_reserved_email: input.reservedEmail ?? null,
    p_bypass_capacity: input.bypassCapacity ?? true,
    p_price_override: input.priceOverride ?? null,
    p_max_uses: input.maxUses ?? 1,
    p_valid_hours: input.validHours ?? null,
    p_comment: input.comment ?? null,
  });
  if (error) throw error;
  return data as string;
}

export async function listVouchers(eventId: string): Promise<Voucher[]> {
  const { data, error } = await supabase
    .from('exos_vouchers').select('*').eq('event_id', eventId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, code: r.code, tierId: r.tier_id, maxUses: r.max_uses, usedCount: r.used_count,
    bypassCapacity: r.bypass_capacity, priceOverride: r.price_override, reservedEmail: r.reserved_email,
    validUntil: r.valid_until, comment: r.comment, createdAt: r.created_at,
  }));
}

export async function deleteVoucher(id: string): Promise<void> {
  const { error } = await supabase.from('exos_vouchers').delete().eq('id', id);
  if (error) throw error;
}
