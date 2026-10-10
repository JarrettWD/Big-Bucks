// Questions in the terminal, for the setup scripts (local and production). Hidden
// answers (PINs, passwords, keys) are never shown or kept.

import { createInterface } from 'node:readline';
import { clearClipboard, readClipboard } from './clipboard.ts';

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

// Keys and passwords from the clipboard (Dad, 2026-10-10: pasting into hidden prompts
// was unreliable in PowerShell). Pressing Enter with nothing typed uses what was copied.

export interface ClipboardIo {
  read: () => string | null;
  clear: () => boolean;
}
const systemClipboard: ClipboardIo = { read: () => readClipboard(), clear: () => clearClipboard() };

/** What a hidden answer means: what was typed, or (nothing typed) what was copied. */
export function secretFrom(
  answer: string,
  io: ClipboardIo,
): { value: string | null; fromClipboard: boolean } {
  if (answer !== '') return { value: answer, fromClipboard: false };
  const copied = io.read();
  return { value: copied ? copied : null, fromClipboard: true };
}

/**
 * A key or password, hidden. Press Enter with nothing typed to use what you copied: it's
 * checked, never shown, and the clipboard is cleared once it's accepted.
 */
export async function askSecret(
  question: string,
  ok: (s: string) => string | null,
  io: ClipboardIo = systemClipboard,
  answer: (q: string) => Promise<string> = (q) => ask(q, true),
): Promise<{ value: string; fromClipboard: boolean }> {
  for (;;) {
    const r = secretFrom(await answer(`${question} (or press Enter to use what you copied): `), io);
    if (r.value === null) {
      console.log("  The clipboard is empty or couldn't be read. Copy it again, then press Enter.");
      continue;
    }
    const problem = ok(r.value);
    if (problem) {
      console.log(`  ${problem}${r.fromClipboard ? ' (That was what you copied.)' : ''}`);
      continue;
    }
    if (r.fromClipboard)
      console.log(
        io.clear()
          ? '  Used what you copied (not shown). The clipboard is now cleared.'
          : "  Used what you copied (not shown). Couldn't clear the clipboard: copy something else over it.",
      );
    return { value: r.value, fromClipboard: r.fromClipboard };
  }
}

/**
 * A parent password: at least 12 characters, hidden, typed twice. From the clipboard it's
 * asked for only once (a paste can't have a typing slip).
 */
export async function askPassword(io: ClipboardIo = systemClipboard): Promise<string> {
  const longEnough = (s: string) => (s.length >= 12 ? null : 'At least 12 characters, please.');
  for (;;) {
    const first = await askSecret('Password (at least 12 characters, hidden)', longEnough, io);
    if (first.fromClipboard) return first.value;
    if ((await ask('Password again: ', true)) === first.value) return first.value;
    console.log("  The two passwords didn't match. Try again.");
  }
}
