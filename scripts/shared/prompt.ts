// Questions in the terminal, for the setup scripts (local and production). Hidden
// answers (PINs, passwords, keys) are never shown or kept.

import { createInterface } from 'node:readline';

export function ask(question: string, hidden = false): Promise<string> {
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

export async function askUntil(
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

/** A 6-digit PIN, typed twice, hidden. */
export async function askPin(): Promise<string> {
  for (;;) {
    const pin = await askUntil(
      'PIN (6 digits, hidden): ',
      (s) => (/^\d{6}$/.test(s) ? null : 'Exactly 6 digits.'),
      true,
    );
    if ((await ask('PIN again: ', true)) === pin) return pin;
    console.log("  The two PINs didn't match. Try again.");
  }
}

export const username = (s: string) =>
  /^[a-z0-9_]{3,30}$/.test(s) ? null : 'Use 3 to 30 lowercase letters, numbers or _ (no spaces).';
export const notEmpty = (s: string) => (s ? null : 'Please type something.');

export const email = (s: string) =>
  /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s) ? null : "That doesn't look like an email.";

/** A parent password: at least 12 characters, typed twice, hidden. */
export async function askPassword(): Promise<string> {
  for (;;) {
    const password = await askUntil(
      'Password (at least 12 characters, hidden): ',
      (s) => (s.length >= 12 ? null : 'At least 12 characters, please.'),
      true,
    );
    if ((await ask('Password again: ', true)) === password) return password;
    console.log("  The two passwords didn't match. Try again.");
  }
}
