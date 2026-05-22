import { supabase } from './supabase';
import { getCurrentAppUser } from './auth';

// Transactional email queue (Supabase). queueEmail inserts a pending row into
// public.exos_mail (migration 20260520160000); a downstream drainer — an edge
// function / cron + an email provider — sends it and flips status. Until that
// drainer is wired, rows just accumulate as 'pending' (the same decoupling the
// old Firebase "Trigger Email" extension gave us). We catch errors so the
// calling flow never fails on a queue-write rejection — the exos_mail RLS is
// intentionally narrow (authenticated-insert only, template-whitelisted,
// size-capped via CHECK constraints).

export type MailTemplate = 'transfer-initiated' | 'transfer-claimed' | 'org-invite' | 'event-cancelled' | 'event-updated';

interface QueueOptions {
  to: string;
  subject: string;
  html: string;
  template: MailTemplate;
}

/**
 * Best-effort enqueue of a transactional email. Never throws — the caller
 * shouldn't have to wrap this in try/catch. The row lands as status 'pending';
 * delivery happens out-of-band (a service-role drainer), so a queue-write here
 * is decoupled from the actual send.
 */
export async function queueEmail(opts: QueueOptions): Promise<void> {
  try {
    const { error } = await supabase.from('exos_mail').insert({
      to_email: opts.to.trim().toLowerCase(),
      template: opts.template,
      subject: opts.subject,
      html: opts.html,
      created_by: getCurrentAppUser()?.uid ?? null,
    });
    if (error) throw error;
  } catch (err) {
    // Common when the row violates a CHECK/RLS, when offline, or when called
    // outside an authenticated context. We log but never propagate.
    console.warn('queueEmail failed (non-fatal):', err);
  }
}

/**
 * Light HTML escaper for inserting user-provided strings into our
 * template bodies. This isn't a substitute for a real templating system
 * but keeps the queued email payload safe from accidental injection
 * when the recipient mail client renders the HTML.
 */
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
