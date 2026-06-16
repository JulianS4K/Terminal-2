// Invoices (pretix-style) — read-only list for buyer (own) + organizer (org).
// Records are generated server-side on fulfillment; this just reads them.

import { supabase } from './supabase';

export interface Invoice {
  id: string;
  number: string;
  eventId: string | null;
  sessionId: string | null;
  buyerEmail: string | null;
  currency: string;
  subtotalCents: number;
  taxCents: number;
  totalCents: number;
  status: 'issued' | 'refunded' | 'cancelled';
  issuedAt: string;
}

function mapInvoice(r: any): Invoice {
  return {
    id: r.id, number: r.number, eventId: r.event_id, sessionId: r.session_id,
    buyerEmail: r.buyer_email, currency: r.currency,
    subtotalCents: r.subtotal_cents, taxCents: r.tax_cents, totalCents: r.total_cents,
    status: r.status, issuedAt: r.issued_at,
  };
}

/** The signed-in buyer's own invoices (RLS: buyer_id = auth.uid()). */
export async function listMyInvoices(): Promise<Invoice[]> {
  const { data, error } = await supabase
    .from('exos_invoices').select('*').order('issued_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapInvoice);
}

/** An org's invoices (RLS: org staff). */
export async function listOrgInvoices(orgId: string): Promise<Invoice[]> {
  const { data, error } = await supabase
    .from('exos_invoices').select('*').eq('org_id', orgId)
    .order('issued_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapInvoice);
}
