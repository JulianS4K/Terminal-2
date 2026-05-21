import { initializeApp } from 'firebase/app';
import { getAuth } from 'firebase/auth';
import { getFirestore } from 'firebase/firestore';
import { getStorage } from 'firebase/storage';
import firebaseConfig from '../../firebase-applet-config.json';

// Note: this JSON ships in the client bundle. Firebase web "apiKey" is an
// app identifier, not a secret — security is enforced by Firestore Rules
// and Firebase Auth on the project. See SECURITY notes in firestore.rules.
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
