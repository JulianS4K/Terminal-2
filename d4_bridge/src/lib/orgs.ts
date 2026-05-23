// Bridge multi-tenant org primitives.
//
// The single seam between the rest of the app and the org data store. As of
// the Supabase migration (docs/d4_bridge_charter.md) this talks to the exos_*
// tables via supabase-js instead of Firestore. Function signatures + return
// types are unchanged so OrganizationContext and the views are drop-in.
//
// Row→type mapping converts Postgres timestamptz strings to Firestore
// `Timestamp` (still imported transitionally) so the existing Organization /
// OrgMembership shapes in src/types.ts keep working until those are de-Firebased.

import { Timestamp } from './timestamp';
import { supabase } from './supabase';
import { Organization, OrgMembership, OrgRole } from '../types';

// --- Slug helpers (pure) ---------------------------------------------------

const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,79}$/;

export function isValidOrgSlug(slug: string): boolean {
  return typeof slug === 'string' && SLUG_RE.test(slug);
}

/** Normalize a free-text name into a slug candidate. */
export function slugify(name: string): string {
  return name
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .slice(0, 80)
    .replace(/^-+|-+$/g, '');
}

// --- Row → type mappers ----------------------------------------------------

const toTs = (iso: string | null | undefined): Timestamp =>
  Timestamp.fromDate(iso ? new Date(iso) : new Date(0));

function mapOrg(row: any, secrets?: any): Organization {
  return {
    id: row.id,
    name: row.name,
    slug: row.slug,
    ownerUid: row.owner_uid,
    createdAt: toTs(row.created_at),
    updatedAt: row.updated_at ? toTs(row.updated_at) : undefined,
    description: row.description ?? undefined,
    followersCount: row.followers_count ?? 0,
    theme: row.theme ?? undefined,
    // payments/distribution live in exos_org_secrets (owner/finance RLS); absent
    // for non-privileged readers.
    payments: secrets?.payments ?? undefined,
    distribution: secrets?.distribution ?? undefined,
  };
}

function mapMembership(row: any): OrgMembership {
  return {
    id: row.id,
    orgId: row.org_id,
    uid: row.user_id,
    role: row.role,
    addedAt: toTs(row.created_at),
    addedBy: row.added_by,
    disabled: row.disabled ?? undefined,
  };
}

// --- Create (via SECURITY DEFINER RPC — bootstraps owner membership) -------

export interface CreateOrgInput {
  name: string;
  slug: string; // Must already be normalized and validated.
  ownerUid: string; // Retained for signature compat; the RPC derives owner from auth.uid().
}

export async function createOrganization(input: CreateOrgInput): Promise<{ orgId: string }> {
  const { name, slug } = input;
  if (!isValidOrgSlug(slug)) {
    throw new Error(`Invalid org slug: ${slug}`);
  }
  if (!name || name.length === 0 || name.length > 100) {
    throw new Error('Org name must be 1-100 characters.');
  }
  const { data, error } = await supabase.rpc('exos_create_org', { p_name: name, p_slug: slug });
  if (error) throw error;
  return { orgId: data as string };
}

// --- Read paths ------------------------------------------------------------

