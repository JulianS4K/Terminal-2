// One-off Node script to grant the platform-admin custom claim to a
// Firebase Auth user identified by email. Custom claims can only be set
// server-side via the Admin SDK — they're signed by Firebase and
// unforgeable from the client, so this is the only path.
//
// Usage:
//   1. From the Firebase console, generate a service account JSON
//      (Project Settings -> Service accounts -> Generate new private
//      key) and save it OUTSIDE the repo (e.g.
//      C:\Users\julia\Documents\vibepass-service-account.json).
//   2. Install the Admin SDK in this project (one time):
//        npm install firebase-admin
//   3. Set the env var pointing at the JSON, then run this script:
//        $env:GOOGLE_APPLICATION_CREDENTIALS="C:\path\to\service-account.json"
//        node scripts/grant-admin.cjs julian@s4kent.com
//   4. Sign out and back into the live app so your auth token picks up
//      the new claim.
//
// File extension note: this is `.cjs` (CommonJS) rather than `.js`
// because the project's package.json has `"type": "module"`, which
// causes Node to interpret bare `.js` files as ESM. The Admin SDK
// docs use `require()`, so we use the `.cjs` extension to opt this
// one script back into CommonJS without touching the rest of the
// project's module behavior.

const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const email = (process.argv[2] || '').trim().toLowerCase();
if (!email || !email.includes('@')) {
  console.error('Usage: node scripts/grant-admin.cjs <email>');
  console.error('       Make sure GOOGLE_APPLICATION_CREDENTIALS is set.');
  process.exit(1);
}

(async () => {
  try {
    const userRecord = await admin.auth().getUserByEmail(email);
    console.log(`Found user: ${userRecord.uid} (${userRecord.email})`);
    console.log(`Existing claims:`, userRecord.customClaims || {});

    await admin.auth().setCustomUserClaims(userRecord.uid, {
      ...(userRecord.customClaims || {}),
      admin: true,
    });

    const updated = await admin.auth().getUser(userRecord.uid);
    console.log('Updated claims:', updated.customClaims);
    console.log('');
    console.log('Done. Sign out + back in (or refresh the auth token)');
    console.log('to see admin-gated UI in the live app.');
    process.exit(0);
  } catch (err) {
    console.error('Failed:', err.message || err);
    process.exit(1);
  }
})();
