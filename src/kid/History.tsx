// "See all": her whole history, newest first, 30 lines at a time.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useKid } from './KidShell';
import { ActivityList } from './home/ActivityList';
import type { ActivityRow } from './home/activityText';
import './home/Home.css';

const PAGE = 30;

export default function History() {
  const { profile } = useKid();
  const [rows, setRows] = useState<ActivityRow[]>([]);
  const [more, setMore] = useState(true);
  const [busy, setBusy] = useState(false);
  const [year, setYear] = useState(0);

  const loadMore = useCallback(
    async (after: ActivityRow) => {
      setBusy(true);
      const { data } = await supabase.rpc('my_activity', {
        p_account_id: profile.accountId,
        p_limit: PAGE,
        p_before_at: after.at,
        p_before_key: after.item_key,
      });
      const page = (data ?? []) as ActivityRow[];
      setRows((r) => [...r, ...page]);
      setMore(page.length === PAGE);
      setBusy(false);
    },
    [profile.accountId],
  );

  useEffect(() => {
    let alive = true;
    Promise.all([
      supabase.rpc('app_today'),
      supabase.rpc('my_activity', { p_account_id: profile.accountId, p_limit: PAGE }),
    ]).then(([t, a]) => {
      if (!alive) return;
      const page = (a.data ?? []) as ActivityRow[];
      setYear(Number(String(t.data ?? '').slice(0, 4)));
      setRows(page);
      setMore(page.length === PAGE);
    });
    return () => {
      alive = false;
    };
  }, [profile.accountId]);

  return (
    <div className="home home--single">
      <section className="card" aria-labelledby="h-history">
        <h1 id="h-history" className="card__title">
          Your history
        </h1>
        {year > 0 && <ActivityList rows={rows} thisYear={year} />}
        {more && rows.length > 0 && (
          <button
            type="button"
            className="btn btn--soft"
            onClick={() => loadMore(rows[rows.length - 1])}
            disabled={busy}
          >
            {busy ? 'Loading…' : 'Show more'}
          </button>
        )}
        <Link className="btn" to="/kid">
          Back to Home
        </Link>
      </section>
    </div>
  );
}
