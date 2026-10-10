// A backup of the LOCAL copy on this computer, made exactly like the daily backup of
// production (same script, same read-only backup login), for practising the restore
// drill and for testing:
//
//   npm run backup:local
//   npm run restore:drill -- .local-backup/backup
//
// It refuses anything but the local database (127.0.0.1:54322, is_local_dev = true).
// It gives the local backup login a fresh password each time; nothing is saved. Like
// the workflow, it records the backup in the database (record_backup).

import { record, take } from '../../ops/backup-repo/scripts/backup.ts';
import { LocalDb } from '../timemachine/db.ts';

const OUT = '.local-backup';

async function main(): Promise<void> {
  const db = await LocalDb.connect();
  let password: string;
  try {
    const [r] = await db.q<{ words: string }>('select public.set_backup_login() as words');
    password = r.words.split(': ').pop()!.trim();
  } finally {
    await db.close();
  }
  const url = `postgresql://backup_reader:${password}@127.0.0.1:54322/postgres`;
  const { message } = await take(url, OUT);
  console.log(message);
  // As the workflow does once the commit is safe: prelaunch_reset() checks this record.
  console.log(await record(url, OUT));
  console.log(`Saved in ${OUT}/backup. Try the drill: npm run restore:drill -- ${OUT}/backup`);
}

main().catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
