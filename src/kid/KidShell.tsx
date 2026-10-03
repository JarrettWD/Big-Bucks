// The kid app's frame: her name and notifications bell on top, the four tabs at
// the bottom (Wish List only when its feature switch is on for her), and the
// screen in between. Stage 7 fills the screens in.

import { useEffect } from 'react';
import { Link, NavLink, Outlet, useOutletContext } from 'react-router-dom';
import { useAuth, type Profile } from '../auth/AuthProvider';
import { getRememberedKid, rememberKid } from '../auth/remember';
import { useKidSummary, type KidSummary } from './useKid';
import './KidShell.css';

export interface KidContext {
  profile: Profile;
  summary: KidSummary;
}

// eslint-disable-next-line react-refresh/only-export-components
export const useKid = () => useOutletContext<KidContext>();

const TABS = [
  { to: '/kid', label: 'Home', icon: '🏠', end: true },
  { to: '/kid/graphs', label: 'Graphs', icon: '📈' },
  { to: '/kid/trade', label: 'Buy / Sell', icon: '🔁' },
  { to: '/kid/wishlist', label: 'Wish List', icon: '⭐', wishlist: true },
];

export default function KidShell() {
  const { profile, signOut } = useAuth();
  const summary = useKidSummary(profile?.accountId ?? null);

  // Remember her on this device, so next time she only enters her PIN.
  useEffect(() => {
    if (!profile) return;
    const r = getRememberedKid();
    if (r?.username !== profile.username || r.displayName !== profile.displayName)
      rememberKid({ username: profile.username, displayName: profile.displayName });
  }, [profile]);

  if (!profile) return null;
  const tabs = TABS.filter((t) => !t.wishlist || summary.wishlist);

  return (
    <div className="kid">
      <header className="kid__top">
        <span className="kid__hi">Hi, {profile.displayName}!</span>
        <Link
          to="/kid/notices"
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
        <button type="button" className="kid__out" onClick={signOut}>
          Sign out
        </button>
      </header>

      <main className="kid__main">
        <Outlet context={{ profile, summary } satisfies KidContext} />
      </main>

      <nav className="kid__tabs" aria-label="Main">
        {tabs.map((t) => (
          <NavLink key={t.to} to={t.to} end={t.end} className="kid__tab">
            <span aria-hidden="true" className="kid__tab-icon">
              {t.icon}
            </span>
            <span>{t.label}</span>
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
