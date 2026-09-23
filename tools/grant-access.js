#!/usr/bin/env node
/**
 * Manage the dashboard allowlist.
 *
 * RTDB rules cannot match on email (dots are illegal in keys and rules have no
 * string replace), so the allowlist is keyed by UID. This script resolves an
 * email to its UID and writes /acl/viewers/<uid>.
 *
 * Three tiers. A viewer sees the farm; a controller may also operate lights,
 * switches and fans from the dashboard; an admin may additionally grant and
 * revoke the other two tiers for anyone else, from the dashboard's Admin
 * page. Granting control implies view; granting admin implies both.
 *
 * Admin is deliberately the one tier the dashboard itself can never hand
 * out - RTDB rules refuse a client write to acl/admins no matter who is
 * asking, so promoting someone to admin always comes back through here,
 * with the service account credential.
 *
 *   npm run grant   -- someone@example.com
 *   npm run grant   -- someone@example.com --control
 *   npm run grant   -- someone@example.com --admin
 *   npm run revoke  -- someone@example.com            (removes every tier)
 *   npm run revoke  -- someone@example.com --control  (demotes to view-only)
 *   npm run revoke  -- someone@example.com --admin    (demotes to controller)
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
const control = args.includes('--control');
const makeAdmin = args.includes('--admin');
const email = args.find((a) => !a.startsWith('--'));

async function main() {
  if (list) {
    const [viewSnap, ctlSnap, adminSnap] = await Promise.all([
      db.ref('acl/viewers').get(),
      db.ref('acl/controllers').get(),
      db.ref('acl/admins').get(),
    ]);
    const viewers = viewSnap.val() || {};
    const controllers = ctlSnap.val() || {};
    const admins = adminSnap.val() || {};
    const uids = Object.keys(viewers).filter((u) => viewers[u] === true);
    if (!uids.length) {
      console.log('No viewers on the allowlist yet.');
      return;
    }
    console.log(`${uids.length} viewer(s):`);
    for (const uid of uids) {
      const tier = admins[uid] === true ? 'admin'
        : controllers[uid] === true ? 'control' : 'view';
      try {
        const user = await admin.auth().getUser(uid);
        console.log(`  ${(user.email || '(no email)').padEnd(34)} ${tier.padEnd(8)} ${uid}`);
      } catch {
        console.log(`  ${'(deleted user)'.padEnd(34)} ${tier.padEnd(8)} ${uid}`);
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

  const viewRef = db.ref(`acl/viewers/${user.uid}`);
  const ctlRef = db.ref(`acl/controllers/${user.uid}`);
  const adminRef = db.ref(`acl/admins/${user.uid}`);

  if (revoke && makeAdmin) {
    // Demote, do not lock out: they keep control, they lose the admin page.
    await adminRef.remove();
    console.log(`${email} is no longer an admin, but keeps their existing access.`);
  } else if (revoke && control) {
    // Demote, do not lock out: they keep the dashboard, they lose the switches.
    await Promise.all([ctlRef.remove(), adminRef.remove()]);
    console.log(`${email} can view the dashboard but no longer control devices.`);
  } else if (revoke) {
    await Promise.all([viewRef.remove(), ctlRef.remove(), adminRef.remove()]);
    console.log(`Revoked all dashboard access for ${email} (${user.uid}).`);
  } else if (makeAdmin) {
    // Admin without control would be a dashboard they cannot act from, so
    // grant every tier under it too.
    await viewRef.set(true);
    await ctlRef.set(true);
    await adminRef.set(true);
    console.log(`${email} (${user.uid}) is now an admin: can view, control, ` +
      `and grant/revoke access for anyone else from the dashboard's Admin page.`);
  } else if (control) {
    // Control without view would be a dashboard they cannot read, so grant both.
    await viewRef.set(true);
    await ctlRef.set(true);
    console.log(`${email} (${user.uid}) can now view AND control farm devices.`);
  } else {
    await viewRef.set(true);
    console.log(`Granted dashboard access to ${email} (${user.uid}).`);
  }
}

main().then(() => process.exit(0)).catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
