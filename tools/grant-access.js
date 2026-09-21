#!/usr/bin/env node
/**
 * Manage the dashboard allowlist.
 *
 * RTDB rules cannot match on email (dots are illegal in keys and rules have no
 * string replace), so the allowlist is keyed by UID. This script resolves an
 * email to its UID and writes /acl/viewers/<uid>.
 *
 *   npm run grant  -- someone@example.com
 *   npm run revoke -- someone@example.com
 *   npm run list
 *
 * The person must have signed in at least once so a Firebase Auth user exists.
 */
const admin = require('firebase-admin');
const path = require('path');

const KEY = process.env.GOOGLE_APPLICATION_CREDENTIALS
  || path.join(__dirname, 'serviceAccount.json');
const DB_URL = process.env.FIREBASE_DB_URL;

if (!DB_URL) {
  console.error('Set FIREBASE_DB_URL to your Realtime Database URL first.');
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.cert(require(KEY)),
  databaseURL: DB_URL,
});

const db = admin.database();
const args = process.argv.slice(2);
const revoke = args.includes('--revoke');
const list = args.includes('--list');
const email = args.find((a) => !a.startsWith('--'));

async function main() {
  if (list) {
    const snap = await db.ref('acl/viewers').get();
    const viewers = snap.val() || {};
    const uids = Object.keys(viewers).filter((u) => viewers[u] === true);
    if (!uids.length) {
      console.log('No viewers on the allowlist yet.');
      return;
    }
    console.log(`${uids.length} viewer(s):`);
    for (const uid of uids) {
      try {
        const user = await admin.auth().getUser(uid);
        console.log(`  ${user.email || '(no email)'}  ${uid}`);
      } catch {
        console.log(`  (deleted user)  ${uid}`);
      }
    }
    return;
  }

  if (!email) {
    console.error('Usage: npm run grant -- someone@example.com');
    process.exit(1);
  }

  let user;
  try {
    user = await admin.auth().getUserByEmail(email);
  } catch {
    console.error(
      `No Firebase Auth user for ${email}.\n` +
      `Ask them to open the dashboard and click "Sign in with Google" once, ` +
      `then run this again.`
    );
    process.exit(1);
  }

  const ref = db.ref(`acl/viewers/${user.uid}`);
  if (revoke) {
    await ref.remove();
    console.log(`Revoked dashboard access for ${email} (${user.uid}).`);
  } else {
    await ref.set(true);
    console.log(`Granted dashboard access to ${email} (${user.uid}).`);
  }
}

main().then(() => process.exit(0)).catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
