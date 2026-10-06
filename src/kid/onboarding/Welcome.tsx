// Onboarding, together with Dad (SPEC "Onboarding"; wording in MESSAGES §11):
//   welcome     what we'll do together
//   tour        a quick look around (she can skip it)
//   agreement   the house rules, which she signs; Dad countersigns on his phone
//   decision    once her first deposit is in: what should her money do?
// "Make it yours" and "your first wish" join when their features are built.
// She can leave any time and look around; Home offers to pick up where she was.
// In Dad's "View as", every step shows but nothing can be signed or chosen.

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Explain } from '../../components/Glossary';
import { supabase } from '../../lib/supabase';
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
  const { view, summary } = useKid();
  const [search] = useSearchParams();
  const [state, setState] = useState<OnboardingState | null>(null);
  const [failed, setFailed] = useState(false);
  const [step, setStep] = useState<Step | null>(null);
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
    return data;
  }, [view]);

  useEffect(() => {
    let live = true;
    void kidRpc<OnboardingState>(view, 'onboarding_state', { p_account_id: view.accountId }).then(
      ({ data, error }) => {
        if (!live) return;
        if (error || !data) return setFailed(true);
        setState(data);
        const asked = search.get('step') as Step | null;
        setStep(asked && shownSteps(data).includes(asked) ? asked : firstStep(data));
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
  if (!state || !step) return <div className="home" aria-busy="true" />;

  const steps = shownSteps(state);
  const go = (s: Step) => {
    setStep(s);
    window.scrollTo(0, 0);
  };
  const after = (s: Step) => steps[steps.indexOf(s) + 1] ?? 'decision';

  return (
    <div className="home home--single welcome">
      {step === 'welcome' && <WelcomeStep state={state} onNext={() => go(after('welcome'))} />}
      {step === 'tour' && (
        <TourStep state={state} onBack={() => go('welcome')} onNext={() => go(after('tour'))} />
      )}
      {step === 'agreement' && (
        <AgreementStep
          state={state}
          onSigned={async () => {
            await load();
            summary.reload();
          }}
          // A new version signed after onboarding goes back Home; otherwise on to her first decision.
          onNext={() => (state.done ? navigate(view.base) : go(after('agreement')))}
        />
      )}
      {step === 'decision' && <DecisionStep state={state} />}
    </div>
  );
}

function WelcomeStep({ state, onNext }: { state: OnboardingState; onNext: () => void }) {
  const { view } = useKid();
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
          {TEXT.letsGo}
        </button>
        <Link className="btn btn--soft" to={view.base}>
          {TEXT.lookAround}
        </Link>
      </div>
    </section>
  );
}

function TourStep({
  state,
  onBack,
  onNext,
}: {
  state: OnboardingState;
  onBack: () => void;
  onNext: () => void;
}) {
  const cards = tourCards(state.rules, state.steps.includes('wish'));
  const [i, setI] = useState(0);
  const ref = useFocus<HTMLHeadingElement>(i);
  const card = cards[i];
  const last = i === cards.length - 1;
  return (
    <section className="card welcome__card" aria-labelledby="t-title">
      <p className="welcome__count">
        {i + 1} / {cards.length}
      </p>
      <h1 id="t-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {card.title}
      </h1>
      {card.lines.map((l, n) => (
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
        <button type="button" className="btn" onClick={() => (last ? onNext() : setI(i + 1))}>
          {last ? TEXT.done : TEXT.next}
        </button>
        <button
          type="button"
          className="btn btn--soft"
          onClick={() => (i === 0 ? onBack() : setI(i - 1))}
        >
          {TEXT.back}
        </button>
        {!last && (
          <button type="button" className="btn btn--soft" onClick={onNext}>
            {TEXT.skipTour}
          </button>
        )}
      </div>
    </section>
  );
}

function AgreementStep({
  state,
  onSigned,
  onNext,
}: {
  state: OnboardingState;
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
          <button
            type="button"
            className="btn btn--gold"
            onClick={() => void sign()}
            disabled={busy || view.viewing}
            aria-describedby={view.viewing ? 'viewing-banner' : undefined}
          >
            {busy ? TEXT.signing : TEXT.signButton}
          </button>
        </div>
      )}
    </section>
  );
}

function DecisionStep({ state }: { state: OnboardingState }) {
  const { view, summary } = useKid();
  const [chosen, setChosen] = useState<string | null>(null);
  const [error, setError] = useState('');
  const ref = useFocus<HTMLHeadingElement>(chosen);

  if (state.first_deposit_cents === null)
    return (
      <section className="card welcome__card" aria-labelledby="d-title">
        <h1 id="d-title" className="welcome__title" tabIndex={-1} ref={ref}>
          {TEXT.beforeDepositTitle}
        </h1>
        <p>{TEXT.beforeDeposit}</p>
        <div className="welcome__buttons">
          <Link className="btn" to={`${view.base}/trade`}>
            {TEXT.goToTrade}
          </Link>
          <Link className="btn btn--soft" to={view.base}>
            {TEXT.backHome}
          </Link>
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
        <Link
          className="btn btn--gold"
          to={chosen === 'savings' ? view.base : `${view.base}/trade`}
        >
          {chosen === 'savings' ? TEXT.goHome : TEXT.goToTrade}
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
    summary.reload();
    setChosen(key);
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

/** Focus a step's heading when it appears, for keyboards and screen readers. */
function useFocus<T extends HTMLElement>(key?: unknown) {
  const ref = useRef<T>(null);
  useEffect(() => {
    ref.current?.focus();
  }, [key]);
  return ref;
}
