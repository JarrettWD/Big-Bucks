// Settings → Backup: the Download backup button (Stage 5). The download-backup
// function signs in as Dad with his own token; the database (parent_backup_export)
// checks he's a parent with the authenticator code, writes every table as CSV and
// JSON, and logs the download. The phone saves the zip.

import { useState } from 'react';
import { anonKeyForFunctions, functionsUrl, supabase } from '../../lib/supabase';
import { TEXT } from './settingsText';

/** The file name from Content-Disposition, or a plain one. */
function zipName(disposition: string | null): string {
  const m = /filename="([^"]+)"/.exec(disposition ?? '');
  return m ? m[1] : 'big-bucks-backup.zip';
}

export default function BackupDownload() {
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const download = async () => {
    setBusy(true);
    setSaved(null);
    setError(null);
    try {
      const { data } = await supabase.auth.getSession();
      const token = data.session?.access_token;
      if (!token) throw new Error(TEXT.backupSignIn);
      const res = await fetch(`${functionsUrl}/download-backup`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, apikey: anonKeyForFunctions },
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(body.error ?? `(${res.status})`);
      }
      const name = zipName(res.headers.get('content-disposition'));
      const url = URL.createObjectURL(await res.blob());
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      setSaved(name);
    } catch (e) {
      setError(TEXT.backupFailed((e as Error).message));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="set__card" id="set-backup" aria-labelledby="set-backup-h">
      <h2 id="set-backup-h">{TEXT.backupTitle}</h2>
      <p className="set__muted" id="set-backup-help">
        {TEXT.backupHelp}
      </p>
      <button
        type="button"
        className="set__btn"
        onClick={download}
        disabled={busy}
        aria-describedby="set-backup-help"
      >
        ⬇ {busy ? TEXT.backupBusy : TEXT.backupButton}
      </button>
      {saved && (
        <p className="set__done" role="status">
          {TEXT.backupDone(saved)}
        </p>
      )}
      {error && (
        <p className="set__error" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
