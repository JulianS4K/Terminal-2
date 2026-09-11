// Organizer campaigns (Stage 5, mig 20260911140000) — RPC wrappers.
//
// Audiences resolve server-side at send; opt-outs are honoured per org; the
// cron sends scheduled rows. SMS is accepted at save but the send RPC refuses
// it until a provider is configured (operator decision). Pure model:
// ./campaignsModel.ts.

import { supabase } from './supabase';
import { publicUrl } from './utils';
import { mapCampaign, type AudienceKind, type Campaign, type CampaignChannel } from './campaignsModel';

export * from './campaignsModel';

export async function listCampaigns(input: { orgId: string; eventId?: string | null }): Promise<Campaign[]> {
  let q = supabase.from('exos_campaigns').select('*').eq('org_id', input.orgId).order('created_at', { ascending: false });
  if (input.eventId) q = q.eq('event_id', input.eventId);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []).map(mapCampaign);
}

export async function countAudience(input: { orgId: string; eventId?: string | null; kind: AudienceKind }): Promise<number> {
  const { data, error } = await supabase.rpc('exos_campaign_audience_count', {
    p_org_id: input.orgId,
    p_event_id: input.eventId ?? null,
    p_audience: { kind: input.kind },
  });
  if (error) throw error;
  return Number(data) || 0;
}

export async function saveCampaign(input: {
  id?: string | null;
  orgId: string;
  eventId?: string | null;
  name: string;
  channel: CampaignChannel;
  kind: AudienceKind;
  subject: string;
  body: string;
  scheduledAt?: Date | null;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_campaign_save', {
    p_id: input.id ?? null,
    p_org_id: input.orgId,
    p_event_id: input.eventId ?? null,
    p_name: input.name,
    p_channel: input.channel,
    p_audience: { kind: input.kind },
    p_subject: input.subject,
    p_body: input.body,
    p_scheduled_at: input.scheduledAt ? input.scheduledAt.toISOString() : null,
  });
  if (error) throw error;
  return String(data);
}

/** Send now. The base URL for the unsubscribe link is this app's own origin. */
export async function sendCampaign(id: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_campaign_send', {
    p_id: id,
    p_base_url: publicUrl('/'),
  });
  if (error) throw error;
  return Number(data) || 0;
}

export async function cancelCampaign(id: string): Promise<void> {
  const { error } = await supabase.rpc('exos_campaign_cancel', { p_id: id });
  if (error) throw error;
}

/** Public (anon) opt-out by the token from an email footer. Returns a masked email. */
export async function marketingOptOut(token: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_marketing_optout', { p_token: token });
  if (error) throw error;
  return String(data ?? '');
}
