// `npm run setup-account`: create a login on the LOCAL Supabase.
//
// Asks for the role, display name, username and PIN (kids) or email and
// password (parent), and whether a kid is a test account. Nothing is written to
// the repo: the answers go straight into the local database.
//
// Local only for now. Creating the real accounts in production comes after
// stage 4, once the production project exists.

import { createInterface } from 'node:readline';
import { connectLocal, createKid, createParent, writeAppEnv } from './local.ts';

function ask(question: string, hidden = false): Promise<string> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (hidden) {
      // Show the question, then hide what's typed.
      const out = rl as unknown as { _writeToOutput: (s: string) => void };
      let shown = false;
      out._writeToOutput = (s: string) => {
        if (!shown) {
          process.stdout.write(s);
          shown = true;
        } else if (s.includes('\n')) process.stdout.write('\n');
      };
    }
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function askUntil(
  question: string,
  ok: (s: string) => string | null,
  hidden = false,
): Promise<string> {
  for (;;) {
    const a = await ask(question, hidden);
    const problem = ok(a);
    if (!problem) return a;
    console.log(`  ${problem}`);
  }
}

const username = (s: string) =>
  /^[a-z0-9_]{3,30}$/.test(s) ? null : 'Use 3 to 30 lowercase letters, numbers or _ (no spaces).';
const notEmpty = (s: string) => (s ? null : 'Please type something.');

async function main(): Promise<void> {
  const { keys, db, admin } = await connectLocal();
  try {
    console.log('Create a Big Bucks login on the LOCAL Supabase (this computer only).\n');
    const role = await askUntil('Kid or parent? (kid/parent): ', (s) =>
      ['kid', 'parent'].includes(s.toLowerCase()) ? null : 'Type kid or parent.',
    );

    if (role.toLowerCase() === 'kid') {
      const displayName = await askUntil('Display name (what the app calls her): ', notEmpty);
      const user = await askUntil('Username (for the login screen): ', username);
      let pin = '';
      for (;;) {
        pin = await askUntil(
          'PIN (6 digits, hidden): ',
          (s) => (/^\d{6}$/.test(s) ? null : 'Exactly 6 digits.'),
          true,
        );
        if ((await ask('PIN again: ', true)) === pin) break;
        console.log("  The two PINs didn't match. Try again.");
      }
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
      const email = await askUntil('Email: ', (s) =>
        /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s) ? null : "That doesn't look like an email.",
      );
      let password = '';
      for (;;) {
        password = await askUntil(
          'Password (at least 12 characters, hidden): ',
          (s) => (s.length >= 12 ? null : 'At least 12 characters, please.'),
          true,
        );
        if ((await ask('Password again: ', true)) === password) break;
        console.log("  The two passwords didn't match. Try again.");
      }
      await createParent(admin, { email, password, username: user, displayName });
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
