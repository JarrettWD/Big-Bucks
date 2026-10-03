// The kid screens still to come in stage 7: the notices list is read-only, and
// Graphs, Buy / Sell and Wish List are placeholders. Home is in ./home.

import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

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
