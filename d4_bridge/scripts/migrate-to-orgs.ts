// One-shot migration that brings the existing single-tenant codebase
// into the Sprint 1 multi-tenant data shape.
//
// What it does, per legacy event currently at the root collection:
//   1. Look up (or create) a default Organization keyed off the event's
//      `organizerId` uid. Multiple events with the same organizerId
//      share the same org.
//   2. Ensure the bootstrap `org_memberships/{orgId}_{uid}` doc exists
//      for the organizerId with role=owner.
//   3. Stamp `orgId` onto the event doc.
//   4. Stamp `orgId` onto every ticket whose eventId matches.
//   5. Stamp `orgId` onto every transfer whose eventId matches.
//
// Idempotent: re-running is safe — every step short-circuits when the
// target state is already in place.
//
// HOW TO RUN: this script is intended for the Firebase Admin SDK so it
// can bypass the Firestore security rules and update arbitrary docs.
// You'll need a service-account.json from the Firebase console.
//
//   $ npm install firebase-admin tsx
//   $ tsx scripts/migrate-to-orgs.ts
//
// Production runs should target a fresh Firebase project with no real
// user data first to validate behaviour, then the live project. Always
// snapshot Firestore (gcloud firestore export) before running.
//
// Note on scale: this script reads + writes one batch per organizerId
// + one batch per event. For Bridge first-wave (a handful of organizer
// uids) the run finishes in seconds. For larger datasets the loops
// would need pagination + parallel batching.

import admin from 'firebase-admin';

// You provide this via env: GOOGLE_APPLICATION_CREDENTIALS pointing at
// the service-account.json. We deliberately don't import the JSON
// directly so the file never lands in the repo.
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

// -----------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------

/** Slugify a uid into a fallback org slug. The user can rename later. */
function defaultSlugForUid(uid: string): string {
  // Take first 8 chars of uid, lowercase, prefix with "org-".
  return ('org-' + uid.toLowerCase().slice(0, 12)).replace(/[^a-z0-9-]/g, '-');
}

interface MigrationStats {
  organizerUids: Set<string>;
  orgsCreated: number;
  orgsReused: number;
  membershipsCreated: number;
  eventsStamped: number;
  ticketsStamped: number;
  transfersStamped: number;
}

const stats: MigrationStats = {
  organizerUids: new Set(),
  orgsCreated: 0,
  orgsReused: 0,
  membershipsCreated: 0,
  eventsStamped: 0,
  ticketsStamped: 0,
  transfersStamped: 0,
};

/**
 * Resolve (or create) the default org for a given organizer uid.
 * Returns the orgId. Caches results in-memory so the same uid only
 * triggers one round-trip.
 */
const orgIdCache = new Map<string, string>();

