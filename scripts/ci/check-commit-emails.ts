// `npm run check:emails`: every commit's author and committer email must be a GitHub
// noreply address, so no personal email is ever published with the code (the repo is
// public). Runs in CI on every push, and as two hooks on Dad's computer
// (`git config core.hooksPath .githooks`, see docs/RUNBOOK.md):
//   * pre-commit (--staged): the identity the next commit will use, as git itself
//     works it out (so GIT_AUTHOR_EMAIL and friends count too);
//   * pre-push (--push): every commit about to be pushed, including any made with
//     --author or on another computer, before anything is public.
//
// Allowed: <id>+<username>@users.noreply.github.com, and noreply@github.com (GitHub's own
// committer address when a change is made on github.com). One commit from before this
// rule (2026-10-08) used a personal address; history isn't rewritten (Dad's decision), so
// it is the single exception, named by its full id.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const ALLOWED = [/^\d+\+[A-Za-z0-9-]+@users\.noreply\.github\.com$/, /^noreply@github\.com$/];
const GRANDFATHERED = new Set(['3d52ac775b9811fd9547237344c073ad52d6c150']);
const ZERO = /^0+$/;

export const isNoreply = (email: string): boolean => ALLOWED.some((re) => re.test(email.trim()));

/** The email in a git identity line: "Name <email> 1700000000 +0000". */
export const identEmail = (ident: string): string => ident.match(/<([^>]*)>/)?.[1] ?? '';

/**
 * The commits a push would publish, from the lines git gives a pre-push hook:
 * "<local ref> <local sha> <remote ref> <remote sha>". A deleted ref publishes nothing;
 * a new branch publishes whatever isn't already on the remote.
 */
export function pushRanges(stdin: string): string[][] {
  const out: string[][] = [];
  for (const line of stdin.split('\n')) {
    const [, local, , remote] = line.trim().split(/\s+/);
    if (!local || ZERO.test(local)) continue;
    out.push(
      remote && !ZERO.test(remote) ? [`${remote}..${local}`] : [local, '--not', '--remotes'],
    );
  }
  return out;
}

function git(args: string[]): string {
  return execFileSync('git', args, { encoding: 'utf8' });
}

function problems(logArgs: string[]): string[] {
  const bad: string[] = [];
  for (const line of git(['log', '--format=%H%x09%ae%x09%ce', ...logArgs]).split('\n')) {
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
  return bad;
}

function report(bad: string[], ok: string): void {
  if (bad.length) {
    console.error(
      `${bad.length} problem(s). Commits must use a GitHub noreply email:\n  ${bad.join('\n  ')}`,
    );
    process.exitCode = 1;
  } else console.log(ok);
}

function main(): void {
  if (process.argv.includes('--staged')) {
    const bad: string[] = [];
    for (const v of ['GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT']) {
      const email = identEmail(git(['var', v]));
      if (!isNoreply(email))
        bad.push(
          `this commit's ${v === 'GIT_AUTHOR_IDENT' ? 'author' : 'committer'} would be "${email}"`,
        );
    }
    if (bad.length)
      bad.push(
        'Use your GitHub noreply address: git config user.email "<id>+<username>@users.noreply.github.com"',
      );
    report(bad, 'This commit uses a GitHub noreply email.');
    return;
  }
  if (process.argv.includes('--push')) {
    const bad = pushRanges(readFileSync(0, 'utf8')).flatMap(problems);
    report(bad, 'Every commit being pushed uses a GitHub noreply email.');
    return;
  }
  report(problems([]), 'Every commit uses a GitHub noreply email.');
}

if (process.argv[1]?.endsWith('check-commit-emails.ts')) main();
