// On Home: the set-up banner until onboarding is done (and when the house rules
// change), and "What's new" once for each feature switched on after she onboarded.
// Her very first visit opens the welcome screens; after that she chooses.

import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { kidRpc, useKidView } from '../kidView';
import { TEXT, type OnboardingState } from './onboardingText';
import './Welcome.css';

/** Remembered on this device only, so the welcome screens open by themselves once. */
const openedKey = (account: string) => `bb-welcome-opened:${account}`;

export function SetupBanner() {
  const view = useKidView();
  const navigate = useNavigate();
  const [state, setState] = useState<OnboardingState | null>(null);

  useEffect(() => {
    let live = true;
    void kidRpc<OnboardingState>(view, 'onboarding_state', { p_account_id: view.accountId }).then(
      ({ data }) => {
        if (!live || !data) return;
        setState(data);
        if (view.viewing || data.done || data.signed_version !== null) return;
        let opened = true;
        try {
          opened = window.localStorage.getItem(openedKey(view.accountId)) === 'yes';
          window.localStorage.setItem(openedKey(view.accountId), 'yes');
        } catch {
          // No storage (a private window): don't keep opening it.
        }
        if (!opened) navigate(`${view.base}/welcome`);
      },
    );
    return () => {
      live = false;
    };
  }, [view, navigate]);

  if (!state) return null;
  let words: string;
  let button: string;
  let to = `${view.base}/welcome`;
  if (!state.done && state.signed_version === null) {
    words = TEXT.setupBanner;
    button = TEXT.setupStart;
  } else if (!state.done) {
    words = TEXT.setupContinue;
    button = TEXT.setupContinueButton;
  } else if (state.needs_signature) {
    words = TEXT.changedBanner;
    button = TEXT.readIt;
    to = `${view.base}/welcome?step=agreement`;
  } else return null;

  return (
    <section className="banner" aria-label="Setting up">
      <div className="banner__card banner__card--celebrate">
        <p className="banner__title">{words}</p>
        <Link className="btn btn--small" to={to}>
          {button}
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
