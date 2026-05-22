// Exos ticket + transfer seam (Supabase). The single module the ticket-path
// views talk to, replacing the scattered Firestore calls in MyTickets,
// TicketDetail, WalletPass, TransferTicket, ClaimTicket, OrganizerCheckIn and
// the event report. Same pattern as lib/events.ts:
//   * reads hit the RLS-gated base tables (owner/buyer/staff visibility),
//   * mutations go through the SECURITY DEFINER RPCs from migration
//     20260520130000 (mint / check-in / transfer / claim / cancel / void),
//   * rows are mapped to the existing Ticket / Transfer shapes (src/types.ts)
//     so the views stay close to drop-in. timestamptz → Firestore Timestamp
//     transitionally, same as the other seams.
//
// Real buyer fulfillment (Stripe Checkout + webhook) is still phase-2 and runs
// server-side under service_role; mintTickets() here is the org-staff/admin
// comp + test-mint path (wired to EventDetails' admin "TEST" button) that makes
// the whole flow exercisable on Supabase without a payment processor.

import { Timestamp } from './timestamp';
import { supabase } from './supabase';
import { getCurrentAppUser } from './auth';
import { mapEvent } from './events';
import { Event, Ticket, Transfer } from '../types';

const toTs = (iso?: string | null): Timestamp =>
  Timestamp.fromDate(iso ? new Date(iso) : new Date(0));

// --- Row → type mappers ----------------------------------------------------

export function mapTicket(row: any): Ticket {
  return {
    id: row.id,
    eventId: row.event_id,
    orgId: row.org_id ?? undefined,
    buyerId: row.buyer_id,
    ownerId: row.owner_id,
    // organizerId is no longer load-bearing (RLS gates staff access by org
    // role, not this field). Surface the event creator when the event is
    // joined, else empty — kept only to satisfy the legacy Ticket shape.
    organizerId: row.event?.created_by ?? '',
    status: row.status,
    barcodeValue: '',
    barcodeSecret: row.barcode_secret ?? undefined,
    tierId: row.tier_id ?? undefined,
    tierName: row.tier_name ?? undefined,
    orderId: row.order_ref ?? undefined,
    pricePaid: row.price_paid != null ? Number(row.price_paid) : undefined,
    channelSource: (row.channel_source ?? undefined) as Ticket['channelSource'],
    promoterId: row.promoter_id ?? undefined,
    buyerEmail: row.buyer_email ?? undefined,
    transferId: row.transfer_id ?? undefined,
    pendingTransferId: row.pending_transfer_id ?? null,
    voidedAt: row.voided_at ? toTs(row.voided_at) : undefined,
    voidedBy: row.voided_by ?? undefined,
    voidedReason: row.voided_reason ?? undefined,
    purchaseDate: toTs(row.created_at),
    lastReissueDate: row.last_reissue_at ? toTs(row.last_reissue_at) : undefined,
    checkInDate: row.check_in_at ? toTs(row.check_in_at) : undefined,
  };
}

function mapTicketWithEvent(row: any): Ticket & { event?: Event } {
  const t = mapTicket(row);
  return { ...t, event: row.event ? mapEvent(row.event) : undefined };
}

export function mapTransfer(row: any): Transfer {
  return {
    id: row.id,
    ticketId: row.ticket_id,
    senderId: row.sender_id,
    senderEmail: row.sender_email ?? undefined,
    receiverEmail: row.receiver_email,
    status: row.status,
    createdAt: toTs(row.created_at),
    updatedAt: row.updated_at ? toTs(row.updated_at) : undefined,
    eventId: row.event_id ?? undefined,
    eventTitle: row.event_title ?? undefined,
    eventImage: row.event_image ?? undefined,
    tierName: row.tier_name ?? undefined,
    organizerId: row.organizer_id ?? undefined,
    orgId: row.org_id ?? undefined,
  };
}

const TICKET_WITH_EVENT = '*, event:exos_events(*)';

// --- Profile name lookups (no FK from tickets→profiles, so do it in two
//     steps rather than a PostgREST embed) ------------------------------------

async function fetchProfileNames(ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const unique = Array.from(new Set(ids.filter(Boolean)));
  if (unique.length === 0) return out;
  const { data } = await supabase
    .from('exos_profiles')
    .select('id, display_name')
    .in('id', unique);
  for (const p of data ?? []) out.set(p.id, p.display_name ?? '');
  return out;
}

// --- Buyer-facing reads ----------------------------------------------------

/** Tickets the current user OWNS, newest first, with the event joined. */
export async function listMyTickets(): Promise<(Ticket & { event?: Event })[]> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return [];
  const { data, error } = await supabase
    .from('exos_tickets')
    .select(TICKET_WITH_EVENT)
    .eq('owner_id', uid)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapTicketWithEvent);
}

