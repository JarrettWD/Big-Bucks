// The parent side's frame: its own header and routes. Reached only by a parent
// who has passed the authenticator step (the route guard in App.tsx); the
// database requires the same (aal2) for every parent read and action.
// Tabs: bottom of the screen on phones (Dad's main device), top from 720px.
// The Approvals count comes from parent_inbox(), shared with the Approvals screen.

import { useEffect, useState } from 'react';
import { Link, NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { formatCents } from '../lib/money';
import { supabase } from '../lib/supabase';
import { useInbox } from './useInbox';
import './Parent.css';

export default function ParentShell() {
  const { profile, signOut } = useAuth();
  const inbox = useInbox();
  const waiting = inbox.inbox ? inbox.inbox.requests.length + inbox.inbox.questions.length : 0;
  return (
    <div className="parent">
      <header className="parent__top">
        <span className="parent__title">Big Bucks · {profile?.displayName}</span>
        <button type="button" onClick={signOut}>
          Sign out
        </button>
      </header>
      <nav className="parent__tabs" aria-label="Parent">
        <NavLink to="/parent" end>
          <span className="parent__tab-icon" aria-hidden="true">
            🏠
          </span>
          Dashboard
        </NavLink>
        <NavLink
          to="/parent/approvals"
          aria-label={waiting > 0 ? `Approvals, ${waiting} waiting` : 'Approvals'}
        >
          <span className="parent__tab-icon" aria-hidden="true">
            ✅
          </span>
          <span>
            Approvals
            {waiting > 0 && (
              <span className="parent__badge" aria-hidden="true">
                {waiting}
              </span>
            )}
          </span>
        </NavLink>
        <NavLink to="/parent/settings">
          <span className="parent__tab-icon" aria-hidden="true">
            ⚙️
          </span>
          Settings
        </NavLink>
      </nav>
      <main className="parent__main">
        <Outlet context={inbox} />
      </main>
    </div>
  );
}

interface Row {
  account_id: string;
  is_test: boolean;
  total_worth_cents: number;
}

export function ParentDashboard() {
  const [rows, setRows] = useState<(Row & { name: string })[] | null>(null);
  useEffect(() => {
    let alive = true;
    Promise.all([
      supabase.from('account_balances').select('account_id, is_test, total_worth_cents'),
      supabase.from('accounts').select('id, name'),
    ]).then(([b, a]) => {
      if (!alive) return;
      const names = new Map((a.data ?? []).map((x) => [x.id, x.name as string]));
      setRows(
        ((b.data ?? []) as Row[])
          .map((r) => ({ ...r, name: names.get(r.account_id) ?? '?' }))
          .sort((x, y) => Number(x.is_test) - Number(y.is_test) || x.name.localeCompare(y.name)),
      );
    });
    return () => {
      alive = false;
    };
  }, []);
  return (
    <section className="parent-card">
      <h1>Dashboard</h1>
      {rows === null ? (
        <p>Loading…</p>
      ) : (
        <ul className="parent-kids">
          {rows.map((r) => (
            <li key={r.account_id}>
              <span>
                {r.name}
                {r.is_test && <em> (test account)</em>}
              </span>
              <strong>{formatCents(r.total_worth_cents)}</strong>
            </li>
          ))}
        </ul>
      )}
      <p>
        <Link to="/parent/approvals">See what's waiting in Approvals</Link>
      </p>
      <p className="parent-soon">The rest of the dashboard arrives in stage 8, part B.</p>
    </section>
  );
}

export function ParentSettings() {
  return (
    <section className="parent-card">
      <h1>Settings</h1>
      <p className="parent-soon">Rates, the deposit cap and feature switches arrive in stage 8.</p>
    </section>
  );
}
