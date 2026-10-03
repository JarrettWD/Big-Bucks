// The kid screens for now: Home shows her total worth (with the "?" and the
// "Updating…" state), the notices list is read-only, and the other tabs are
// placeholders. Stage 7 builds them out.

import { useEffect, useState } from 'react';
import { Explain } from '../components/Glossary';
import { Updating } from '../components/Updating';
import { formatCents } from '../lib/money';
import { supabase } from '../lib/supabase';
import { useKid } from './KidShell';

export function KidHome() {
  const { summary } = useKid();
  return (
    <>
      <section className="kid-card" aria-labelledby="worth">
        <p id="worth" className="kid-card__label">
          Total worth <Explain term="Total worth" />
        </p>
        <Updating updating={summary.updating}>
          <p className="kid-big">
            {summary.totalWorthCents === null ? '…' : formatCents(summary.totalWorthCents)}
          </p>
        </Updating>
      </section>
      <section className="kid-card">
        <p className="kid-soon">Your savings, GICs and funds will show up here soon.</p>
      </section>
    </>
  );
}

function Placeholder({ title }: { title: string }) {
  return (
    <section className="kid-card">
      <h1 className="kid-title">{title}</h1>
      <p className="kid-soon">Coming soon.</p>
    </section>
  );
}

export const KidGraphs = () => <Placeholder title="Graphs" />;
export const KidTrade = () => <Placeholder title="Buy / Sell" />;
export const KidWishList = () => <Placeholder title="Wish List" />;

interface Notice {
  id: number;
  title: string;
  body: string;
  created_at: string;
  read_at: string | null;
}

export function KidNotices() {
  const [notices, setNotices] = useState<Notice[] | null>(null);
  useEffect(() => {
    let alive = true;
    supabase
      .from('notifications')
      .select('id, title, body, created_at, read_at')
      .order('created_at', { ascending: false })
      .limit(50)
      .then(({ data }) => alive && setNotices(data ?? []));
    return () => {
      alive = false;
    };
  }, []);
  return (
    <section className="kid-card">
      <h1 className="kid-title">Notices</h1>
      {notices === null ? (
        <p className="kid-soon">Loading…</p>
      ) : notices.length === 0 ? (
        <p className="kid-soon">Nothing new. You're all caught up!</p>
      ) : (
        <ul className="notices">
          {notices.map((n) => (
            <li key={n.id} className={n.read_at ? '' : 'is-new'}>
              <strong>{n.title}</strong>
              {n.body && <span>{n.body}</span>}
              <time dateTime={n.created_at}>
                {new Date(n.created_at).toLocaleDateString('en-CA', {
                  month: 'short',
                  day: 'numeric',
                  timeZone: 'America/Edmonton',
                })}
              </time>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
