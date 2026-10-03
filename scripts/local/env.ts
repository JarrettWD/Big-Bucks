// `npm run env:local`: point the app at the local Supabase (writes .env.local).
// The demo and setup script do this too; the end-to-end tests run it before building.

import { localKeys, writeAppEnv } from './local.ts';

try {
  writeAppEnv(localKeys());
  console.log('Wrote .env.local: the app will use the local Supabase.');
} catch (e) {
  console.error((e as Error).message);
  process.exitCode = 1;
}
