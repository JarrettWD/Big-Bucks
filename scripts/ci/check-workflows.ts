// Checks every GitHub workflow before it can fail at 8 am: Big-Bucks' own and the
// copies for the private big-bucks-backups repo (ops/backup-repo). actionlint checks
// each workflow's structure and expressions, and runs shellcheck on every `run:`
// script, so a shell mistake (like an unbalanced quote) fails CI instead of the
// morning health check (Stage 5, Dad 2026-10-10).
//
//   npm run check:workflows              every workflow
//   npm run check:workflows -- <file>    just these files
//
// It runs actionlint's own Docker image, pinned, which includes shellcheck.

import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const IMAGE = 'rhysd/actionlint:1.7.7';
const FOLDERS = ['.github/workflows', 'ops/backup-repo/.github/workflows'];

function workflows(): string[] {
  return FOLDERS.flatMap((d) =>
    readdirSync(d)
      .filter((f) => /\.ya?ml$/.test(f))
      .sort()
      .map((f) => join(d, f).replaceAll('\\', '/')),
  );
}

const given = process.argv.slice(2);
const files = given.length ? given.map((f) => f.replaceAll('\\', '/')) : workflows();
console.log(`Checking ${files.length} workflow${files.length === 1 ? '' : 's'} with ${IMAGE}:`);
for (const f of files) console.log(`  ${f}`);

const r = spawnSync(
  'docker',
  ['run', '--rm', '-v', `${process.cwd()}:/repo`, '-w', '/repo', IMAGE, '-no-color', ...files],
  { stdio: 'inherit', env: { ...process.env, MSYS_NO_PATHCONV: '1' } },
);
if (r.error) {
  console.error(`Couldn't run Docker: ${r.error.message}`);
  process.exit(1);
}
if (r.status === 0) console.log('All workflows pass.');
else console.error('A workflow has a problem (above). Fix it before it runs on GitHub.');
process.exit(r.status ?? 1);
