// The kid app's frame: her name and notifications bell on top, the four tabs at
// the bottom (Wish List only when its feature switch is on for her), and the
// screen in between.
//
// The same frame shows her screens to Dad in "View as <kid>" (a `view` with
// viewing = true): a read-only banner with Exit on top, only Home and Graphs as
// tabs, every read through parent_view, and every action switched off.
//
// Until she has finished onboarding (Dad, B4 review), the app is locked to it:
// the tabs and the bell stay in place but greyed out, a tap says why (at the top
// of her step, so it never covers anything), and any other address brings her
// back to her step. It unlocks as soon as both signatures are done and her first
// deposit is in, so her first decision can open Buy / Sell. Dad's "View as" isn't
// locked.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, NavLink, Outlet, useLocation, useOutletContext } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { getRememberedKid, rememberKid } from '../auth/remember';
import { kidRpc, KidViewContext, type KidView } from './kidView';
import { TEXT as ONBOARDING } from './onboarding/onboardingText';
import { useKidSummary, type KidSummary } from './useKid';
import './KidShell.css';

export interface KidContext {
  view: KidView;
  summary: KidSummary & { reload: () => void };
  /** Whether the app is hers yet (null while loading), and a fresh look. */
  onboarding: { unlocked: boolean | null; reload: () => Promise<void> };
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
  const location = useLocation();

  // Is the app hers yet? (Dad viewing: never locked.)
  const [unlocked, setUnlocked] = useState<boolean | null>(null);
  const reloadOnboarding = useCallback(async () => {
    if (!view) return;
    const { data } = await kidRpc<{ unlocked: boolean }>(view, 'onboarding_state', {
      p_account_id: view.accountId,
    });
    setUnlocked(Boolean(data?.unlocked));
  }, [view]);
  useEffect(() => {
    if (!view) return;
    let live = true;
    void kidRpc<{ unlocked: boolean }>(view, 'onboarding_state', {
      p_account_id: view.accountId,
    }).then(({ data }) => {
      if (live) setUnlocked(Boolean(data?.unlocked));
    });
    return () => {
      live = false;
    };
  }, [view]);

  // "Finish setting up first…", for a few seconds after she taps a locked tab.
  const [nudge, setNudge] = useState(0);
  const nudgeTimer = useRef<number | undefined>(undefined);
  const nudgeHer = () => {
    setNudge((n) => n + 1);
    window.scrollTo(0, 0); // the line is at the top of her step
    window.clearTimeout(nudgeTimer.current);
    nudgeTimer.current = window.setTimeout(() => setNudge(0), 4000);
  };
  useEffect(() => () => window.clearTimeout(nudgeTimer.current), []);

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
  const locked = !view.viewing && unlocked === false;
  const onWelcome = location.pathname.startsWith(`${view.base}/welcome`);

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
            {locked ? (
              <button
                type="button"
                className="kid__bell kid__bell--locked"
                aria-disabled="true"
                aria-label="Notices"
                aria-describedby="kid-locked"
                onClick={nudgeHer}
              >
                <span aria-hidden="true">🔔</span>
              </button>
            ) : (
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
            )}
            {!view.viewing && (
              <button type="button" className="kid__out" onClick={signOut}>
                Sign out
              </button>
            )}
          </header>
        </div>

        <main className="kid__main">
          {locked && (
            <p
              id="kid-locked"
              className={nudge ? 'kid__nudge kid__nudge--on' : 'kid__nudge'}
              role="status"
            >
              {nudge ? ONBOARDING.locked : ''}
            </p>
          )}
          {!view.viewing && unlocked === null ? (
            <div aria-busy="true" />
          ) : locked && !onWelcome ? (
            // Any other address during onboarding: back to her step.
            <Navigate to={`${view.base}/welcome`} replace />
          ) : (
            <Outlet
              context={
                {
                  view,
                  summary,
                  onboarding: { unlocked, reload: reloadOnboarding },
                } satisfies KidContext
              }
            />
          )}
        </main>

        <nav className="kid__tabs" aria-label="Main">
          {tabs.map((t) =>
            locked ? (
              <button
                key={t.to}
                type="button"
                className="kid__tab kid__tab--locked"
                aria-disabled="true"
                aria-describedby="kid-locked"
                onClick={nudgeHer}
              >
                <span aria-hidden="true" className="kid__tab-icon">
                  {t.icon}
                </span>
                <span>{t.label}</span>
              </button>
            ) : (
              <NavLink key={t.to} to={`${view.base}${t.to}`} end={t.end} className="kid__tab">
                <span aria-hidden="true" className="kid__tab-icon">
                  {t.icon}
                </span>
                <span>{t.label}</span>
              </NavLink>
            ),
          )}
        </nav>
      </div>
    </KidViewContext.Provider>
  );
}
