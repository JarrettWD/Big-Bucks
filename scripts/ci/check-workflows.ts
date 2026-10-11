// Checks every GitHub workflow before it can fail at 8 am: Big-Bucks' own and the
// copies for the private big-bucks-backups repo (ops/backup-repo). actionlint checks
// each workflow's structure and expressions, and runs shellcheck on every `run:`
// script, so a shell mistake (like an unbalanced quote) fails CI instead of the
// morning health check (Stage 5, Dad 2026-10-10).
//
//   npm run check:workflows              every workflow
//   npm run check:workflows -- <file>    just these files
//
// It runs actionlint's own Docker image, pinned, which includes shellcheck. Shell
// scripts the workflows call (ops/backup-repo/scripts/*.sh) get shellcheck too.

import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const IMAGE = 'rhysd/actionlint:1.7.7';
const FOLDERS = ['.github/workflows', 'ops/backup-repo/.github/workflows'];
const SCRIPTS = 'ops/backup-repo/scripts';

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
for (const f of files.filter((x) => !x.endsWith('.sh'))) console.log(`  ${f}`);

function docker(args: string[]): number {
  const r = spawnSync(
    'docker',
    ['run', '--rm', '-v', `${process.cwd()}:/repo`, '-w', '/repo', ...args],
    { stdio: 'inherit', env: { ...process.env, MSYS_NO_PATHCONV: '1' } },
  );
  if (r.error) {
    console.error(`Couldn't run Docker: ${r.error.message}`);
    process.exit(1);
  }
  return r.status ?? 1;
}

const yamlFiles = files.filter((f) => /\.ya?ml$/.test(f));
const shellFiles = given.length
  ? files.filter((f) => f.endsWith('.sh'))
  : readdirSync(SCRIPTS)
      .filter((f) => f.endsWith('.sh'))
      .map((f) => `${SCRIPTS}/${f}`);
for (const f of shellFiles) console.log(`  ${f} (shellcheck)`);

// Both always run, so one report shows every problem.
const lint = yamlFiles.length ? docker([IMAGE, '-no-color', ...yamlFiles]) : 0;
const shell = shellFiles.length ? docker(['--entrypoint', 'shellcheck', IMAGE, ...shellFiles]) : 0;
const status = lint || shell;
if (status === 0) console.log('All workflows and scripts pass.');
else console.error('A workflow or script has a problem (above). Fix it before it runs on GitHub.');
process.exit(status);
