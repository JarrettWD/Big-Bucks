// Before the end-to-end tests: reload the demo (this resets the LOCAL database
// and gives the demo logins new PINs), then add two throwaway logins the tests
// need and the demo shouldn't be bothered by:
//   * a test kid for the lockout test, so the demo kids never get locked;
//   * a test kid for the PIN-reset test (her PIN changes during it);
//   * a test kid for calling kid-login directly (lockouts, codes, timing);
//   * a parent with no authenticator yet, for the first-time setup test.
// Their details go to .e2e-logins.local (gitignored).

import { execSync } from 'node:child_process';
import { randomBytes, randomInt } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { connectLocal, createKid, createParent } from './local.ts';

execSync('npm run demo', { stdio: 'inherit' });

const { db, admin } = await connectLocal();
try {
  const kid = {
    username: 'e2e_lockout',
    displayName: 'Lockout Test',
    pin: String(randomInt(0, 1_000_000)).padStart(6, '0'),
    isTest: true,
  };
  await createKid(admin, kid);
  const resetKid = {
    username: 'e2e_reset',
    displayName: 'Reset Test',
    pin: String(randomInt(0, 1_000_000)).padStart(6, '0'),
    isTest: true,
  };
  await createKid(admin, resetKid);
  const apiKid = {
    username: 'e2e_api',
    displayName: 'Api Test',
    pin: String(randomInt(0, 1_000_000)).padStart(6, '0'),
    isTest: true,
  };
  await createKid(admin, apiKid);
  const parent = {
    email: 'e2e.parent@demo.example',
    password: randomBytes(18).toString('base64url'),
    username: 'e2e_parent',
    displayName: 'New Parent',
  };
  await createParent(admin, parent);
  writeFileSync(
    '.e2e-logins.local',
    JSON.stringify({ lockoutKid: kid, resetKid, apiKid, newParent: parent }, null, 2) + '\n',
  );
  console.log('End-to-end logins ready.');
} finally {
  await db.close();
}
