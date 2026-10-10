// The Download backup zip (Stage 5), with no Deno or network in it, so Vitest can
// check it (backup_zip.test.ts). The database hands over every table already written
// as CSV and JSON text (parent_backup_export), so no number is ever parsed or rounded
// here: the text goes into the zip exactly as the database wrote it.

import { strToU8, zipSync, type Zippable } from 'fflate';

export interface ExportTable {
  name: string;
  rows: number;
  csv: string;
  json: string;
}

export interface Export {
  taken_at: string;
  day: string;
  tables: ExportTable[];
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const TABLE = /^[a-z_]+\.[a-z_0-9]+$/;

/** The file name the phone saves: big-bucks-backup-2026-10-10.zip. */
export function backupFileName(day: string): string {
  if (!DAY.test(day)) throw new Error(`Not a day: ${day}`);
  return `big-bucks-backup-${day}.zip`;
}

/** Every table as csv/<table>.csv and json/<table>.json, plus a README and manifest.json. */
export function buildBackupZip(data: Export): Uint8Array {
  if (!data || !Array.isArray(data.tables) || data.tables.length === 0)
    throw new Error('The database sent no tables.');
  const files: Zippable = {};
  for (const t of data.tables) {
    if (!TABLE.test(t.name)) throw new Error(`Unexpected table name: ${t.name}`);
    files[`csv/${t.name}.csv`] = strToU8(t.csv);
    files[`json/${t.name}.json`] = strToU8(t.json);
  }
  const rows = data.tables.reduce((n, t) => n + t.rows, 0);
  files['manifest.json'] = strToU8(
    JSON.stringify(
      {
        taken_at: data.taken_at,
        day: data.day,
        tables: data.tables.map((t) => ({ name: t.name, rows: t.rows })),
        rows,
      },
      null,
      2,
    ) + '\n',
  );
  files['README.txt'] = strToU8(
    [
      `Big Bucks backup, taken ${data.taken_at} (UTC).`,
      `${data.tables.length} tables, ${rows} rows.`,
      '',
      'csv/   each table as a CSV file (opens in Excel or Google Sheets).',
      'json/  each table as JSON, with every value exactly as the database holds it.',
      '',
      'Money is in cents (amount_cents 1234 = $12.34). Times are in UTC.',
      'The daily backup in the big-bucks-backups repo is the one to restore from;',
      'this zip is a copy to keep before a big change.',
      '',
    ].join('\r\n'),
  );
  return zipSync(files, { level: 6 });
}
