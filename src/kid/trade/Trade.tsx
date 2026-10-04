// Buy / Sell. She picks Buy or Sell, then From and To (every move goes through
// savings), types an amount, and sees what's free to use and the spec's warnings
// as she goes. A summary comes before "Yes, do it"; deposits and withdrawals go
// to Dad, everything else happens on its own.
//
//   trade_options(account)   what she has, before she types
//   move_preview(...)        the real rules, run and rolled back, after she pauses typing
//   the real action          request_deposit, request_withdrawal, buy_gic, break_gic, request_trade
//
// Every amount, date and rule comes from the database. Wording: docs/MESSAGES.md §8.

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Explain } from '../../components/Glossary';
import { formatDate, formatRate, termLabel, termWords } from '../../lib/format';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import {
  dropdownPlaces,
  fromPlaces,
  isGicPlace,
  keepOrFirst,
  moveFor,
  parseAmount,
  toPlaces,
  type Holdings,
  type Move,
  type Place,
  type Side,
} from './moves';
import {
  amountHelp,
  doneText,
  isCaution,
  placeBlocked,
  placeLabel,
  sellsAll,
  summaryFor,
  waitingLine,
  warningText,
  type Preview,
  type TradeOptions,
} from './tradeText';
import '../home/Home.css';
import '../GicChoice.css';
import './Trade.css';

/** How long she must pause typing before the amount is checked. */
export const PREVIEW_DELAY_MS = 500;

type Step = 'form' | 'confirm' | 'done';

