// @vitest-environment node
// The function runs in Deno, not a browser: Node's own byte arrays, as there.
import { describe, expect, it } from 'vitest';
import { strFromU8, unzipSync } from 'fflate';
import { backupFileName, buildBackupZip } from './backup_zip.ts';

const data = {
  taken_at: '2026-10-11T14:30:00Z',
  day: '2026-10-11',
  tables: [
    {
      name: 'public.transactions',
      rows: 1,
      csv: 'id,amount_cents,units\n1,12345,1.23456789\n',
      json: '[{"id": 1, "units": 1.23456789012345678, "amount_cents": 12345}]',
    },
    { name: 'private.kid_pin_resets', rows: 0, csv: 'account_id,created_at\n', json: '[]' },
  ],
};

describe('the Download backup zip', () => {
  it('holds every table as CSV and JSON, byte for byte as the database wrote them', () => {
    const files = unzipSync(buildBackupZip(data));
    expect(Object.keys(files).sort()).toEqual([
      'README.txt',
      'csv/private.kid_pin_resets.csv',
      'csv/public.transactions.csv',
      'json/private.kid_pin_resets.json',
      'json/public.transactions.json',
      'manifest.json',
    ]);
    // The units keep all their digits: the JSON text is never parsed on the way.
    expect(strFromU8(files['json/public.transactions.json'])).toBe(data.tables[0].json);
    expect(strFromU8(files['csv/public.transactions.csv'])).toBe(data.tables[0].csv);
    expect(JSON.parse(strFromU8(files['manifest.json']))).toEqual({
      taken_at: '2026-10-11T14:30:00Z',
      day: '2026-10-11',
      tables: [
        { name: 'public.transactions', rows: 1 },
        { name: 'private.kid_pin_resets', rows: 0 },
      ],
      rows: 1,
    });
    expect(strFromU8(files['README.txt'])).toContain('2 tables, 1 rows.');
  });

  it('refuses an empty export or an odd table name', () => {
    expect(() => buildBackupZip({ ...data, tables: [] })).toThrow('no tables');
    expect(() =>
      buildBackupZip({ ...data, tables: [{ ...data.tables[0], name: '../etc/passwd' }] }),
    ).toThrow('Unexpected table name');
  });

  it('names the file by the day', () => {
    expect(backupFileName('2026-10-11')).toBe('big-bucks-backup-2026-10-11.zip');
    expect(() => backupFileName('soon')).toThrow();
  });
});
