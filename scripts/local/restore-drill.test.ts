import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { OWN_FILE_TABLES } from '../../ops/backup-repo/scripts/guards.ts';
import { copyCommand, folderProblem, ownFileTables } from './restore-drill.ts';

function backupFolder(tables: string[], withCsv: boolean): string {
  const dir = mkdtempSync(join(tmpdir(), 'bb-drill-'));
  for (const f of ['schema.sql', 'auth.sql', 'data.sql', 'balances.csv'])
    writeFileSync(join(dir, f), 'x\n');
  writeFileSync(
    join(dir, 'counts.json'),
    JSON.stringify({
      tables: Object.fromEntries(tables.map((t) => [t, { rows: 1, md5: '', columns: ['a'] }])),
    }),
  );
  if (withCsv) {
    mkdirSync(join(dir, 'csv'));
    for (const t of tables) writeFileSync(join(dir, 'csv', `${t}.csv`), 'a\n1\n');
  }
  return dir;
}

describe('photos have their own backup file (stage 9)', () => {
  it('keeps the wish photos out of data.sql', () => {
    expect(OWN_FILE_TABLES).toEqual(['public.wishlist_photos']);
  });

  it('loads them back with \\copy, every column named', () => {
    expect(copyCommand('public.wishlist_photos', ['wishlist_item_id', 'account_id', 'photo'])).toBe(
      `\\copy "public"."wishlist_photos" ("wishlist_item_id", "account_id", "photo") from '/tmp/drill/public.wishlist_photos.csv' with (format csv, header true)`,
    );
  });

  it('a backup from before Stage 9 has no photo file, and needs none', () => {
    const dir = backupFolder(['public.transactions'], false);
    expect(ownFileTables({ tables: { 'public.transactions': {} } } as never)).toEqual([]);
    expect(folderProblem(dir)).toBeNull();
  });

  it('refuses a backup whose photo file is missing', () => {
    const dir = backupFolder(['public.transactions', 'public.wishlist_photos'], false);
    expect(folderProblem(dir)).toMatch(/has no csv\/public\.wishlist_photos\.csv/);
    expect(folderProblem(backupFolder(['public.wishlist_photos'], true))).toBeNull();
  });
});
