// Onboarding, together with Dad (SPEC "Onboarding"; wording in MESSAGES §11):
//   welcome     what we'll do together, and one button: Let's get started
//   tour        a quick look around (required; Back and Next)
//   personalise "Make it yours": her colour and animal (only when it's on for her; stage 10)
//   wish        her first wish (only when the Wish List is on for her; she may skip it)
//   agreement   the house rules, which she signs; Dad countersigns on his phone
//   decision    her first deposit (asked for right here; if Dad says no, she sees
//               why and asks again), then what her money does
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
import { StarPicker } from '../wishlist/StarPicker';
import { TEXT as WISH } from '../wishlist/wishText';
import { LookPicker } from '../look/MakeItYours';
import { TEXT as LOOK } from '../look/lookText';
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
import '../trade/Trade.css';
import '../wishlist/WishList.css';
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
  const lastTourCard = tourCards(state.rules, state.steps.includes('wish')).length - 1;
  // Back: the step before, or the tour's last card.
  const back = (s: Step) => {
    const p = steps[steps.indexOf(s) - 1] ?? 'welcome';
    return p === 'tour' ? go('tour', lastTourCard) : go(p);
  };

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
      {place.step === 'personalise' && (
        <PersonaliseStep
          onBack={() => back('personalise')}
          onNext={() => go(after('personalise'))}
        />
      )}
      {place.step === 'wish' && (
        <WishStep state={state} onBack={() => back('wish')} onNext={() => go(after('wish'))} />
      )}
      {place.step === 'agreement' && (
        <AgreementStep
          state={state}
          onBack={() => back('agreement')}
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

/** Step 2, "Make it yours" (stage 10): the same picker as Home's, saved as she goes on. */
function PersonaliseStep({ onBack, onNext }: { onBack: () => void; onNext: () => void }) {
  const { view } = useKid();
  const ref = useFocus<HTMLHeadingElement>();
  return (
    <section className="card welcome__card" aria-labelledby="p-title">
      <h1 id="p-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {LOOK.lookTitle}
      </h1>
      <LookPicker onSaved={onNext} />
      <div className="welcome__buttons">
        <button type="button" className="btn btn--soft" onClick={onBack}>
          {TEXT.back}
        </button>
        {view.viewing && (
          <button type="button" className="btn" onClick={onNext}>
            {TEXT.next}
          </button>
        )}
      </div>
    </section>
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

// Step 3 (MESSAGES §11): her first wish. Name, rough price (she may skip it) and stars;
// the rest (a link, a photo) waits for her Wish List. She can skip the whole step.
function WishStep({
  state,
  onBack,
  onNext,
}: {
  state: OnboardingState;
  onBack: () => void;
  onNext: () => void;
}) {
  const { view } = useKid();
  const ref = useFocus<HTMLHeadingElement>();
  const [name, setName] = useState('');
  const [price, setPrice] = useState('');
  const [stars, setStars] = useState(3);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [added, setAdded] = useState(false);
  const ids = { name: useId(), price: useId() };

  const add = async () => {
    const amount = parseAmount(price);
    if (amount.state === 'bad') return setError(amount.message);
    setBusy(true);
    setError('');
    const { error: e } = await supabase.rpc('wish_add', {
      p_name: name,
      p_price_cents: amount.state === 'ok' ? amount.cents.toString() : null,
      p_link: null,
      p_stars: stars,
    });
    setBusy(false);
    if (e) return setError(e.message);
    setAdded(true);
  };

  return (
    <section className="card welcome__card" aria-labelledby="wish-title">
      <h1 id="wish-title" className="welcome__title" tabIndex={-1} ref={ref}>
        {WISH.addTitle}
      </h1>
      {added ? (
        <p role="status">{WISH.added(state.rules.goal_wait_days ?? '7')}</p>
      ) : (
        <>
          <div className="field">
            <label className="field__label" htmlFor={ids.name}>
              {WISH.name}
            </label>
            <input
              id={ids.name}
              className="wish-form__input"
              value={name}
              maxLength={60}
              disabled={view.viewing}
              onChange={(e) => setName(e.target.value)}
              autoComplete="off"
            />
          </div>
          <div className="field">
            <label className="field__label" htmlFor={ids.price}>
              {WISH.price}
            </label>
            <span className="field__money">
              <span aria-hidden="true">$</span>
              <input
                id={ids.price}
                className="field__input"
                inputMode="decimal"
                value={price}
                disabled={view.viewing}
                onChange={(e) => setPrice(e.target.value)}
                autoComplete="off"
              />
            </span>
          </div>
          <StarPicker value={stars} onChange={view.viewing ? () => undefined : setStars} />
        </>
      )}
      <p className="muted">{WISH.seeLine}</p>
      {error && (
        <p className="wish__problem" role="alert">
          {error}
        </p>
      )}
      <div className="welcome__buttons">
        {added || view.viewing ? (
          <button type="button" className="btn" onClick={onNext}>
            {TEXT.next}
          </button>
        ) : (
          <>
            <button
              type="button"
              className="btn btn--gold"
              disabled={busy}
              onClick={() => void add()}
            >
              {WISH.addIt}
            </button>
            <button type="button" className="btn btn--soft" onClick={onNext}>
              {WISH.skip}
            </button>
          </>
        )}
        <button type="button" className="btn btn--soft" onClick={onBack}>
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
