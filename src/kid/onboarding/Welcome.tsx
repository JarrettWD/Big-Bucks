// Onboarding, together with Dad (SPEC "Onboarding"; wording in MESSAGES §11):
//   welcome     what we'll do together, and one button: Let's get started
//   tour        a quick look around (required; Back and Next)
//   agreement   the house rules, which she signs; Dad countersigns on his phone
//   decision    her first deposit (asked for right here; if Dad says no, she sees
//               why and asks again), then what her money does
// "Make it yours" and "your first wish" join when their features are built.
// The rest of the app stays locked until both have signed and her first deposit
// is in (KidShell); then a GIC or fund choice opens Buy / Sell. Her place is
// saved as she goes (save_onboarding_step), so she resumes where she left off.
// In Dad's "View as", every step shows but nothing can be signed, asked or chosen,
// and her place isn't moved.

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { Explain } from '../../components/Glossary';
import { supabase } from '../../lib/supabase';
import { parseAmount } from '../trade/moves';
import { useKid } from '../KidShell';
import { kidRpc } from '../kidView';
import { AgreementView } from './AgreementView';
import {
  decisionChoices,
  firstStep,
  shownSteps,
  stepList,
  tourCards,
  TEXT,
  type OnboardingState,
  type Step,
} from './onboardingText';
import '../home/Home.css';
import './Welcome.css';

export default function Welcome() {
  const { view, summary, onboarding } = useKid();
  const [search] = useSearchParams();
  const [state, setState] = useState<OnboardingState | null>(null);
  const [failed, setFailed] = useState(false);
  const [place, setPlace] = useState<{ step: Step; card: number } | null>(null);
  const navigate = useNavigate();

  const load = useCallback(async () => {
    const { data, error } = await kidRpc<OnboardingState>(view, 'onboarding_state', {
      p_account_id: view.accountId,
    });
    if (error || !data) {
      setFailed(true);
      return null;
    }
    setFailed(false);
    setState(data);
    if (data.unlocked) await onboarding.reload(); // the tabs open as soon as it's hers
    return data;
  }, [view, onboarding]);

  useEffect(() => {
    let live = true;
    void kidRpc<OnboardingState>(view, 'onboarding_state', { p_account_id: view.accountId }).then(
      ({ data, error }) => {
        if (!live) return;
        if (error || !data) return setFailed(true);
        setState(data);
        // Dad viewing may open any step; she resumes where she left off.
        const asked = search.get('step') as Step | null;
        if (asked && shownSteps(data).includes(asked) && (view.viewing || data.done))
          setPlace({ step: asked, card: 0 });
        else setPlace({ step: firstStep(data), card: data.resume_card ?? 0 });
      },
    );
    return () => {
      live = false;
    };
  }, [view, search]);

  if (failed)
    return (
      <div className="home home--single">
        <section className="card">
          <p>{TEXT.loadError}</p>
          <button type="button" className="btn" onClick={() => void load()}>
            {TEXT.retry}
          </button>
        </section>
      </div>
    );
  if (!state || !place) return <div className="home" aria-busy="true" />;
  // Finished, with nothing new to sign: nothing to do here.
  if (state.done && !state.needs_signature && !view.viewing)
    return <Navigate to={view.base} replace />;

  const steps = shownSteps(state);
  const go = (step: Step, card = 0) => {
    setPlace({ step, card });
    window.scrollTo(0, 0);
    if (!view.viewing && !state.done)
      // (A Supabase call only runs once its result is asked for, hence the .then.)
      void supabase
        .rpc('save_onboarding_step', { p_step: step, p_card: card })
        .then(() => undefined);
  };
  const after = (s: Step) => steps[steps.indexOf(s) + 1] ?? 'decision';

  return (
    <div className="home home--single welcome">
      {place.step === 'welcome' && (
        <WelcomeStep state={state} onNext={() => go(after('welcome'))} />
      )}
      {place.step === 'tour' && (
        <TourStep
          state={state}
          card={place.card}
          onCard={(c) => go('tour', c)}
          onBack={() => go('welcome')}
          onNext={() => go(after('tour'))}
        />
      )}
      {place.step === 'agreement' && (
        <AgreementStep
          state={state}
          onBack={() => go('tour', tourCards(state.rules, state.steps.includes('wish')).length - 1)}
          onSigned={async () => {
            await load();
            summary.reload();
          }}
          // A new version signed after onboarding goes back Home; otherwise on to her first decision.
          onNext={() => (state.done ? navigate(view.base) : go(after('agreement')))}
        />
      )}
      {place.step === 'decision' && (
        <DecisionStep
          state={state}
          reload={load}
          onFinished={async () => {
            await onboarding.reload();
            summary.reload();
          }}
        />
      )}
    </div>
  );
}