export default function Trade() {
  const { view, summary } = useKid();
  const accountId = view.accountId;
  const [opts, setOpts] = useState<TradeOptions | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [tick, setTick] = useState(0);

  const [side, setSide] = useState<Side>('buy');
  // What she picked; the screen uses the nearest allowed choice (below).
  const [pickedFrom, setFrom] = useState<Place | null>(null);
  const [pickedTo, setTo] = useState<Place | null>(null);
  const [amountText, setAmountText] = useState('');
  const [sellAll, setSellAll] = useState(false);
  const [term, setTerm] = useState<number | null>(null);
  const [step, setStep] = useState<Step>('form');
  const [busy, setBusy] = useState(false);
  const [submitError, setSubmitError] = useState('');
  const [done, setDone] = useState<{ title: string; text: string } | null>(null);

  // What she has ------------------------------------------------------------------------------
  useEffect(() => {
    if (!accountId) return;
    let alive = true;
    supabase.rpc('trade_options', { p_account_id: accountId }).then(({ data, error }) => {
      if (!alive) return;
      if (error || !data) setLoadError(true);
      else {
        setLoadError(false);
        setOpts(data as TradeOptions);
      }
    });
    return () => {
      alive = false;
    };
  }, [accountId, tick]);

  const holdings: Holdings = useMemo(
    () => ({
      fundIds: opts?.funds.map((f) => f.fund_id) ?? [],
      sellableFundIds:
        opts?.funds.filter((f) => Number(f.available_units) > 0).map((f) => f.fund_id) ?? [],
      gicIds: opts?.gics.map((g) => g.gic_id) ?? [],
    }),
    [opts],
  );
  // Her picks while they're allowed; otherwise the first allowed choice (after
  // switching Buy / Sell, or when a GIC she picked is gone).
  const fromList = opts ? fromPlaces(side, holdings) : [];
  const from = keepOrFirst(pickedFrom, fromList);
  const toList = from ? toPlaces(side, from, holdings) : [];
  const to = keepOrFirst(pickedTo, toList);

  const move: Move | null = from && to ? moveFor(side, from, to) : null;
  const fund = move?.fundId ? opts?.funds.find((f) => f.fund_id === move.fundId) : undefined;
  const gic = move?.gicId ? opts?.gics.find((g) => g.gic_id === move.gicId) : undefined;
  const blocked =
    (from && opts ? placeBlocked(from, opts) : null) ??
    (to && opts ? placeBlocked(to, opts) : null);
  const needsAmount =
    move !== null && move.kind !== 'break_gic' && !(move.kind === 'sell_fund' && sellAll);
  const parsed = parseAmount(amountText);
  const cents = needsAmount && parsed.state === 'ok' ? parsed.cents : null;
  const amount = cents !== null ? formatCents(cents) : null;

  // The check, after she pauses typing --------------------------------------------------------
  const [preview, setPreview] = useState<{ key: string; result: Preview } | null>(null);
  const [previewError, setPreviewError] = useState(false);
  const previewKey =
    move && !blocked && (!needsAmount || cents !== null)
      ? JSON.stringify([move.kind, move.fundId, move.gicId, cents?.toString() ?? null, sellAll])
      : null;
  const lastAmount = useRef(amountText);

  useEffect(() => {
    // Only typing waits for a pause; picking a choice is checked right away.
    const typed = lastAmount.current !== amountText;
    lastAmount.current = amountText;
    if (!previewKey || !move) return;
    let alive = true;
    const timer = setTimeout(
      () => {
        setPreviewError(false);
        supabase
          .rpc('move_preview', {
            p_kind: move.kind,
            p_amount_cents: needsAmount && cents !== null ? Number(cents) : null,
            p_fund_id: move.fundId,
            p_gic_id: move.gicId,
            p_term: null,
            p_sell_all: move.kind === 'sell_fund' && sellAll,
          })
          .then(({ data, error }) => {
            if (!alive) return;
            setPreviewError(Boolean(error));
            if (!error) setPreview({ key: previewKey, result: data as Preview });
          });
      },
      typed ? PREVIEW_DELAY_MS : 0,
    );
    return () => {
      alive = false;
      clearTimeout(timer);
    };
    // previewKey captures everything the check depends on.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey]);

  const current = preview && preview.key === previewKey ? preview.result : null;
  const checking = previewKey !== null && current === null && !previewError;
  const quote =
    move?.kind === 'buy_gic' && current
      ? current.gic_quotes.find((q) => q.term_months === term)
      : undefined;
  const ready =
    current !== null &&
    current.problem === null &&
    (move?.kind !== 'buy_gic' || quote !== undefined);

  const reset = useCallback(() => {
    setAmountText('');
    setSellAll(false);
    setTerm(null);
    setPreview(null);
    setSubmitError('');
    setDone(null);
    setStep('form');
    setTick((t) => t + 1);
  }, []);

  const submit = async () => {
    if (!move || !ready) return;
    setBusy(true);
    setSubmitError('');
    const c = cents !== null ? Number(cents) : null;
    const call = {
      deposit: () => supabase.rpc('request_deposit', { p_amount_cents: c }),
      withdraw: () => supabase.rpc('request_withdrawal', { p_amount_cents: c }),
      buy_gic: () => supabase.rpc('buy_gic', { p_amount_cents: c, p_term_months: term }),
      break_gic: () => supabase.rpc('break_gic', { p_gic_id: move.gicId }),
      buy_fund: () =>
        supabase.rpc('request_trade', {
          p_fund_id: move.fundId,
          p_side: 'buy',
          p_amount_cents: c,
          p_sell_all: false,
        }),
      sell_fund: () =>
        supabase.rpc('request_trade', {
          p_fund_id: move.fundId,
          p_side: 'sell',
          p_amount_cents: sellAll ? null : c,
          p_sell_all: sellAll,
        }),
    }[move.kind];
    const { error } = await call();
    setBusy(false);
    if (error) {
      setSubmitError(error.message);
      return;
    }
    // Worded now: reloading her holdings below can remove the GIC or change the choices.
    const year = Number(opts!.today.slice(0, 4));
    setDone(doneText({ kind: move.kind, amount, fund, gic, quote, preview: current!, year }));
    setStep('done');
    summary.reload();
    setTick((t) => t + 1);
  };

  // Screen ---------------------------------------------------------------------------------------
  if (loadError)
    return (
      <div className="trade trade--single">
        <section className="card">
          <p className="muted">
            Big Bucks couldn't load your money just now. Please try again in a minute.
          </p>
          <button type="button" className="btn" onClick={() => setTick((t) => t + 1)}>
            Try again
          </button>
        </section>
      </div>
    );
  if (!opts) return <div className="trade" aria-busy="true" aria-label="Loading" />;

  if (opts.updating)
    return (
      <div className="trade trade--single">
        <section className="card" aria-labelledby="trade-title">
          <h1 id="trade-title" className="trade__title">
            Buy / Sell
          </h1>
          <p className="trade__updating">
            <strong>Updating…</strong> Your numbers are being double-checked. They'll be back soon.
          </p>
          <p className="muted">You can make moves again once they're back.</p>
        </section>
      </div>
    );

  const year = Number(opts.today.slice(0, 4));
  const ctx = {
    kind: move?.kind ?? 'deposit',
    year,
    sellAll: sellAll || sellsAll(current),
    amount,
    fundName: fund?.name ?? 'fund',
  } as const;

  return (
    <div className="trade">
      <section className="card trade__main" aria-labelledby="trade-title">
        {step === 'form' && (
          <TradeForm
            opts={opts}
            side={side}
            setSide={(s) => {
              setSide(s);
              // Each side starts at its own first choices.
              setFrom(null);
              setTo(null);
              setSellAll(false);
              setTerm(null);
            }}
            from={from}
            setFrom={setFrom}
            to={to}
            setTo={setTo}
            fromList={fromList}
            toList={toList}
            move={move}
            blocked={blocked}
            needsAmount={needsAmount}
            amountText={amountText}
            setAmountText={setAmountText}
            amountMessage={parsed.state === 'bad' && needsAmount ? parsed.message : null}
            sellAll={sellAll}
            setSellAll={setSellAll}
            term={term}
            setTerm={setTerm}
            preview={current}
            previewError={previewError}
            checking={checking}
            ready={ready}
            onNext={() => setStep('confirm')}
            ctx={ctx}
          />
        )}

        {step === 'confirm' && move && current && (
          <Confirm
            summary={summaryFor({
              kind: move.kind,
              amount,
              sellAll: sellAll || sellsAll(current),
              fund,
              gic,
              quote,
              preview: current,
              year,
            })}
            busy={busy}
            error={submitError}
            onYes={submit}
            onBack={() => {
              setSubmitError('');
              setStep('form');
            }}
          />
        )}

        {step === 'done' && done && <Done {...done} onAnother={reset} />}
      </section>

      <WaitingList opts={opts} />
    </div>
  );
}

// The form ---------------------------------------------------------------------------------------

function TradeForm(p: {
  opts: TradeOptions;
  side: Side;
  setSide: (s: Side) => void;
  from: Place | null;
  setFrom: (p: Place) => void;
  to: Place | null;
  setTo: (p: Place) => void;
  fromList: Place[];
  toList: Place[];
  move: Move | null;
  blocked: string | null;
  needsAmount: boolean;
  amountText: string;
  setAmountText: (s: string) => void;
  amountMessage: string | null;
  sellAll: boolean;
  setSellAll: (b: boolean) => void;
  term: number | null;
  setTerm: (t: number) => void;
  preview: Preview | null;
  previewError: boolean;
  checking: boolean;
  ready: boolean;
  onNext: () => void;
  ctx: {
    kind: Move['kind'];
    year: number;
    sellAll: boolean;
    amount: string | null;
    fundName: string;
  };
}) {
  const id = useId();
  const { opts, move } = p;
  const fund = move?.fundId ? opts.funds.find((f) => f.fund_id === move.fundId) : undefined;
  const gic = move?.gicId ? opts.gics.find((g) => g.gic_id === move.gicId) : undefined;
  const helpId = `${id}-help`;
  const msgId = `${id}-msg`;

  return (
    <div className="trade__form">
      <h1 id="trade-title" className="trade__title">
        Buy / Sell
      </h1>

      <div className="trade__side" role="group" aria-label="Buy or sell">
        {(['buy', 'sell'] as const).map((s) => (
          <button
            key={s}
            type="button"
            className="trade__side-btn"
            aria-pressed={p.side === s}
            onClick={() => p.setSide(s)}
          >
            {s === 'buy' ? 'Buy' : 'Sell'}
          </button>
        ))}
      </div>
      <p className="muted">
        {p.side === 'buy'
          ? 'Put money into savings, a GIC or a fund.'
          : 'Take money out of a GIC, a fund or savings.'}
      </p>

      <div className="trade__pair">
        <div className="field">
          <label className="field__label" htmlFor={`${id}-from`}>
            From
          </label>
          <select
            id={`${id}-from`}
            className="field__select"
            value={p.from ?? ''}
            onChange={(e) => p.setFrom(e.target.value as Place)}
          >
            {dropdownPlaces(p.fromList, p.from).map((pl) => {
              const why = isGicPlace(pl) ? null : placeBlocked(pl, opts);
              return (
                <option key={pl} value={pl}>
                  {placeLabel(pl, opts, 'from')}
                  {why ? ` (${why})` : ''}
                </option>
              );
            })}
          </select>
        </div>
        <span className="trade__arrow" aria-hidden="true">
          ➜
        </span>
        <div className="field">
          <label className="field__label" htmlFor={`${id}-to`}>
            To
          </label>
          <select
            id={`${id}-to`}
            className="field__select"
            value={p.to ?? ''}
            onChange={(e) => p.setTo(e.target.value as Place)}
          >
            {p.toList.map((pl) => {
              const why = placeBlocked(pl, opts);
              return (
                <option key={pl} value={pl}>
                  {placeLabel(pl, opts, 'to')}
                  {why ? ` (${why})` : ''}
                </option>
              );
            })}
          </select>
        </div>
      </div>
      {p.side === 'sell' && p.fromList.length === 1 && (
        <p className="muted">You don't have any GICs or funds to sell right now.</p>
      )}

      {p.blocked === 'traded today, again tomorrow' && (
        <p className="trade__note" role="status">
          You've already traded the {fund?.name} fund today. You can trade it again tomorrow. One
          trade per fund each day helps you think it through.
        </p>
      )}
      {p.blocked === 'ready today' && (
        <p className="trade__note" role="status">
          This GIC is ready today, so you won't lose any interest. It will be ready to choose soon.
        </p>
      )}

      {move?.kind === 'break_gic' && (
        <fieldset className="options">
          <legend>Which GIC?</legend>
          <div className="gic-cards">
            {opts.gics.map((g) => (
              <label key={g.gic_id} className="gic-card">
                <input
                  type="radio"
                  name={`${id}-gic`}
                  className="gic-card__radio"
                  checked={g.gic_id === gic?.gic_id}
                  onChange={() => p.setFrom(`gic:${g.gic_id}`)}
                />
                <span className="gic-card__amount">{formatCents(g.balance_cents)}</span>{' '}
                <span>
                  {termLabel(g.term_months)} GIC at {formatRate(g.rate)}
                </span>{' '}
                <span className="gic-card__ready">
                  {g.can_break ? `Ready ${formatDate(g.maturity_date, p.ctx.year)}` : 'Ready today'}
                </span>
              </label>
            ))}
          </div>
          <p className="muted">
            A GIC comes out all at once. <Explain term="Breaking a GIC early" />
          </p>
        </fieldset>
      )}

      {move && move.kind !== 'break_gic' && !p.blocked && (
        <div className="trade__amount">
          <div className="field">
            <label className="field__label" htmlFor={`${id}-amount`}>
              How much?
            </label>
            <span className="field__money">
              <span aria-hidden="true">$</span>
              <input
                id={`${id}-amount`}
                className="field__input"
                type="text"
                inputMode="decimal"
                autoComplete="off"
                placeholder={p.needsAmount ? '0.00' : 'All of it'}
                value={p.needsAmount ? p.amountText : ''}
                disabled={!p.needsAmount}
                aria-invalid={p.amountMessage !== null}
                aria-describedby={`${helpId} ${msgId}`}
                onChange={(e) => p.setAmountText(e.target.value)}
              />
            </span>
          </div>
          <p id={helpId} className="trade__help">
            {amountHelp(move.kind, opts, fund)}{' '}
            <Explain
              term={
                move.kind === 'deposit'
                  ? 'Deposit cap'
                  : move.kind === 'sell_fund'
                    ? 'Unit price'
                    : 'Available'
              }
            />
          </p>
          {move.kind === 'sell_fund' && (
            <label className="trade__all">
              <input
                type="checkbox"
                checked={p.sellAll}
                onChange={(e) => p.setSellAll(e.target.checked)}
              />
              <span>Sell all of it</span>
            </label>
          )}
          <p id={msgId} className="trade__problem" aria-live="polite">
            {p.amountMessage}
          </p>
        </div>
      )}

      {/* Right under the amount, so a problem shows next to what she typed. */}
      <div aria-live="polite" className="trade__check">
        {p.checking && <p className="muted">Checking…</p>}
        {p.previewError && (
          <p className="trade__problem">
            Big Bucks couldn't check that just now. Please try again.
          </p>
        )}
        {p.preview?.problem && <p className="trade__problem">{p.preview.problem}</p>}
        {p.preview && !p.preview.problem && p.preview.warnings.length > 0 && (
          <ul className="trade__warnings">
            {p.preview.warnings.map((w) => (
              <li key={w.code} className={isCaution(w) ? 'is-caution' : ''}>
                <span aria-hidden="true">{isCaution(w) ? '⚠️' : '💡'}</span>
                <span>
                  {warningText(w, p.ctx)}
                  {w.code === 'market_price' && (
                    <>
                      {' '}
                      <Explain term="Market close" />
                    </>
                  )}
                  {w.code === 'fund_below_cost' && (
                    <>
                      {' '}
                      <Explain term="Loss" />
                    </>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {move?.kind === 'buy_gic' && !p.blocked && (
        <fieldset className="options">
          <legend>
            How long? <Explain term="Term" />
          </legend>
          <div className="terms">
            {opts.gic_rates.map((r) => {
              const q = p.preview?.gic_quotes.find((x) => x.term_months === r.term_months);
              return (
                <button
                  key={r.term_months}
                  type="button"
                  className="term"
                  aria-pressed={p.term === r.term_months}
                  onClick={() => p.setTerm(r.term_months)}
                >
                  <span className="term__len">{termWords(r.term_months)}</span>
                  <span className="term__rate">{formatRate(r.rate)}</span>
                  {q && <span className="term__earns">earns {formatCents(q.interest_cents)}</span>}
                  {r.is_special && <span className="term__special">Special!</span>}
                </button>
              );
            })}
          </div>
        </fieldset>
      )}

      <button type="button" className="btn trade__next" disabled={!p.ready} onClick={p.onNext}>
        {move?.kind === 'buy_gic' && p.preview && !p.preview.problem && p.term === null
          ? 'Pick how long first'
          : 'Next'}
      </button>
    </div>
  );
}

function Confirm(p: {
  summary: { question: string; points: string[] };
  busy: boolean;
  error: string;
  onYes: () => void;
  onBack: () => void;
}) {
  return (
    <div className="confirm">
      <h1 id="trade-title" className="confirm__q">
        {p.summary.question}
      </h1>
      <ul>
        {p.summary.points.map((x) => (
          <li key={x}>{x}</li>
        ))}
      </ul>
      {p.error && (
        <p className="choice__error" role="alert">
          {p.error}
        </p>
      )}
      <div className="confirm__buttons">
        <button type="button" className="btn" onClick={p.onYes} disabled={p.busy}>
          {p.busy ? 'Working…' : 'Yes, do it'}
        </button>
        <button type="button" className="btn btn--soft" onClick={p.onBack} disabled={p.busy}>
          Go back
        </button>
      </div>
    </div>
  );
}

function Done(p: { title: string; text: string; onAnother: () => void }) {
  return (
    <div className="done" role="status">
      <h1 id="trade-title" className="trade__title">
        {p.title}
      </h1>
      <p className="choice__lead">{p.text}</p>
      <div className="confirm__buttons">
        <Link className="btn" to="/kid">
          Back to Home
        </Link>
        <button type="button" className="btn btn--soft" onClick={p.onAnother}>
          Make another move
        </button>
      </div>
    </div>
  );
}

function WaitingList({ opts }: { opts: TradeOptions }) {
  const year = Number(opts.today.slice(0, 4));
  return (
    <section className="card trade__waiting" aria-labelledby="waiting-title">
      <h2 id="waiting-title" className="card__title">
        Waiting
      </h2>
      {opts.waiting.length === 0 ? (
        <p className="muted">Nothing waiting right now.</p>
      ) : (
        <ul className="waiting">
          {opts.waiting.map((w) => {
            const line = waitingLine(w, opts.funds);
            return (
              <li key={w.request_id}>
                <span aria-hidden="true">⏳</span>
                <span className="waiting__text">
                  <span className="waiting__title">{line.title}</span>
                  <span className="waiting__detail">
                    {line.detail} · asked {formatDate(w.on_day, year)}
                  </span>
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