/** A single ticket (owner/buyer/staff per RLS) with its event joined. */
export async function getTicket(ticketId: string): Promise<(Ticket & { event?: Event }) | null> {
  const { data, error } = await supabase
    .from('exos_tickets')
    .select(TICKET_WITH_EVENT)
    .eq('id', ticketId)
    .maybeSingle();
  if (error) throw error;
  return data ? mapTicketWithEvent(data) : null;
}

/** The current user's tickets for one event (the TicketDetail carousel). */
export async function listMyTicketsForEvent(eventId: string): Promise<Ticket[]> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return [];
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('*')
    .eq('owner_id', uid)
    .eq('event_id', eventId);
  if (error) throw error;
  return (data ?? []).map(mapTicket);
}

// --- Transfer reads --------------------------------------------------------

/** Pending transfers addressed to the current user's email (inbound claims). */
export async function listInboundTransfers(): Promise<Transfer[]> {
  const email = getCurrentAppUser()?.email?.toLowerCase();
  if (!email) return [];
  const { data, error } = await supabase
    .from('exos_transfers')
    .select('*')
    .eq('receiver_email', email)
    .eq('status', 'pending');
  if (error) throw error;
  return (data ?? []).map(mapTransfer);
}

/** Pending transfers the current user has sent (outbound, cancellable). */
export async function listOutboundTransfers(): Promise<Transfer[]> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return [];
  const { data, error } = await supabase
    .from('exos_transfers')
    .select('*')
    .eq('sender_id', uid)
    .eq('status', 'pending');
  if (error) throw error;
  return (data ?? []).map(mapTransfer);
}

export async function getTransfer(transferId: string): Promise<Transfer | null> {
  const { data, error } = await supabase
    .from('exos_transfers')
    .select('*')
    .eq('id', transferId)
    .maybeSingle();
  if (error) throw error;
  return data ? mapTransfer(data) : null;
}

// --- Organizer / staff reads (RLS: org-staff only) -------------------------

export type ScanTicket = Ticket & { ownerName: string };

/** Look up one ticket for the door scanner — includes barcode_secret (staff
 *  RLS) for HMAC verification + the owner's display name. */
export async function getTicketForScan(ticketId: string): Promise<ScanTicket | null> {
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('*')
    .eq('id', ticketId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const names = await fetchProfileNames([data.owner_id]);
  return { ...mapTicket(data), ownerName: names.get(data.owner_id) || 'Anonymous attendee' };
}

export interface RegistryEntry {
  id: string;
  status: Ticket['status'];
  ownerId: string;
  name: string;
  tier: string;
  barcodeSecret: string;
  promoterId: string;
  pendingTransferId: string | null;
}

/** Every ticket for an event, for the offline check-in registry (staff RLS). */
export async function listEventTicketsForRegistry(eventId: string): Promise<RegistryEntry[]> {
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('id, status, owner_id, tier_name, barcode_secret, promoter_id, pending_transfer_id')
    .eq('event_id', eventId);
  if (error) throw error;
  const rows = data ?? [];
  const names = await fetchProfileNames(rows.map((r: any) => r.owner_id));
  return rows.map((r: any) => ({
    id: r.id,
    status: r.status,
    ownerId: r.owner_id ?? '',
    name: names.get(r.owner_id) || 'Anonymous',
    tier: r.tier_name || 'Standard',
    barcodeSecret: r.barcode_secret || '',
    promoterId: r.promoter_id || '',
    pendingTransferId: r.pending_transfer_id ?? null,
  }));
}

/** All tickets for an event (event report). Staff RLS. */
export async function listEventTickets(eventId: string): Promise<Ticket[]> {
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('*')
    .eq('event_id', eventId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapTicket);
}

/** Tickets across every org the current user staffs (organizer dashboard
 *  sales chart). exos_tickets has no organizer_id, so we scope by the
 *  caller's active org memberships. */
export async function listMyOrgTickets(limit = 1000): Promise<Ticket[]> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return [];
  const { data: mems, error: mErr } = await supabase
    .from('exos_org_memberships')
    .select('org_id')
    .eq('user_id', uid)
    .neq('disabled', true);
  if (mErr) throw mErr;
  const orgIds = (mems ?? []).map((m: any) => m.org_id);
  if (orgIds.length === 0) return [];
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('*')
    .in('org_id', orgIds)
    .limit(limit);
  if (error) throw error;
  return (data ?? []).map(mapTicket);
}

/** Platform-wide ticket sample for the admin dashboard chart (RLS returns
 *  all rows only for platform admins). */
export async function listAllTickets(limit = 500): Promise<Ticket[]> {
  const { data, error } = await supabase
    .from('exos_tickets')
    .select('*')
    .limit(limit);
  if (error) throw error;
  return (data ?? []).map(mapTicket);
}

export interface CheckinRow {
  id: string;
  ticketId: string;
  scannedBy: string;
  source: string | null;
  verification: string | null;
  scannedAt: Timestamp;
}

