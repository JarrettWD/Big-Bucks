// On Home: a banner when the house rules change (and, in Dad's "View as", whether
// she has set up yet), and "What's new" once for each feature switched on after
// she onboarded.

import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { kidRpc, useKidView } from '../kidView';
import { TEXT, homeBanner, type OnboardingState } from './onboardingText';
import './Welcome.css';

/**
 * In her own app, Home is reachable only once onboarding is done, so the banner
 * there is for a new version of the house rules to sign. In Dad's "View as" it
 * also shows whether she has set up yet (no button: he can't sign for her).
 */
export function SetupBanner() {
  const view = useKidView();
  const [state, setState] = useState<OnboardingState | null>(null);

  useEffect(() => {
    let live = true;
    void kidRpc<OnboardingState>(view, 'onboarding_state', { p_account_id: view.accountId }).then(
      ({ data }) => {
        if (live && data) setState(data);
      },
    );
    return () => {
      live = false;
    };
  }, [view]);

  if (!state) return null;
  const which = homeBanner(state, view.viewing);
  if (which === null) return null;
  const title =
    which === 'continue' || which === 'viewing_continue'
      ? TEXT.setupContinue
      : which === 'viewing_start'
        ? TEXT.setupBanner
        : which === 'changed'
          ? TEXT.changedBanner
          : TEXT.changedWaiting;
  const link =
    which === 'continue'
      ? { to: `${view.base}/welcome`, label: TEXT.keepGoing }
      : which === 'changed'
        ? { to: `${view.base}/welcome?step=agreement`, label: TEXT.readIt }
        : null;
  const label =
    which === 'changed' || which === 'waiting_for_dad' ? 'Your agreement' : 'Setting up';
  return (
    <section className="banner" aria-label={label}>
      <div className="banner__card banner__card--celebrate">
        <p className="banner__title">{title}</p>
        {link && (
          <Link className="btn btn--small" to={link.to}>
            {link.label}
          </Link>
        )}
      </div>
    </section>
  );
}

interface NewThing {
  feature: string;
  title: string;
  lines: string[];
  link: string | null;
}

export function WhatsNew() {
  const view = useKidView();
  const navigate = useNavigate();
  const [items, setItems] = useState<NewThing[]>([]);

  useEffect(() => {
    if (view.viewing) return; // Dad's "View as" never marks anything as seen.
    let live = true;
    void supabase.rpc('whats_new').then(({ data }) => {
      if (live && Array.isArray(data)) setItems(data as NewThing[]);
    });
    return () => {
      live = false;
    };
  }, [view.viewing]);

  const item = items[0];
  if (!item) return null;
  const seen = async (go: boolean) => {
    await supabase.rpc('mark_whats_new_seen', { p_feature: item.feature });
    setItems((all) => all.slice(1));
    if (go && item.link) navigate(item.link.replace(/^\/kid/, view.base));
  };
  return (
    <section className="whatsnew" aria-labelledby="whatsnew-title">
      <h2 id="whatsnew-title">{item.title}</h2>
      {item.lines.map((l) => (
        <p key={l}>{l}</p>
      ))}
      <div className="welcome__buttons">
        {item.link && (
          <button type="button" className="btn" onClick={() => void seen(true)}>
            {TEXT.showMe}
          </button>
        )}
        <button type="button" className="btn btn--soft" onClick={() => void seen(false)}>
          {TEXT.gotIt}
        </button>
      </div>
    </section>
  );
}
