import type { User as SupabaseUser } from '@supabase/supabase-js';

// App-facing user shape. Mirrors the subset of the old Firebase `User` the app
// consumed (uid / email / displayName / photoURL / emailVerified) so the swap
// to Supabase Auth is drop-in for the ~20 views that read `useAuth().user`.
export interface AppUser {
  uid: string;
  email: string | null;
  displayName: string | null;
  photoURL: string | null;
  emailVerified: boolean;
}

export function toAppUser(u: SupabaseUser | null | undefined): AppUser | null {
  if (!u) return null;
  const meta = (u.user_metadata ?? {}) as Record<string, any>;
  return {
    uid: u.id,
    email: u.email ?? null,
    displayName: meta.display_name ?? meta.name ?? meta.full_name ?? null,
    photoURL: meta.avatar_url ?? meta.picture ?? null,
    emailVerified: !!u.email_confirmed_at,
  };
}

// Supabase `app_metadata` is set server-side (service role) and is unforgeable
// from the client — the analogue of the old Firebase `admin` custom claim.
export function isAdminUser(u: SupabaseUser | null | undefined): boolean {
  return ((u?.app_metadata ?? {}) as Record<string, any>).admin === true;
}

// Lightweight current-user holder so non-React modules (e.g. error logging in
// lib/utils.ts) can read auth context without a global auth singleton.
let _current: AppUser | null = null;
export function setCurrentAppUser(u: AppUser | null) {
  _current = u;
}
export function getCurrentAppUser(): AppUser | null {
  return _current;
}