export async function listEventCheckins(eventId: string): Promise<CheckinRow[]> {
  const { data, error } = await supabase
    .from('exos_event_checkins')
    .select('*')
    .eq('event_id', eventId)
    .order('scanned_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id,
    ticketId: r.ticket_id,
    scannedBy: r.scanned_by,
    source: r.source,
    verification: r.verification,
    scannedAt: toTs(r.scanned_at),
  }));
}

export interface ScanRejectRow {
  id: string;
  reason: string;
  source: string;
  ticketIdAttempted: string | null;
  wrongEventId: string | null;
  wrongEventTitle: string | null;
  reasonDetail: string | null;
  rejectedAt: Timestamp;
}

export async function listEventScanRejects(eventId: string): Promise<ScanRejectRow[]> {
  const { data, error } = await supabase
    .from('exos_scan_rejects')
    .select('*')
    .eq('event_id', eventId)
    .order('rejected_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id,
    reason: r.reason,
    source: r.source,
    ticketIdAttempted: r.ticket_id_attempted,
    wrongEventId: r.wrong_event_id,
    wrongEventTitle: r.wrong_event_title,
    reasonDetail: r.reason_detail,
    rejectedAt: toTs(r.rejected_at),
  }));
}

// --- Mutations (SECURITY DEFINER RPCs) -------------------------------------

export type ScanReason =
  | 'wrong-event' | 'voided' | 'used' | 'in-transfer'
  | 'invalid-barcode' | 'not-found' | 'expired-code';

export interface CheckInResult {
  ok: boolean;
  reason: string;
}

/** Atomic check-in (status flip + audit). Returns {ok,reason}; reason is one
 *  of 'checked-in' | 'used' | 'voided' | 'in-transfer' | 'not-found'. */
export async function checkInTicket(
  ticketId: string,
  source: 'camera' | 'manual',
  verification: 'verified' | 'legacy' | 'manual',
): Promise<CheckInResult> {
  const { data, error } = await supabase.rpc('exos_check_in_ticket', {
    p_ticket_id: ticketId,
    p_source: source,
    p_verification: verification,
  });
  if (error) throw error;
  return (data ?? { ok: false, reason: 'not-found' }) as CheckInResult;
}

/** Append a scan-rejection audit row (direct INSERT, staff RLS). Best-effort
 *  at the call site, same as the Firestore writeScanReject. */
export async function recordScanReject(input: {
  eventId: string;
  orgId: string;
  reason: ScanReason;
  source: 'camera' | 'manual';
  ticketIdAttempted?: string | null;
  wrongEventId?: string | null;
  wrongEventTitle?: string | null;
  reasonDetail?: string | null;
}): Promise<void> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return;
  const { error } = await supabase.from('exos_scan_rejects').insert({
    event_id: input.eventId,
    org_id: input.orgId,
    rejected_by: uid,
    reason: input.reason,
    source: input.source,
    ticket_id_attempted: input.ticketIdAttempted
      ? String(input.ticketIdAttempted).slice(0, 256)
      : null,
    wrong_event_id: input.wrongEventId ?? null,
    wrong_event_title: input.wrongEventTitle ? String(input.wrongEventTitle).slice(0, 200) : null,
    reason_detail: input.reasonDetail ? String(input.reasonDetail).slice(0, 200) : null,
  });
  if (error) throw error;
}

/** Create a pending transfer + lock the ticket. Returns the transfer id. */
export async function createTransfer(ticketId: string, receiverEmail: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_create_transfer', {
    p_ticket_id: ticketId,
    p_receiver_email: receiverEmail,
  });
  if (error) throw error;
  return data as string;
}

export async function cancelTransfer(transferId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_cancel_transfer', { p_transfer_id: transferId });
  if (error) throw error;
}

/** Claim a transfer: take ownership + rotate the barcode secret. Returns the
 *  claimed ticket id. */
export async function claimTransfer(transferId: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_claim_transfer', { p_transfer_id: transferId });
  if (error) throw error;
  return data as string;
}

export async function voidTicket(ticketId: string, reason?: string): Promise<void> {
  const { error } = await supabase.rpc('exos_void_ticket', {
    p_ticket_id: ticketId,
    p_reason: reason ?? null,
  });
  if (error) throw error;
}

/** Mint tickets directly (comp / admin test-mint). Returns the new ticket ids.
 *  Org-staff or admin only (enforced in the RPC). */
export async function mintTickets(input: {
  eventId: string;
  tierId?: string | null;
  quantity?: number;
  orderRef?: string | null;
  pricePaid?: number | null;
  promoterId?: string | null;
}): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_mint_tickets', {
    p_event_id: input.eventId,
    p_tier_id: input.tierId ?? null,
    p_quantity: input.quantity ?? 1,
    p_order_ref: input.orderRef ?? null,
    p_price_paid: input.pricePaid ?? null,
    p_promoter_id: input.promoterId ?? null,
  });
  if (error) throw error;
  return (data ?? []) as string[];
}
