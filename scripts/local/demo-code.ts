// `npm run demo:code`: the demo parent's current authenticator code, so you can
// sign in as the parent locally without setting up an authenticator app.

import { existsSync, readFileSync } from 'node:fs';
import { totp } from './totp.ts';

const FILE = '.demo-logins.local';

if (!existsSync(FILE)) {
  console.error('No demo logins yet. Run "npm run demo" first.');
  process.exitCode = 1;
} else {
  const { parent } = JSON.parse(readFileSync(FILE, 'utf8')) as { parent: { totpSecret: string } };
  const now = Date.now() / 1000;
  const left = 30 - Math.floor(now % 30);
  console.log(`Parent code: ${totp(parent.totpSecret, now)}  (changes in ${left} seconds)`);
}
