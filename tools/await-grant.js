#!/usr/bin/env node
/**
 * Wait for someone to sign in, then allowlist them.
 *
 * A viewer cannot be granted access until they have signed in once, because
 * the RTDB rules key on UID and the UID does not exist before first sign-in.
 * This removes the round trip: start it, tell them to sign in, walk away.
 *
 *   npm run await -- someone@example.com [minutes]
 */
const admin = require('firebase-admin');
const path = require('path');

const EMAIL = process.argv.find((a, i) => i >= 2 && !a.startsWith('--') && a.includes('@'));
const MINUTES = Number(process.argv[3]) || 15;
const DB = process.env.FIREBASE_DB_URL;
const KEY = process.env.GOOGLE_APPLICATION_CREDENTIALS
  || path.join(__dirname, 'serviceAccount.json');

if (!EMAIL || !DB) {
  console.error('Usage: FIREBASE_DB_URL=... npm run await -- someone@example.com [minutes]');
  process.exit(1);
}

admin.initializeApp({ credential: admin.credential.cert(require(KEY)), databaseURL: DB });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const deadline = Date.now() + MINUTES * 60 * 1000;
  while (Date.now() < deadline) {
    try {
      const user = await admin.auth().getUserByEmail(EMAIL);
      const ref = admin.database().ref(`acl/viewers/${user.uid}`);
      await ref.set(true);
      const readback = (await ref.get()).val();
      console.log(`GRANTED ${EMAIL}`);
      console.log(`  uid       : ${user.uid}`);
      console.log(`  provider  : ${(user.providerData[0] || {}).providerId}`);
      console.log(`  verified  : ${user.emailVerified}`);
      console.log(`  acl value : ${readback}`);
      process.exit(readback === true ? 0 : 3);
    } catch (e) {
      if (e.code !== 'auth/user-not-found') {
        console.error('ERROR', e.code || '', e.message);
        process.exit(1);
      }
    }
    await sleep(5000);
  }
  console.log(`TIMEOUT: ${EMAIL} did not sign in within ${MINUTES} minutes.`);
  process.exit(2);
})();