function WelcomeStep({ state, onNext }: { state: OnboardingState; onNext: () => void }) {
  const ref = useFocus<HTMLHeadingElement>();
  return (
    <section className="card welcome__card" aria-labelledby="w-title">
      <h1 id="w-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {TEXT.welcomeTitle(state.name)}
      </h1>
      <p className="welcome__tag">{TEXT.tagline}</p>
      <p>{TEXT.welcomeBody}</p>
      <h2 className="card__title">{TEXT.together}</h2>
      <ol className="welcome__steps">
        {stepList(shownSteps(state)).map((s) => (
          <li key={s}>{s}</li>
        ))}
      </ol>
      <div className="welcome__buttons">
        <button type="button" className="btn btn--gold" onClick={onNext}>
          {TEXT.getStarted}
        </button>
      </div>
    </section>
  );
}

function TourStep({
  state,
  card,
  onCard,
  onBack,
  onNext,
}: {
  state: OnboardingState;
  card: number;
  onCard: (card: number) => void;
  onBack: () => void;
  onNext: () => void;
}) {
  const cards = tourCards(state.rules, state.steps.includes('wish'));
  const i = Math.min(card, cards.length - 1);
  const ref = useFocus<HTMLHeadingElement>(i);
  const shown = cards[i];
  const last = i === cards.length - 1;
  return (
    <section className="card welcome__card" aria-labelledby="t-title">
      <p className="welcome__count">
        {i + 1} / {cards.length}
      </p>
      <h1 id="t-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {shown.title}
      </h1>
      {shown.lines.map((l, n) => (
        <p key={n}>
          {l.strong && <strong>{l.strong}</strong>}
          {l.text}
          {l.term && (
            <>
              {' '}
              <Explain term={l.term} />
            </>
          )}
        </p>
      ))}
      <div className="welcome__buttons">
        <button type="button" className="btn" onClick={() => (last ? onNext() : onCard(i + 1))}>
          {last ? TEXT.done : TEXT.next}
        </button>
        <button
          type="button"
          className="btn btn--soft"
          onClick={() => (i === 0 ? onBack() : onCard(i - 1))}
        >
          {TEXT.back}
        </button>
      </div>
    </section>
  );
}

