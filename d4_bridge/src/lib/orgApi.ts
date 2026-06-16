// Org developer surface — API keys + outbound webhooks (Hi.Events parity).
//
// API keys are managed only through SECDEF RPCs (the plaintext is returned once
// at creation and never again — only a hash is stored). Webhooks are managed
// directly via staff RLS on exos_webhooks.

import { supabase } from './supabase';

export interface ApiKey {
  id: string;
  name: string | null;
  keyPrefix: string;
  scopes: string[];
  lastUsedAt: string | null;
  revokedAt: string | null;
  createdAt: string;
}

export interface Webhook {
  id: string;
  orgId: string;
  url: string;
  secret: string;
  eventTypes: string[];
  enabled: boolean;
  description: string | null;
  createdAt: string;
}

export const WEBHOOK_EVENT_TYPES = [
  'ticket.created',
  'ticket.checked_in',
  'order.fulfilled',
  'order.refunded',
  'event.published',
] as const;

/** Create an API key; returns the plaintext ONCE (store it now — irrecoverable). */
export async function createApiKey(orgId: string, name?: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_create_api_key', { p_org_id: orgId, p_name: name ?? null });
  if (error) throw error;
  return data as string;
}

export async function revokeApiKey(keyId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_revoke_api_key', { p_key_id: keyId });
  if (error) throw error;
  return data === true;
}

export async function listApiKeys(orgId: string): Promise<ApiKey[]> {
  const { data, error } = await supabase.rpc('exos_list_api_keys', { p_org_id: orgId });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, name: r.name, keyPrefix: r.key_prefix, scopes: r.scopes ?? [],
    lastUsedAt: r.last_used_at, revokedAt: r.revoked_at, createdAt: r.created_at,
  }));
}

function mapWebhook(r: any): Webhook {
  return {
    id: r.id, orgId: r.org_id, url: r.url, secret: r.secret,
    eventTypes: r.event_types ?? ['*'], enabled: r.enabled,
    description: r.description ?? null, createdAt: r.created_at,
  };
}

export async function listWebhooks(orgId: string): Promise<Webhook[]> {
  const { data, error } = await supabase
    .from('exos_webhooks').select('*').eq('org_id', orgId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapWebhook);
}

export async function createWebhook(orgId: string, url: string, eventTypes: string[]): Promise<Webhook> {
  const { data, error } = await supabase
    .from('exos_webhooks')
    .insert({ org_id: orgId, url: url.trim(), event_types: eventTypes.length ? eventTypes : ['*'] })
    .select('*').single();
  if (error) throw error;
  return mapWebhook(data);
}

export async function setWebhookEnabled(id: string, enabled: boolean): Promise<void> {
  const { error } = await supabase.from('exos_webhooks').update({ enabled }).eq('id', id);
  if (error) throw error;
}

export async function deleteWebhook(id: string): Promise<void> {
  const { error } = await supabase.from('exos_webhooks').delete().eq('id', id);
  if (error) throw error;
}
