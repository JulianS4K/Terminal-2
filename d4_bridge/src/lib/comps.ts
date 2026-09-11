// Group sales / comp allocations (Stage 3, mig 20260911132000).
//
// Thin wrappers over the SECDEF RPCs: bulk comp issuance to an email list
// (owner / manager / admin), the per-org comp usage read, and the owner-only
// budget setter. Everything is enforced server-side; these only shape the
// result rows.

import { supabase } from './supabase';
import type { CompBatchRow, CompOutcome } from './compsModel';

export * from './compsModel';

export async function issueCompBatch(input: {
  eventId: string;
  tierId?: string | null;
  emails: string[];
  qtyEach?: number;
  promoterId?: string | null;
}): Promise<CompBatchRow[]> {
  const { data, error } = await supabase.rpc('exos_issue_comp_batch', {
    p_event_id: input.eventId,
    p_tier_id: input.tierId ?? null,
    p_emails: input.emails,
    p_qty_each: input.qtyEach ?? 1,
    p_promoter_id: input.promoterId ?? null,
  });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    email: String(r.email ?? ''),
    outcome: (r.outcome ?? 'invalid') as CompOutcome,
    ticketIds: (r.ticket_ids ?? []) as string[],
    detail: r.detail ?? null,
  }));
}

/** Non-voided free comp tickets issued by the org (staff read). */
export async function getOrgCompUsage(orgId: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_org_comp_usage', { p_org_id: orgId });
  if (error) throw error;
  return Number(data) || 0;
}

/** Owner / admin: set (or clear with null) the org's comp budget. */
export async function setOrgCompBudget(orgId: string, budget: number | null): Promise<void> {
  const { error } = await supabase.rpc('exos_set_org_comp_budget', {
    p_org_id: orgId,
    p_budget: budget,
  });
  if (error) throw error;
}
