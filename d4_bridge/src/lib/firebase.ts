import { initializeApp } from 'firebase/app';
import { getAuth } from 'firebase/auth';
import { getFirestore } from 'firebase/firestore';
import { getStorage } from 'firebase/storage';

// Firebase web config is sourced from VITE_FIREBASE_* env at build time
// (same pattern as supabase.ts's VITE_SUPABASE_*), NOT a committed JSON.
// The web "apiKey" is a public app identifier — security is enforced by
// Firestore Rules + Firebase Auth — but we keep it out of the repo so the
// committed static bundle carries no key (secret-scan stays green) and the
// value is injected per-environment at deploy. Missing env → undefined
// config; initializeApp() does not throw on that (it only fails on actual
// use), so the SPA shell still renders during the Firestore→Supabase
// migration. firestoreDatabaseId historically '(default)'.
const env = (import.meta as any).env ?? {};
const firebaseConfig = {
  apiKey:            env.VITE_FIREBASE_API_KEY,
  authDomain:        env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId:         env.VITE_FIREBASE_PROJECT_ID,
  storageBucket:     env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId:             env.VITE_FIREBASE_APP_ID,
  measurementId:     env.VITE_FIREBASE_MEASUREMENT_ID,
  firestoreDatabaseId: env.VITE_FIREBASE_FIRESTORE_DB_ID,
};
const app = initializeApp(firebaseConfig);

// Resolve the Firestore database. The `firestoreDatabaseId` field in
// `firebase-applet-config.json` is either:
//   * `"(default)"` — the project's default database. The Firebase SDK
//     refuses to address this when passed as a literal string, so we
//     OMIT the second argument and let the SDK pick up the default.
//   * `""` / null / undefined — same behavior as above.
//   * Any other string — treated as a named database id (e.g. an
//     AI-Studio-spawned `ai-studio-...` database). Pass it through.
//
// This matters for production: if you pass the literal string
// `"(default)"` to `getFirestore`, the SDK looks up a database NAMED
// `"(default)"` which won't exist, and every read/write fails with
// permission-denied (or not-found, depending on the SDK version).
const dbId = (firebaseConfig as any).firestoreDatabaseId;
export const db = dbId && dbId !== '(default)'
  ? getFirestore(app, dbId)
  : getFirestore(app);
export const auth = getAuth(app);
// Storage handles event-image uploads — used by CreateEvent and EditEvent.
// The corresponding bucket rules live in storage.rules.
export const storage = getStorage(app);

// Previously this module ran a `testConnection()` probe at import time that
// did `getDocFromServer(doc(db, 'test', 'connection'))`. With the global
// deny-by-default rule that probe always fails with permission-denied,
// generating a noisy console error and a wasted Firestore read on every
// page load. Removed.
