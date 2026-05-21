import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { auth } from './firebase';
import type { ToastOptions } from '../context/ToastContext';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export enum OperationType {
  CREATE = 'create',
  UPDATE = 'update',
  DELETE = 'delete',
  LIST = 'list',
  GET = 'get',
  WRITE = 'write',
}

interface FirestoreErrorInfo {
  error: string;
  operationType: OperationType;
  path: string | null;
  // Captured for diagnostic logging only — never include this in the
  // user-facing toast or anything that gets serialized into a thrown Error.
  authInfo: {
    userId?: string | null;
    emailVerified?: boolean | null;
    isAnonymous?: boolean | null;
  };
}

/**
 * Centralised handler for Firestore failures.
 *
 * Previously this function did `throw new Error(JSON.stringify(errInfo))` with
 * the user's email, uid, and provider data baked into the message. Callers
 * never wrapped that throw in a try/catch, so errors silently rejected the
 * surrounding async function — leaving the UI in a stuck loading state and
 * creating a PII leak risk if the error string ever reached an observer.
 *
 * The new contract:
 *   - Always log the error (with PII fields scoped down to non-sensitive ids)
 *     to the console for diagnostic purposes.
 *   - If a `toast` callback is provided, surface a short, user-friendly
 *     message — never the raw error or any auth fields.
 *   - Return `void`. Do NOT throw. Callers stay in their own catch block and
 *     remain in control of state cleanup, navigation, etc.
 */
export type ToastFn = (opts: ToastOptions) => void;

export function handleFirestoreError(
  error: unknown,
  operationType: OperationType,
  path: string | null,
  toast?: ToastFn,
): void {
  const info: FirestoreErrorInfo = {
    error: error instanceof Error ? error.message : String(error),
    authInfo: {
      // Intentionally narrowed — no email, displayName, providerData, etc.
      userId: auth.currentUser?.uid,
      emailVerified: auth.currentUser?.emailVerified,
      isAnonymous: auth.currentUser?.isAnonymous,
    },
    operationType,
    path,
  };
  console.error('Firestore Error:', info);

  if (toast) {
    const friendly = friendlyMessage(error);
    toast({
      kind: 'error',
      title: 'Something went wrong',
      message: friendly,
    });
  }
}

function friendlyMessage(error: unknown): string {
  const msg = error instanceof Error ? error.message : String(error);
  // Surface a couple of common Firestore failure modes in plain English.
  if (/permission|insufficient/i.test(msg)) {
    return "You don't have permission to do that. Try signing in again.";
  }
  if (/unavailable|network|offline/i.test(msg)) {
    return 'Connection problem. Please check your internet and try again.';
  }
  return 'Could not complete the request. Please try again.';
}

/**
 * Format a number as currency in the given ISO 4217 code. Defaults to
 * USD when the caller doesn't supply one — matches the legacy behavior
 * for any code path that hasn't been threaded through with a currency
 * yet (e.g., dashboards summarising mixed-currency events).
 *
 * Falls back gracefully if Intl rejects an unknown code.
 */
export function formatCurrency(amount: number, currency = 'USD') {
  const code = (currency || 'USD').toUpperCase();
  try {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: code,
    }).format(amount);
  } catch {
    // Bad code — render the number with the literal code suffix.
    return `${amount.toFixed(2)} ${code}`;
  }
}

export function generateBarcodeContent(ticketId: string, ownerId: string, secret?: string) {
  // Rotating barcode: ticketId + ownerId + current 30s bucket + secret.
  // The 30s bucket means a screenshotted QR stops scanning after at most
  // 30 seconds; the secret is rotated on transfer so an old owner can't
  // forge the new owner's barcode.
  const timestamp = Math.floor(Date.now() / 30000);
  return `T-${ticketId}:${ownerId}:${timestamp}${secret ? ':' + secret : ''}`;
}

// NOTE: `getStripe` lives in `./stripe`. Import it directly from there in
// the views that need it (currently only EventDetails). We deliberately do
// NOT re-export it here — a re-export is a side-effect import in ES modules,
// which would defeat the chunk split for `formatCurrency` consumers.
