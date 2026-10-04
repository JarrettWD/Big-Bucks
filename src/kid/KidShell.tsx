// The kid app's frame: her name and notifications bell on top, the four tabs at
// the bottom (Wish List only when its feature switch is on for her), and the
// screen in between.
//
// The same frame shows her screens to Dad in "View as <kid>" (a `view` with
// viewing = true): a read-only banner with Exit on top, only Home and Graphs as
// tabs, every read through parent_view, and every action switched off.

import { useEffect, useMemo } from 'react';
import { Link, NavLink, Outlet, useOutletContext } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { getRememberedKid, rememberKid } from '../auth/remember';
import { KidViewContext, type KidView } from './kidView';
import { useKidSummary, type KidSummary } from './useKid';
import './KidShell.css';

export interface KidContext {
  view: KidView;
  summary: KidSummary & { reload: () => void };
}

// eslint-disable-next-line react-refresh/only-export-components
export const useKid = () => useOutletContext<KidContext>();

const TABS = [
  { to: '', label: 'Home', icon: '🏠', end: true },
  { to: '/graphs', label: 'Graphs', icon: '📈' },
  { to: '/trade', label: 'Buy / Sell', icon: '🔁', action: true },
  { to: '/wishlist', label: 'Wish List', icon: '⭐', wishlist: true, action: true },
];

export default function KidShell({ viewing }: { viewing?: KidView }) {
  const { profile, signOut } = useAuth();
  const view = useMemo<KidView | null>(
    () =>
      viewing ??
      (profile?.accountId
        ? { accountId: profile.accountId, name: profile.displayName, viewing: false, base: '/kid' }
        : null),
    [viewing, profile],
  );
  const summary = useKidSummary(view);

  // Remember her on this device, so next time she only enters her PIN (her own app only).
  useEffect(() => {
    if (!profile || viewing) return;
    const r = getRememberedKid();
    if (r?.username !== profile.username || r.displayName !== profile.displayName)
      rememberKid({ username: profile.username, displayName: profile.displayName });
  }, [profile, viewing]);

  if (!view) return null;
  // Dad sees her Home and Graphs; Buy / Sell and the Wish List are hers to use.
  const tabs = TABS.filter((t) => (!t.wishlist || summary.wishlist) && !(view.viewing && t.action));

  return (
    <KidViewContext.Provider value={view}>
      <div className={view.viewing ? 'kid kid--viewing' : 'kid'}>
        <div className="kid__head">
          {view.viewing && (
            <div className="kid__viewing" role="note" id="viewing-banner">
              <span>{`Viewing ${view.name}'s screens — read-only`}</span>
              <Link to="/parent" className="kid__exit">
                Exit
              </Link>
            </div>
          )}
          <header className="kid__top">
            <span className="kid__hi">Hi, {view.name}!</span>
            <Link
              to={`${view.base}/notices`}
              className="kid__bell"
              aria-label={summary.unread ? `Notices, ${summary.unread} new` : 'Notices'}
            >
              <span aria-hidden="true">🔔</span>
              {summary.unread > 0 && (
                <span className="kid__badge" aria-hidden="true">
                  {summary.unread > 9 ? '9+' : summary.unread}
                </span>
              )}
            </Link>
            {!view.viewing && (
              <button type="button" className="kid__out" onClick={signOut}>
                Sign out
              </button>
            )}
          </header>
        </div>

        <main className="kid__main">
          <Outlet context={{ view, summary } satisfies KidContext} />
        </main>

        <nav className="kid__tabs" aria-label="Main">
          {tabs.map((t) => (
            <NavLink key={t.to} to={`${view.base}${t.to}`} end={t.end} className="kid__tab">
              <span aria-hidden="true" className="kid__tab-icon">
                {t.icon}
              </span>
              <span>{t.label}</span>
            </NavLink>
          ))}
        </nav>
      </div>
    </KidViewContext.Provider>
  );
}
