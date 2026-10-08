// On Home: a banner when the house rules change (and, in Dad's "View as", whether
// she has set up yet), and "What's new" once for each feature switched on after
// she onboarded.

import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { kidRpc, useKidView } from '../kidView';
import { TEXT, type OnboardingState } from './onboardingText';
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
  if (!state.done && !view.viewing && state.unlocked)
    return (
      <section className="banner" aria-label="Setting up">
        <div className="banner__card banner__card--celebrate">
          <p className="banner__title">{TEXT.setupContinue}</p>
          <Link className="btn btn--small" to={`${view.base}/welcome`}>
            {TEXT.keepGoing}
          </Link>
        </div>
      </section>
    );
  if (!state.done) {
    if (!view.viewing) return null; // she's locked to her welcome screens anyway
    return (
      <section className="banner" aria-label="Setting up">
        <div className="banner__card banner__card--celebrate">
          <p className="banner__title">
            {state.signed_version === null ? TEXT.setupBanner : TEXT.setupContinue}
          </p>
        </div>
      </section>
    );
  }
  if (!state.needs_signature) return null;
  return (
    <section className="banner" aria-label="Setting up">
      <div className="banner__card banner__card--celebrate">
        <p className="banner__title">{TEXT.changedBanner}</p>
        <Link className="btn btn--small" to={`${view.base}/welcome?step=agreement`}>
          {TEXT.readIt}
        </Link>
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
