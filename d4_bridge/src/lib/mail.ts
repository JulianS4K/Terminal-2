import { supabase } from './supabase';

// Thin wrapper around the Supabase exos_queue_mail() SECDEF RPC.
//
// The RPC SERVER-DERIVES to_email, subject, and html from the related
// record (transfer / invite / ticket) — the client only supplies the
// template name and the UUID of the related record. This closes the open
// mail-relay risk (B1 SEC-HIGH, bot_chat #438, mig 20260520160000).
//
// Best-effort (never throws). Until the exos_mail schema migration lands,
// calls fail silently — same behaviour as the previous Firebase Trigger
// Email queue when the extension wasn't wired.
//
// Template → refId mapping:
//   transfer-initiated  refId = exos_transfers.id   (caller = sender)
//   transfer-claimed    refId = exos_transfers.id   (caller = receiver; notifies sender)
//   org-invite          refId = exos_org_invites.id (caller = inviter)
//   event-cancelled     refId = exos_tickets.id     (caller = org staff)
//   event-updated       refId = exos_tickets.id     (caller = org staff)

export type MailTemplate =
  | 'transfer-initiated'
  | 'transfer-claimed'
  | 'org-invite'
  | 'event-cancelled'
  | 'event-updated';

interface QueueOptions {
  template: MailTemplate;
  /** UUID of the related record (transfer / invite / ticket). */
  refId?: string | null;
}

/**
 * Best-effort enqueue of a transactional email via the exos_queue_mail RPC.
 * Never throws — the caller shouldn't wrap this in try/catch.
 */
export async function queueEmail(opts: QueueOptions): Promise<void> {
  try {
    const { error } = await supabase.rpc('exos_queue_mail', {
      p_template: opts.template,
      p_ref_id:   opts.refId ?? null,
    });
    if (error) {
      // Non-fatal: migration may not be applied yet, or ref lookup failed.
      console.warn('queueEmail failed (non-fatal):', error.message);
    }
  } catch (err) {
    console.warn('queueEmail failed (non-fatal):', err);
  }
}

/**
 * Light HTML escaper for user-provided strings in UI copy.
 * Mail bodies are now server-rendered; this is kept for any UI contexts
 * that still need it (e.g. toast messages with user-supplied content).
 */
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
