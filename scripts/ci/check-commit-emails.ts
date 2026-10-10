// `npm run check:emails`: every commit's author and committer email must be a GitHub
// noreply address, so no personal email is ever published with the code (the repo is
// public). Runs in CI on every push, and as a pre-commit hook on Dad's computer
// (`git config core.hooksPath .githooks`, see docs/RUNBOOK.md).
//
// Allowed: <id>+<username>@users.noreply.github.com, and noreply@github.com (GitHub's own
// committer address when a change is made on github.com). One commit from before this
// rule (2026-10-08) used a personal address; history isn't rewritten (Dad's decision), so
// it is the single exception, named by its full id.
//
// With --staged it checks only the identity the next commit will use.

import { execFileSync } from 'node:child_process';

const ALLOWED = [/^\d+\+[A-Za-z0-9-]+@users\.noreply\.github\.com$/, /^noreply@github\.com$/];
const GRANDFATHERED = new Set(['3d52ac775b9811fd9547237344c073ad52d6c150']);

export const isNoreply = (email: string): boolean => ALLOWED.some((re) => re.test(email.trim()));

function git(args: string[]): string {
  return execFileSync('git', args, { encoding: 'utf8' });
}

function main(): void {
  if (process.argv.includes('--staged')) {
    const email = git(['config', 'user.email']).trim();
    if (!isNoreply(email)) {
      console.error(
        `This commit would publish "${email}". Use your GitHub noreply address:\n` +
          '  git config user.email "<id>+<username>@users.noreply.github.com"',
      );
      process.exitCode = 1;
    }
    return;
  }

  const bad: string[] = [];
  for (const line of git(['log', '--format=%H%x09%ae%x09%ce']).split('\n')) {
    if (!line.trim()) continue;
    const [sha, author, committer] = line.split('\t');
    if (GRANDFATHERED.has(sha)) continue;
    for (const [who, email] of [
      ['author', author],
      ['committer', committer],
    ] as const)
      if (!isNoreply(email))
        bad.push(`${sha.slice(0, 7)}: ${who} email isn't a GitHub noreply address`);
  }
  if (bad.length) {
    console.error(
      `${bad.length} problem(s). Commits must use a GitHub noreply email:\n  ${bad.join('\n  ')}`,
    );
    process.exitCode = 1;
  } else {
    console.log('Every commit uses a GitHub noreply email.');
  }
}

if (process.argv[1]?.endsWith('check-commit-emails.ts')) main();
