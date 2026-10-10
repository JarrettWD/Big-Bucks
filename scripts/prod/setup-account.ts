// `npm run setup-account:prod -- --production`: logins on PRODUCTION (Stage 4).
//
// Dad's parent account, test kids, and (after the Stage 12 audit) the girls' real
// accounts; or a new PIN for a kid. The same questions as the local script, with
// these guards first:
//   1. it must be started with --production;
//   2. Dad types the project ref, then types it again to confirm;
//   3. the service role key is pasted into this terminal, hidden, for this run only.
//      It is never saved, printed or written to any file;
//   4. the key must be that project's service role key, and the database must
//      already be marked as production (RUNBOOK, production checklist step 1).
// Nothing personal is written to the repo: the answers go straight into production.
//
// On production, Dad normally resets a PIN in the app (Settings → Logins), which is
// logged and tells her. The "pin" option here is for when the app can't be used.

import { createClient } from '@supabase/supabase-js';
import { createKid, createParent } from '../shared/accounts.ts';
import { ask, askPassword, askPin, askUntil, email, notEmpty, username } from '../shared/prompt.ts';
import {
  argsProblem,
  confirmProblem,
  productionUrl,
  refProblem,
  serviceKeyProblem,
} from './guards.ts';

async function main(): Promise<void> {
  const refuse = argsProblem(process.argv.slice(2));
  if (refuse) throw new Error(refuse);

  console.log('Create a Big Bucks login on PRODUCTION (the real app).\n');
  const ref = await askUntil('Project ref (20 letters, Project Settings → General): ', refProblem);
  const again = await ask('Type the project ref again to confirm: ');
  const mismatch = confirmProblem(ref, again);
  if (mismatch) throw new Error(mismatch);
  const key = await askUntil(
    'Service role key (Project Settings → API Keys; paste it, it stays hidden and is never saved): ',
    (k) => serviceKeyProblem(k, ref),
    true,
  );

  const url = productionUrl(ref);
  const admin = createClient(url, key.trim(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const marked = await admin.from('settings').select('key').eq('key', 'is_production').limit(1);
  if (marked.error) throw new Error(`Couldn't reach ${url}: ${marked.error.message}`);
  if (!marked.data?.length)
    throw new Error(
      `${url} isn't marked as production yet. Do RUNBOOK's production checklist step 1 (mark_production) first.`,
    );
  console.log(`\nConnected to ${url} (marked as production).\n`);

  const role = await askUntil('Kid, parent, or a new PIN for a kid? (kid/parent/pin): ', (s) =>
    ['kid', 'parent', 'pin'].includes(s.toLowerCase()) ? null : 'Type kid, parent or pin.',
  );

  if (role.toLowerCase() === 'pin') {
    console.log(
      '(Normally you reset a PIN in the app: Settings → Logins. That is logged and tells her.)',
    );
    const user = await askUntil('Her username: ', username);
    const pin = await askPin();
    const r = await admin.rpc('set_kid_pin', { p_username: user, p_pin: pin });
    if (r.error) throw new Error(r.error.message);
    console.log(`\nDone: "${user}" signs in with her new PIN. She is signed out everywhere else.`);
  } else if (role.toLowerCase() === 'kid') {
    const test = await askUntil('Test account? (y/n): ', (s) =>
      /^[yn]$/i.test(s) ? null : 'Type y or n.',
    );
    const isTest = /^y$/i.test(test);
    if (!isTest) {
      console.log(
        "\nDad's rule (docs/PROGRESS.md, Stage 12): the girls' real accounts wait for the fresh audit " +
          'before launch.',
      );
      const sure = await ask('Type "real" to create a real (not test) kid anyway: ');
      if (sure !== 'real') throw new Error('Nothing was changed.');
    }
    const displayName = await askUntil('Display name (what the app calls her): ', notEmpty);
    const user = await askUntil('Username (for the login screen): ', username);
    const pin = await askPin();
    await createKid(admin, { username: user, displayName, pin, isTest });
    console.log(
      `\nDone: ${displayName} can sign in as "${user}" with her PIN${isTest ? ' (test account)' : ''}.`,
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
}

main().catch((e) => {
  console.error(`\n${(e as Error).message}`);
  process.exitCode = 1;
});
