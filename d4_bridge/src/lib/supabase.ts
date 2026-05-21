import { createClient } from '@supabase/supabase-js';

// Supabase client for Exos (D4). Replaces the Firebase/Firestore data layer
// — migration in progress, see docs/d4_bridge_charter.md. The anon key is a
// public client identifier (like the Firebase web apiKey); row access is
// enforced by RLS on the exos_* tables, not by hiding this key.
//
// Env access mirrors src/lib/stripe.ts: `(import.meta as any).env` so we don't
// need a vite/client type reference in tsconfig.
const url = (import.meta as any).env?.VITE_SUPABASE_URL as string | undefined;
const anonKey = (import.meta as any).env?.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !anonKey) {
  console.warn(
    'VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY not set — Supabase calls will fail.',
  );
}

export const supabase = createClient(url ?? '', anonKey ?? '', {
  auth: {
    // Persist the session in localStorage and refresh it transparently so
    // organizers/buyers stay signed in across reloads (parity with Firebase
    // Auth's persistence).
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
