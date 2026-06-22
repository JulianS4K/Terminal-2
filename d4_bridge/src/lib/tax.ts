// Tax rules (pretix-style) — reusable per-event rates assignable to tiers + add-ons.

import { supabase } from './supabase';

export interface TaxRule {
  id: string;
  name: string;
  ratePercent: number;
  priceIncludesTax: boolean;
}

export interface TaxableProduct {
  id: string;
  name: string;
  taxRateId: string | null;
  kind: 'tier' | 'addon';
}

export async function listTaxRules(eventId: string): Promise<TaxRule[]> {
  const { data, error } = await supabase
    .from('exos_tax_rules').select('*').eq('event_id', eventId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, name: r.name, ratePercent: Number(r.rate_percent), priceIncludesTax: r.price_includes_tax,
  }));
}

export async function saveTaxRule(eventId: string, input: { id?: string; name: string; ratePercent: number; priceIncludesTax: boolean }): Promise<void> {
  const row = {
    event_id: eventId,
    name: input.name.trim(),
    rate_percent: Math.max(0, Math.min(100, Number(input.ratePercent) || 0)),
    price_includes_tax: input.priceIncludesTax,
  };
  if (input.id) {
    const { error } = await supabase.from('exos_tax_rules').update(row).eq('id', input.id);
    if (error) throw error;
  } else {
    const { error } = await supabase.from('exos_tax_rules').insert(row);
    if (error) throw error;
  }
}

export async function deleteTaxRule(id: string): Promise<void> {
  const { error } = await supabase.from('exos_tax_rules').delete().eq('id', id);
  if (error) throw error;
}

/** Tiers + add-ons for the event, with their current tax-rule assignment. */
export async function listTaxableProducts(eventId: string): Promise<TaxableProduct[]> {
  const [tiers, addons] = await Promise.all([
    supabase.from('exos_ticket_tiers').select('id, name, tax_rate_id').eq('event_id', eventId).order('sort_order', { ascending: true }),
    supabase.from('exos_event_addons').select('id, name, tax_rate_id').eq('event_id', eventId).order('sort_order', { ascending: true }),
  ]);
  if (tiers.error) throw tiers.error;
  if (addons.error) throw addons.error;
  return [
    ...(tiers.data ?? []).map((r: any) => ({ id: r.id, name: r.name, taxRateId: r.tax_rate_id, kind: 'tier' as const })),
    ...(addons.data ?? []).map((r: any) => ({ id: r.id, name: r.name, taxRateId: r.tax_rate_id, kind: 'addon' as const })),
  ];
}

export async function setProductTaxRule(product: TaxableProduct, ruleId: string | null): Promise<void> {
  const table = product.kind === 'tier' ? 'exos_ticket_tiers' : 'exos_event_addons';
  const { error } = await supabase.from(table).update({ tax_rate_id: ruleId }).eq('id', product.id);
  if (error) throw error;
}
