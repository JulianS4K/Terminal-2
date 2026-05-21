import { addDoc, collection, serverTimestamp } from 'firebase/firestore';
import { db } from './firebase';

// Thin wrapper around the Firebase Trigger Email extension.
// https://extensions.dev/extensions/firebase/firestore-send-email
//
// Setup: install the extension and point it at the `mail` collection.
// Until that's done, calls below succeed (they just write a doc); the
// extension is what actually sends the email. We catch errors so the
// calling flow doesn't fail when the queue write is rejected — the
// Firestore rule for `mail` is intentionally narrow.

export type MailTemplate = 'transfer-initiated' | 'transfer-claimed' | 'org-invite' | 'event-cancelled' | 'event-updated';

interface QueueOptions {
  to: string;
  subject: string;
  html: string;
  template: MailTemplate;
}

/**
 * Best-effort enqueue of a transactional email. Never throws — the caller
 * shouldn't have to wrap this in try/catch.
 *
 * Why the wire field is `templateName` (not `template`):
 * The Firebase Trigger Email extension treats a top-level `template` field
 * as template-mode rendering — it expects `template: { name, data }` and
 * looks up the named template in a dedicated Firestore templates
 * collection. Our value was a STRING (e.g. 'transfer-initiated') which
 * the extension would either fail to parse or use to look up a template
 * that doesn't exist, dropping the email on the floor. We keep our
 * own internal label under a different field so the extension only sees
 * `to` + `message: {subject, html}` and runs in direct mode.
 */
export async function queueEmail(opts: QueueOptions): Promise<void> {
  try {
    await addDoc(collection(db, 'mail'), {
      to: opts.to.trim().toLowerCase(),
      templateName: opts.template,
      message: {
        subject: opts.subject,
        html: opts.html,
      },
      createdAt: serverTimestamp(),
    });
  } catch (err) {
    // Common when the extension isn't installed yet, when the rule
    // rejects the write, or in offline mode. We log but never propagate.
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