export async function getOrganization(orgId: string): Promise<Organization | null> {
  const { data, error } = await supabase.from('exos_orgs').select('*').eq('id', orgId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  // Best-effort secrets — RLS returns nothing for non owner/finance callers.
  const { data: secrets } = await supabase
    .from('exos_org_secrets')
    .select('payments, distribution')
    .eq('org_id', orgId)
    .maybeSingle();
  return mapOrg(data, secrets);
}

/** Resolve an org by its slug. Returns null when the slug isn't taken. */
export async function getOrganizationBySlug(slug: string): Promise<Organization | null> {
  const { data, error } = await supabase.from('exos_orgs').select('*').eq('slug', slug).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return mapOrg(data);
}

// Public org reads via exos_public_orgs (anon-safe — name/slug/theme only, no
// owner_uid/secrets). For public surfaces (storefront, embed) where the viewer
// may be anonymous and can't read the exos_orgs base table.
function mapPublicOrg(row: any): Organization {
  return {
    id: row.id, name: row.name, slug: row.slug, ownerUid: '', createdAt: toTs(null),
    description: row.description ?? undefined, followersCount: row.followers_count ?? 0,
    theme: row.theme ?? undefined,
  };
}

export async function getPublicOrg(orgId: string): Promise<Organization | null> {
  const { data, error } = await supabase.from('exos_public_orgs').select('*').eq('id', orgId).maybeSingle();
  if (error) throw error;
  return data ? mapPublicOrg(data) : null;
}

export async function getPublicOrgBySlug(slug: string): Promise<Organization | null> {
  const { data, error } = await supabase.from('exos_public_orgs').select('*').eq('slug', slug).maybeSingle();
  if (error) throw error;
  return data ? mapPublicOrg(data) : null;
}

// --- Follow graph (org-level; backs OrganizerProfile) ----------------------

/** Follow an org. Idempotent — a double-follow is a server-side no-op and
 *  never double-counts (the RPC bumps followers_count only on a real insert). */
export async function followOrg(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_follow_org', { p_org_id: orgId });
  if (error) throw error;
}

/** Unfollow an org. Idempotent (no-op + no under-count if not following). */
export async function unfollowOrg(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_unfollow_org', { p_org_id: orgId });
  if (error) throw error;
}

/** Whether the current user follows this org. RLS scopes the row to the caller,
 *  so this only ever returns the caller's own follow edge. */
export async function isFollowingOrg(orgId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('exos_org_follows')
    .select('org_id')
    .eq('org_id', orgId)
    .maybeSingle();
  if (error) throw error;
  return !!data;
}

/**
 * List the orgs the given user belongs to via active (non-disabled)
 * memberships. Returns the membership + the resolved org doc per row.
 */
export async function listOrgsForUser(
  uid: string,
): Promise<{ org: Organization; membership: OrgMembership }[]> {
  const { data, error } = await supabase
    .from('exos_org_memberships')
    .select('*, org:exos_orgs(*)')
    .eq('user_id', uid)
    .neq('disabled', true);
  if (error) throw error;
  const out = (data ?? [])
    .filter((r: any) => r.org)
    .map((r: any) => ({ org: mapOrg(r.org), membership: mapMembership(r) }));
  out.sort((a, b) => a.org.name.localeCompare(b.org.name));
  return out;
}

/** List all members of an org. Owner/manager-only via RLS. */
export async function listOrgMembers(orgId: string): Promise<OrgMembership[]> {
  const { data, error } = await supabase
    .from('exos_org_memberships')
    .select('*')
    .eq('org_id', orgId);
  if (error) throw error;
  return (data ?? []).map(mapMembership);
}

// --- Member management -----------------------------------------------------

export interface AddMemberInput {
  orgId: string;
  uid: string;
  role: OrgRole;
  addedBy: string;
}

export async function addOrgMember(input: AddMemberInput): Promise<void> {
  const { orgId, uid, role, addedBy } = input;
  if (role === 'owner') {
    throw new Error('Granting org ownership requires admin tooling.');
  }
  const { error } = await supabase
    .from('exos_org_memberships')
    .insert({ org_id: orgId, user_id: uid, role, added_by: addedBy });
  if (error) throw error;
}

export async function updateOrgMemberRole(orgId: string, uid: string, role: OrgRole): Promise<void> {
  const { error } = await supabase
    .from('exos_org_memberships')
    .update({ role })
    .eq('org_id', orgId)
    .eq('user_id', uid);
  if (error) throw error;
}

export async function disableOrgMember(orgId: string, uid: string): Promise<void> {
  const { error } = await supabase
    .from('exos_org_memberships')
    .update({ disabled: true })
    .eq('org_id', orgId)
    .eq('user_id', uid);
  if (error) throw error;
}

export async function enableOrgMember(orgId: string, uid: string): Promise<void> {
  const { error } = await supabase
    .from('exos_org_memberships')
    .update({ disabled: false })
    .eq('org_id', orgId)
    .eq('user_id', uid);
  if (error) throw error;
}

// --- Org updates (theme on the org row; payments/distribution in secrets) --

export interface OrgUpdatePatch {
  name?: string;
  theme?: Organization['theme'];
  payments?: Organization['payments'];
  distribution?: Organization['distribution'];
}

export async function updateOrganization(orgId: string, patch: OrgUpdatePatch): Promise<void> {
  const orgFields: Record<string, unknown> = {};
  if (patch.name !== undefined) orgFields.name = patch.name;
  if (patch.theme !== undefined) orgFields.theme = stripUndefined(patch.theme);
  if (Object.keys(orgFields).length > 0) {
    const { error } = await supabase.from('exos_orgs').update(orgFields).eq('id', orgId);
    if (error) throw error;
  }
  // payments/distribution route to the secrets sidecar (owner-only RLS).
  if (patch.payments !== undefined || patch.distribution !== undefined) {
    const secretFields: Record<string, unknown> = { org_id: orgId };
    if (patch.payments !== undefined) secretFields.payments = stripUndefined(patch.payments);
    if (patch.distribution !== undefined) secretFields.distribution = stripUndefined(patch.distribution);
    const { error } = await supabase
      .from('exos_org_secrets')
      .upsert(secretFields, { onConflict: 'org_id' });
    if (error) throw error;
  }
}

function stripUndefined<T extends Record<string, unknown> | undefined>(obj: T): T {
  if (!obj) return obj;
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(obj)) {
    const v = (obj as Record<string, unknown>)[k];
    if (v !== undefined) out[k] = v;
  }
  return out as T;
}

