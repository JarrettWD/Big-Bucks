// `npm run setup-account`: create a login on the LOCAL Supabase.
//
// Asks for the role, display name, username and PIN (kids) or email and
// password (parent), and whether a kid is a test account; or, for "pin", a new PIN
// for a kid who already has a login. Nothing is written to
// the repo: the answers go straight into the local database.
//
// Local only. Logins on production use scripts/prod/setup-account.ts
// (`npm run setup-account:prod`, docs/RUNBOOK.md).

import { connectLocal, createKid, createParent, writeAppEnv } from './local.ts';
import { askPassword, askPin, askUntil, email, notEmpty, username } from '../shared/prompt.ts';

async function main(): Promise<void> {
  const { keys, db, admin } = await connectLocal();
  try {
    console.log('Create a Big Bucks login on the LOCAL Supabase (this computer only).\n');
    const role = await askUntil('Kid, parent, or a new PIN for a kid? (kid/parent/pin): ', (s) =>
      ['kid', 'parent', 'pin'].includes(s.toLowerCase()) ? null : 'Type kid, parent or pin.',
    );

    if (role.toLowerCase() === 'pin') {
      // A new PIN for a kid who already has a login (Dad can also reset one in the
      // app: Settings → Logins).
      const user = await askUntil('Her username: ', username);
      const pin = await askPin();
      const r = await admin.rpc('set_kid_pin', { p_username: user, p_pin: pin });
      if (r.error) throw new Error(r.error.message);
      console.log(`\nDone: "${user}" signs in with her new PIN.`);
    } else if (role.toLowerCase() === 'kid') {
      const displayName = await askUntil('Display name (what the app calls her): ', notEmpty);
      const user = await askUntil('Username (for the login screen): ', username);
      const pin = await askPin();
      const test = await askUntil('Test account? (y/n): ', (s) =>
        /^[yn]$/i.test(s) ? null : 'Type y or n.',
      );
      const r = await createKid(admin, {
        username: user,
        displayName,
        pin,
        isTest: /^y$/i.test(test),
      });
      console.log(
        `\nDone: ${displayName} can sign in as "${user}" with her PIN. Account ${r.accountId}.`,
      );
    } else {
      const displayName = await askUntil('Display name: ', notEmpty);
      const user = await askUntil('Username (a label; parents sign in with email): ', username);
      const address = await askUntil('Email: ', email);
      const password = await askPassword();
      await createParent(admin, { email: address, password, username: user, displayName });
      console.log(
        `\nDone: ${displayName} can sign in at the parent login with that email and password.` +
          '\nThe first sign-in sets up the authenticator app.',
      );
    }
    writeAppEnv(keys);
  } finally {
    await db.close();
  }
}

main().catch((e) => {
  console.error(`\n${(e as Error).message}`);
  process.exitCode = 1;
});