function AgreementStep({
  state,
  onBack,
  onSigned,
  onNext,
}: {
  state: OnboardingState;
  onBack: () => void;
  onSigned: () => Promise<void>;
  onNext: () => void;
}) {
  const { view } = useKid();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [justSigned, setJustSigned] = useState(false);
  const signedRef = useRef<HTMLParagraphElement>(null);
  const headingId = useId();
  const signed = !state.needs_signature;

  useEffect(() => {
    if (justSigned) signedRef.current?.focus();
  }, [justSigned]);

  const sign = async () => {
    setBusy(true);
    setError('');
    const { error: e } = await supabase.rpc('sign_agreement', { p_version: state.current_version });
    setBusy(false);
    if (e) {
      setError(e.message);
      return;
    }
    setJustSigned(true);
    await onSigned();
  };

  return (
    <section className="card welcome__card" aria-labelledby={headingId}>
      <AgreementView doc={state.agreement} headingId={headingId} />
      {signed ? (
        <div className="welcome__signed" role="status">
          <p className="welcome__signed-title" tabIndex={-1} ref={signedRef}>
            {state.countersigned ? `✍️ ${TEXT.dadSigned}` : `✍️ ${TEXT.signedTitle}`}
          </p>
          {!state.countersigned && <p>{TEXT.signedBody}</p>}
          <button type="button" className="btn" onClick={onNext}>
            {TEXT.next}
          </button>
        </div>
      ) : (
        <div className="welcome__sign">
          <p className="welcome__sign-line">
            {state.agreement.sign_line} — {state.name}
          </p>
          {error && (
            <p className="ask__error" role="alert">
              {error}
            </p>
          )}
          <div className="welcome__buttons">
            <button
              type="button"
              className="btn btn--gold"
              onClick={() => void sign()}
              disabled={busy || view.viewing}
              aria-describedby={view.viewing ? 'viewing-banner' : undefined}
            >
              {busy ? TEXT.signing : TEXT.signButton}
            </button>
            {!state.done && (
              <button type="button" className="btn btn--soft" onClick={onBack}>
                {TEXT.back}
              </button>
            )}
          </div>
        </div>
      )}
    </section>
  );
}