// --- Role resolution + helpers (pure) --------------------------------------

export async function getUserRoleInOrg(orgId: string, uid: string): Promise<OrgRole | null> {
  const { data, error } = await supabase
    .from('exos_org_memberships')
    .select('role, disabled')
    .eq('org_id', orgId)
    .eq('user_id', uid)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.disabled === true) return null;
  return data.role as OrgRole;
}

export const ROLE_RANK: Record<OrgRole, number> = {
  owner: 5,
  manager: 4,
  finance: 3,
  content: 2,
  scanner: 1,
};

export function roleAtLeast(holder: OrgRole | null | undefined, min: OrgRole): boolean {
  if (!holder) return false;
  return ROLE_RANK[holder] >= ROLE_RANK[min];
}

export function canEditEvents(role: OrgRole | null | undefined): boolean {
  return roleAtLeast(role, 'content');
}

export function canManageEvents(role: OrgRole | null | undefined): boolean {
  return roleAtLeast(role, 'manager');
}

export function canRunCheckIn(role: OrgRole | null | undefined): boolean {
  if (!role) return false;
  return role === 'scanner' || role === 'manager' || role === 'owner';
}

export function canManageOrg(role: OrgRole | null | undefined): boolean {
  return role === 'owner';
}

// --- Email-based invites ---------------------------------------------------

export interface CreateInviteInput {
  orgId: string;
  email: string;
  role: OrgRole;
  createdBy: string;
  expiresInMs?: number;
}

const DEFAULT_INVITE_TTL_MS = 14 * 24 * 60 * 60 * 1000;

export async function createOrgInvite(
  input: CreateInviteInput,
): Promise<{ id: string; token: string; inviteUrl: string }> {
  const { orgId, email, role, createdBy } = input;
  if (role === 'owner') {
    throw new Error('Owner role cannot be granted via invite — use admin tooling.');
  }
  if (!email || !email.includes('@')) {
    throw new Error('Provide a valid email address.');
  }
  const lowered = email.trim().toLowerCase();
  const expiresAt = new Date(Date.now() + (input.expiresInMs ?? DEFAULT_INVITE_TTL_MS)).toISOString();

  const { data, error } = await supabase
    .from('exos_org_invites')
    .insert({ org_id: orgId, email: lowered, role, created_by: createdBy, expires_at: expiresAt, status: 'pending' })
    .select('id, token')
    .single();
  if (error) throw error;

  const origin = typeof window !== 'undefined' ? window.location.origin : '';
  const inviteUrl = `${origin}/invite/${data.token}`;
  return { id: data.id as string, token: data.token as string, inviteUrl };
}

export async function listOrgInvites(orgId: string): Promise<
  Array<{ token: string; email: string; role: OrgRole; status: string; createdAt?: Timestamp; expiresAt?: Timestamp }>
> {
  const { data, error } = await supabase
    .from('exos_org_invites')
    .select('*')
    .eq('org_id', orgId);
  if (error) throw error;
  return (data ?? []).map((d: any) => ({
    token: d.token,
    email: d.email,
    role: d.role,
    status: d.status,
    createdAt: d.created_at ? toTs(d.created_at) : undefined,
    expiresAt: d.expires_at ? toTs(d.expires_at) : undefined,
  }));
}

export async function cancelOrgInvite(token: string): Promise<void> {
  const { error } = await supabase
    .from('exos_org_invites')
    .update({ status: 'cancelled' })
    .eq('token', token);
  if (error) throw error;
}

export async function getOrgInvite(token: string) {
  const { data, error } = await supabase
    .from('exos_org_invites')
    .select('*')
    .eq('token', token)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return { token: data.token, ...data };
}

/**
 * Claim a pending invite. Routed through the SECURITY DEFINER `exos_claim_invite`
 * RPC, which verifies the caller's confirmed email matches the invite, inserts
 * the membership, and marks the invite completed — atomically. (The other args
 * are retained for signature compat; the RPC derives everything from the token
 * + auth.uid().)
 */
export async function claimOrgInvite(args: {
  token: string;
  orgId: string;
  role: OrgRole;
  uid: string;
}): Promise<void> {
  const { error } = await supabase.rpc('exos_claim_invite', { p_token: args.token });
  if (error) throw error;
}