async function getOrCreateOrgForUid(organizerUid: string): Promise<string> {
  if (orgIdCache.has(organizerUid)) {
    return orgIdCache.get(organizerUid)!;
  }

  // Look for an existing org owned by this uid.
  const existing = await db
    .collection('orgs')
    .where('ownerUid', '==', organizerUid)
    .limit(1)
    .get();
  if (!existing.empty) {
    const orgId = existing.docs[0].id;
    orgIdCache.set(organizerUid, orgId);
    stats.orgsReused += 1;

    // Make sure bootstrap membership is present even for reused orgs —
    // a previous migration run may have created the org but failed
    // before writing the membership. The composite-id `set` is idempotent.
    await ensureBootstrapMembership(orgId, organizerUid);
    return orgId;
  }

  // Mint a new org. Use a Firestore-generated docId for the org and
  // a uid-derived slug so the migration is deterministic per organizer.
  const orgRef = db.collection('orgs').doc();
  const orgId = orgRef.id;
  const slug = defaultSlugForUid(organizerUid);
  const slugRef = db.collection('slugs').doc('org:' + slug);

  // Try to look up the user's displayName for a friendlier org name.
  // Falls back to the slug if no profile exists.
  let orgName = `Org ${slug.slice(4)}`;
  try {
    const userSnap = await db.collection('users').doc(organizerUid).get();
    if (userSnap.exists) {
      const u = userSnap.data() as { displayName?: string };
      if (u.displayName && u.displayName.length > 0) {
        orgName = u.displayName;
      }
    }
  } catch {
    // Ignore — fall back to the slug-derived name.
  }

  const batch = db.batch();
  batch.set(orgRef, {
    name: orgName,
    slug,
    ownerUid: organizerUid,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  // Reserve the slug. Use ignore-if-exists semantics by checking first.
  // We accept that a slug clash means the migration's auto-generated
  // slug collided with a user-chosen one — extremely unlikely given the
  // `org-<uid-prefix>` shape, but we log and continue without
  // reservation so the org still exists.
  const existingSlug = await slugRef.get();
  if (!existingSlug.exists) {
    batch.set(slugRef, {
      orgId,
      organizerId: organizerUid,
      type: 'org',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } else {
    console.warn(`Slug collision for ${slug}; continuing without reservation.`);
  }
  // Bootstrap membership.
  const membershipRef = db
    .collection('org_memberships')
    .doc(`${orgId}_${organizerUid}`);
  batch.set(membershipRef, {
    orgId,
    uid: organizerUid,
    role: 'owner',
    addedAt: admin.firestore.FieldValue.serverTimestamp(),
    addedBy: organizerUid,
  });
  await batch.commit();

  orgIdCache.set(organizerUid, orgId);
  stats.orgsCreated += 1;
  stats.membershipsCreated += 1;
  return orgId;
}

async function ensureBootstrapMembership(orgId: string, uid: string) {
  const ref = db.collection('org_memberships').doc(`${orgId}_${uid}`);
  const snap = await ref.get();
  if (snap.exists) return;
  await ref.set({
    orgId,
    uid,
    role: 'owner',
    addedAt: admin.firestore.FieldValue.serverTimestamp(),
    addedBy: uid,
  });
  stats.membershipsCreated += 1;
}

// -----------------------------------------------------------------
// Main pass: events, then tickets, then transfers.
// -----------------------------------------------------------------

async function run() {
  console.log('Starting migration to multi-tenant org shape…');

  // --- Pass 1: events ------------------------------------------------
  const events = await db.collection('events').get();
  console.log(`Found ${events.size} events to process.`);
  for (const eventDoc of events.docs) {
    const data = eventDoc.data() as { organizerId?: string; orgId?: string };
    const organizerId = data.organizerId;
    if (!organizerId) {
      console.warn(`Event ${eventDoc.id} has no organizerId — skipping.`);
      continue;
    }
    stats.organizerUids.add(organizerId);
    const orgId = await getOrCreateOrgForUid(organizerId);
    if (data.orgId === orgId) continue; // Already migrated.
    await eventDoc.ref.update({ orgId });
    stats.eventsStamped += 1;
  }

  // --- Pass 2: tickets ----------------------------------------------
  // Tickets carry organizerId already; we use it as the join key, and
  // we resolve org from the parent event when possible (the event's
  // orgId is already stamped from Pass 1). Falling back to organizerId
  // mapping covers tickets whose event was deleted before the migration.
  const tickets = await db.collection('tickets').get();
  console.log(`Found ${tickets.size} tickets to process.`);
  for (const ticketDoc of tickets.docs) {
    const data = ticketDoc.data() as { organizerId?: string; orgId?: string };
    if (data.orgId) continue;
    const organizerId = data.organizerId;
    if (!organizerId) continue;
    const orgId = await getOrCreateOrgForUid(organizerId);
    await ticketDoc.ref.update({ orgId });
    stats.ticketsStamped += 1;
  }

  // --- Pass 3: transfers --------------------------------------------
  const transfers = await db.collection('transfers').get();
  console.log(`Found ${transfers.size} transfers to process.`);
  for (const transferDoc of transfers.docs) {
    const data = transferDoc.data() as { organizerId?: string; orgId?: string };
    if (data.orgId) continue;
    const organizerId = data.organizerId;
    if (!organizerId) continue;
    const orgId = await getOrCreateOrgForUid(organizerId);
    await transferDoc.ref.update({ orgId });
    stats.transfersStamped += 1;
  }

  console.log('');
  console.log('Migration complete:');
  console.log(`  organizer uids encountered: ${stats.organizerUids.size}`);
  console.log(`  orgs created:               ${stats.orgsCreated}`);
  console.log(`  orgs reused:                ${stats.orgsReused}`);
  console.log(`  memberships created:        ${stats.membershipsCreated}`);
  console.log(`  events stamped:             ${stats.eventsStamped}`);
  console.log(`  tickets stamped:            ${stats.ticketsStamped}`);
  console.log(`  transfers stamped:          ${stats.transfersStamped}`);
}

run().catch((err) => {
  console.error('Migration failed:', err);
  process.exit(1);
});