function DecisionStep({
  state,
  reload,
  onFinished,
}: {
  state: OnboardingState;
  reload: () => Promise<OnboardingState | null>;
  onFinished: () => Promise<void>;
}) {
  const { view } = useKid();
  const navigate = useNavigate();
  const [chosen, setChosen] = useState<string | null>(null);
  const [error, setError] = useState('');
  const ref = useFocus<HTMLHeadingElement>(chosen ?? state.first_deposit_cents);

  // Waiting on Dad (to say yes to her deposit, or to sign): look again now and then.
  const waitingForDeposit =
    state.first_deposit_cents === null && state.pending_deposit_cents !== null;
  const waitingForSignature = state.first_deposit_cents !== null && !state.countersigned;
  const waiting = waitingForDeposit || waitingForSignature;
  useEffect(() => {
    if (!waiting) return;
    const t = window.setInterval(() => void reload(), 15_000);
    return () => window.clearInterval(t);
  }, [waiting, reload]);

  if (state.first_deposit_cents === null)
    return (
      <section className="card welcome__card" aria-labelledby="d-title">
        <h1 id="d-title" className="welcome__title" tabIndex={-1} ref={ref}>
          {TEXT.beforeDepositTitle}
        </h1>
        {waitingForDeposit ? (
          <div className="welcome__signed" role="status">
            <p className="welcome__signed-title">
              {TEXT.waitingForDad(state.pending_deposit_cents ?? 0)}
            </p>
            <p>{TEXT.askedBody}</p>
            <button type="button" className="btn btn--soft" onClick={() => void reload()}>
              {TEXT.checkAgain}
            </button>
          </div>
        ) : (
          <>
            {state.last_answer && (
              <div className="welcome__answer" role="status">
                <p className="welcome__signed-title">
                  {state.last_answer.status === 'declined' ? TEXT.declinedTitle : TEXT.expiredTitle}
                </p>
                {state.last_answer.status === 'declined' && state.last_answer.reason && (
                  <p>{TEXT.declinedReason(state.last_answer.reason)}</p>
                )}
                <p>{TEXT.askAgain}</p>
              </div>
            )}
            <FirstDeposit onAsked={reload} />
          </>
        )}
      </section>
    );

  if (waitingForSignature)
    return (
      <section className="card welcome__card" aria-labelledby="d-title">
        <h1 id="d-title" className="welcome__title" tabIndex={-1} ref={ref}>
          {TEXT.firstIn(state.first_deposit_cents)}
        </h1>
        <div className="welcome__signed" role="status">
          <p>{TEXT.waitingForDadSign}</p>
          <button type="button" className="btn btn--soft" onClick={() => void reload()}>
            {TEXT.checkAgain}
          </button>
        </div>
      </section>
    );

  if (chosen)
    return (
      <section className="card welcome__card welcome__card--done" aria-labelledby="d-done">
        <h1 id="d-done" className="welcome__title" tabIndex={-1} ref={ref}>
          {TEXT.allSet}
        </h1>
        <p>{TEXT.welcomeAboard}</p>
        <Link className="btn btn--gold" to={view.base}>
          {TEXT.goHome}
        </Link>
      </section>
    );

  const { choices, note } = decisionChoices(state);
  const choose = async (key: string) => {
    setError('');
    const { error: e } = await supabase.rpc('finish_onboarding');
    if (e) {
      setError(e.message);
      return;
    }
    await onFinished();
    // A GIC or a fund: straight to Buy / Sell to do it (the app is hers now).
    if (key === 'savings') setChosen(key);
    else navigate(`${view.base}/trade`);
  };
  return (
    <section className="card welcome__card" aria-labelledby="d-title">
      <h1 id="d-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {TEXT.firstIn(state.first_deposit_cents)}
      </h1>
      <p>{TEXT.decisionBody}</p>
      <ul className="welcome__choices">
        {choices.map((c) => (
          <li key={c.key}>
            <button
              type="button"
              className="welcome__choice"
              onClick={() => void choose(c.key)}
              disabled={view.viewing}
              aria-describedby={view.viewing ? 'viewing-banner' : undefined}
            >
              <strong>{c.title}</strong> {c.text}
            </button>
          </li>
        ))}
      </ul>
      <p className="muted">{note}</p>
      {error && (
        <p className="ask__error" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}

/** Her first deposit, asked for right here (the rest of the app is locked until she's done). */
function FirstDeposit({ onAsked }: { onAsked: () => Promise<OnboardingState | null> }) {
  const { view } = useKid();
  const id = useId();
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const amount = parseAmount(text);

  const ask = async () => {
    if (amount.state !== 'ok') {
      setError(amount.state === 'bad' ? amount.message : TEXT.depositEmpty);
      return;
    }
    setBusy(true);
    setError('');
    const { error: e } = await supabase.rpc('request_deposit', {
      p_amount_cents: amount.cents.toString(),
    });
    setBusy(false);
    if (e) {
      setError(e.message);
      return;
    }
    await onAsked();
  };

  return (
    <div className="welcome__deposit">
      <p>{TEXT.beforeDeposit}</p>
      <label htmlFor={`${id}-amt`}>{TEXT.depositLabel}</label>
      <input
        id={`${id}-amt`}
        className="welcome__amount"
        inputMode="decimal"
        autoComplete="off"
        value={text}
        disabled={view.viewing}
        aria-describedby={error ? `${id}-err` : undefined}
        onChange={(e) => {
          setText(e.target.value);
          setError('');
        }}
      />
      {amount.state === 'ok' && (
        <p className="muted">{TEXT.depositConfirm(Number(amount.cents))}</p>
      )}
      {error && (
        <p id={`${id}-err`} className="ask__error" role="alert">
          {error}
        </p>
      )}
      <button
        type="button"
        className="btn btn--gold"
        onClick={() => void ask()}
        disabled={busy || view.viewing}
        aria-describedby={view.viewing ? 'viewing-banner' : undefined}
      >
        {busy ? TEXT.asking : TEXT.askDad}
      </button>
    </div>
  );
}

/** Focus a step's heading when it appears, for keyboards and screen readers. */
function useFocus<T extends HTMLElement>(key?: unknown) {
  const ref = useRef<T>(null);
  useEffect(() => {
    ref.current?.focus();
  }, [key]);
  return ref;
}
