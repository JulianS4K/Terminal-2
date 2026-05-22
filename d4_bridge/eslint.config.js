// Flat ESLint config. The former `@firebase/eslint-plugin-security-rules`
// entry (which linted firestore.rules) was removed with the Firestore→Supabase
// migration — the app no longer depends on any Firebase package. firestore.rules
// / storage.rules remain in the repo only as the reference security model the
// Supabase RLS migrations were translated from (see migration headers).
export default [
  {
    ignores: ['dist/**/*', 'node_modules/**/*'],
  },
];
