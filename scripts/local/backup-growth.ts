// How much the backup repo grows with photos in it (Stage 9, Dad's condition 1).
//
//   npm run backup:growth
//
// LOCAL copy only (LocalDb refuses anything else). It gives the demo's test kid 30
// wishes with photos the size of real ones (random bytes, which squeeze no better than
// a real JPEG), then takes 30 daily backups exactly as the Backup workflow does, each
// committed to a throwaway git repo, the way big-bucks-backups keeps them:
//   - every day something else changes too (a notice to the test kid), as the ledger and job runs
//     do in production, so data.sql changes every day;
//   - every third day one photo is replaced (10 changes in 30 days).
// It does this twice, side by side on the same data: with the photos inside data.sql
// (the Stage 5 layout) and in their own CSV (Stage 9). Then it reports, for each, the
// repo's size after git packs it (what GitHub keeps), before packing, the
// big-bucks-history.bundle that goes to OneDrive, and one day's backup folder.
//
// Afterwards run `npm run demo` again for fresh demo data. Nothing here touches production.

import { execSync } from 'node:child_process';
import { randomBytes, randomInt } from 'node:crypto';
import { mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { take } from '../../ops/backup-repo/scripts/backup.ts';
import { OWN_FILE_TABLES } from '../../ops/backup-repo/scripts/guards.ts';
import { LocalDb } from '../timemachine/db.ts';

const OUT = '.local-backup/growth';
const DAYS = 30;
const PHOTOS = 30;
const MODES = { inside: [] as string[], own: ['public.wishlist_photos'] };

/** A made-up JPEG of about this many bytes: the JPEG start, then random bytes. */
const jpeg = (bytes: number) =>
  Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(bytes - 4)]);
const sh = (cmd: string, cwd: string) =>
  execSync(cmd, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const mb = (bytes: number) => `${(bytes / 1024 / 1024).toFixed(1)} MB`;

function folderBytes(dir: string): number {
  let n = 0;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    n += e.isDirectory() ? folderBytes(p) : statSync(p).size;
  }
  return n;
}

/** git count-objects: loose and packed sizes, in bytes. */
function gitSizes(repo: string): { loose: number; packed: number } {
  const v = Object.fromEntries(
    sh('git count-objects -v', repo)
      .trim()
      .split('\n')
      .map((l) => l.split(': ')),
  );
  return { loose: Number(v.size) * 1024, packed: Number(v['size-pack']) * 1024 };
}

async function main(): Promise<void> {
  const db = await LocalDb.connect();
  let url: string;
  let photoIds: string[];
  let kidId: string;
  try {
    const [r] = await db.q<{ words: string }>('select public.set_backup_login() as words');
    url = `postgresql://backup_reader:${r.words.split(': ').pop()!.trim()}@127.0.0.1:54322/postgres`;
    const [kid] = await db.q<{ account_id: string }>(
      `select p.account_id from public.profiles p join public.accounts a on a.id = p.account_id
        where a.is_test order by p.username limit 1`,
    );
    if (!kid) throw new Error('No test kid in the local copy. Run npm run demo first.');
    kidId = kid.account_id;
    photoIds = [];
    for (let i = 1; i <= PHOTOS; i++) {
      const [item] = await db.q<{ id: string }>(
        `insert into public.wishlist_items (account_id, name, price_cents, stars, sort_order)
         values ($1, $2, 5000, 3, 1000 + $3) returning id`,
        [kid.account_id, `Growth wish ${i}`, i],
      );
      await db.q(
        `insert into public.wishlist_photos (wishlist_item_id, account_id, photo, thumb) values ($1, $2, $3, $4)`,
        [item.id, kid.account_id, jpeg(randomInt(90_000, 150_001)), jpeg(randomInt(8_000, 18_001))],
      );
      photoIds.push(item.id);
    }
  } finally {
    await db.close();
  }

  rmSync(OUT, { recursive: true, force: true });
  for (const mode of Object.keys(MODES)) {
    const repo = join(OUT, mode);
    mkdirSync(repo, { recursive: true });
    sh('git init -q', repo);
    sh('git config user.email growth@example.invalid', repo);
    sh('git config user.name growth', repo);
    sh('git config core.autocrlf false', repo);
    sh('git config gc.auto 0', repo);
  }

  for (let day = 1; day <= DAYS; day++) {
    const d = await LocalDb.connect();
    try {
      await d.q(
        `insert into public.notifications (account_id, type, title, body, dedupe_key) values ($1, 'rate_change', $2, '', $3)`,
        [kidId, `Backup growth check, day ${day}`, `growth:${day}:${Date.now()}`],
      );
      if (day % 3 === 0)
        await d.q(
          `update public.wishlist_photos set photo = $2, added_at = now() where wishlist_item_id = $1`,
          [photoIds[day % PHOTOS], jpeg(randomInt(90_000, 150_001))],
        );
    } finally {
      await d.close();
    }
    for (const [mode, tables] of Object.entries(MODES)) {
      OWN_FILE_TABLES.splice(0, OWN_FILE_TABLES.length, ...tables);
      const repo = join(OUT, mode);
      await take(url, repo);
      sh('git add -A', repo);
      sh(`git commit -q -m "Backup day ${day}"`, repo);
    }
    console.log(`Day ${day} of ${DAYS} backed up both ways.`);
  }

  console.log('');
  console.log(`After ${DAYS} daily backups with ${PHOTOS} photos (${DAYS / 3} photo changes):`);
  for (const mode of Object.keys(MODES)) {
    const repo = join(OUT, mode);
    const before = gitSizes(repo);
    sh('git gc -q', repo);
    const after = gitSizes(repo);
    sh('git bundle create -q ../' + mode + '.bundle --all', repo);
    const bundle = statSync(join(OUT, `${mode}.bundle`)).size;
    const folder = folderBytes(join(repo, 'backup'));
    const dataSql = statSync(join(repo, 'backup', 'data.sql')).size;
    console.log(
      `  photos ${mode === 'own' ? 'in their own CSV (Stage 9)' : 'inside data.sql (Stage 5)'}:\n` +
        `    repo, packed (what GitHub keeps): ${mb(after.packed + after.loose)}\n` +
        `    repo before packing (loose):      ${mb(before.loose)}\n` +
        `    big-bucks-history.bundle:         ${mb(bundle)}\n` +
        `    one day's backup folder:          ${mb(folder)} (data.sql ${mb(dataSql)})`,
    );
  }
  console.log(`\nThe throwaway repos are in ${OUT}. Run "npm run demo" for fresh demo data.`);
}

main().catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
