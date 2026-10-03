// Runs once before the end-to-end tests: reloads the demo on the LOCAL database
// and adds the test-only logins (see scripts/local/e2e-setup.ts).

import { execSync } from 'node:child_process';

export default function globalSetup(): void {
  console.log('\nReloading the demo on the local database (new demo PINs)…');
  execSync('node scripts/local/e2e-setup.ts', { stdio: 'inherit' });
}
