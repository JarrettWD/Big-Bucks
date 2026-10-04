// Her notices (the bell), newest first. Each date comes from the database
// (my_notices), never from the phone's clock. Opening the list counts as reading
// what's on it: those notices are marked read, but keep their "New" tag until she
// leaves, so she can still see which ones are new. Wording: docs/MESSAGES.md §9.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { formatDate } from '../../lib/format';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import '../home/Home.css';
import './Notices.css';

const PAGE = 50;

interface Notice {
  id: number;
  type: string;
  title: string;
  body: string;
  on_day: string;
  is_new: boolean;
}

export default function Notices() {
  const { profile, summary } = useKid();
  const [notices, setNotices] = useState<Notice[] | null>(null);
  const [year, setYear] = useState(0);
  const [more, setMore] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const { reload } = summary;

  /** Shows a page, then marks its new notices read (the bell count goes down). */
  const show = useCallback(
    async (page: Notice[]) => {
      setMore(page.length === PAGE);
      const fresh = page.filter((n) => n.is_new).map((n) => n.id);
      if (fresh.length) {
        await supabase.rpc('mark_notices_read', { p_ids: fresh });
        reload();
      }
    },
    [reload],
  );

  useEffect(() => {
    let alive = true;
    Promise.all([
      supabase.rpc('app_today'),
      supabase.rpc('my_notices', { p_account_id: profile.accountId, p_limit: PAGE }),
    ]).then(([t, n]) => {
      if (!alive) return;
      if (n.error) {
        setError(true);
        return;
      }
      const page = (n.data ?? []) as Notice[];
      setYear(Number(String(t.data ?? '').slice(0, 4)));
      setNotices(page);
      void show(page);
    });
    return () => {
      alive = false;
    };
  }, [profile.accountId, show]);

  const loadMore = async () => {
    if (!notices?.length) return;
    setBusy(true);
    const { data } = await supabase.rpc('my_notices', {
      p_account_id: profile.accountId,
      p_limit: PAGE,
      p_before_id: notices[notices.length - 1].id,
    });
    const page = (data ?? []) as Notice[];
    setNotices([...notices, ...page]);
    setBusy(false);
    void show(page);
  };

  return (
    <div className="home home--single">
      <section className="card" aria-labelledby="h-notices">
        <h1 id="h-notices" className="card__title">
          Notices
        </h1>
        {error ? (
          <p className="muted">
            Big Bucks couldn't load your notices just now. Please try again in a minute.
          </p>
        ) : notices === null ? (
          <p className="muted" aria-busy="true">
            Loading…
          </p>
        ) : notices.length === 0 ? (
          <p className="muted">Nothing new. You're all caught up!</p>
        ) : (
          <ul className="notices">
            {notices.map((n) => (
              <li key={n.id} className={`notice${n.is_new ? ' notice--new' : ''}`}>
                <span className="notice__top">
                  <strong className="notice__title">{n.title}</strong>
                  {n.is_new && <span className="notice__new">New</span>}
                </span>
                {n.body && <span className="notice__body">{n.body}</span>}
                <span className="notice__date">{formatDate(n.on_day, year)}</span>
                {n.type === 'question' && (
                  <Link className="notice__link" to="/kid/history#questions">
                    See your questions
                  </Link>
                )}
              </li>
            ))}
          </ul>
        )}
        {more && (
          <button type="button" className="btn btn--soft" onClick={loadMore} disabled={busy}>
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
