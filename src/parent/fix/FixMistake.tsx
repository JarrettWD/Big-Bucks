// Fix a mistake: Dad adds to or takes from one girl's savings, linked to the
// history line (or question) it fixes. Opened from a line in "View as <kid>"
// (which stays read-only: its link leads here) or from a question on Approvals.
//
// The database does everything: correction_preview runs the real correction with
// in_preview() on and rolls it back, so the screen shows the amount after rounding
// (in her favour), her savings before and after, the log line and her notice. The
// button only works once that preview matches exactly what's typed. Every
// reduction, and any addition over the cap or $100, needs the extra check: a
// second step showing the amount in large type. correct_savings checks it all again.

import { useEffect, useId, useRef, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import {
  TEXT,
  amountLooksOk,
  beforeAfter,
  checkHeading,
  checkWhy,
  checkYes,
  pastLine,
  roundedLine,
  yesLabel,
  type CountsAs,
  type Direction,
  type FixPreview,
  type PastCorrection,
} from './fixText';
import '../settings/Settings.css';
import './Fix.css';

/** A preview that couldn't run at all (the database's message goes in problem). */
const NOTHING: FixPreview = {
  problem: null,
  warning: null,
  limit_cents: null,
  line_left_cents: null,
  counts_as: null,
  needs_retype: false,
  kid: null,
  line: null,
  question: null,
  savings_cents: null,
  held_cents: null,
  free_cents: null,
  check_over_cents: null,
  cents: null,
  typed: null,
  rounded: false,
  needs_check: false,
  savings_after_cents: null,
  free_after_cents: null,
  summary: null,
  notices: [],
};

async function loadPast(
  accountId: string,
): Promise<{ list: PastCorrection[] | null; error: string | null }> {
  const { data, error } = await supabase.rpc('parent_corrections', { p_account_id: accountId });
  return error
    ? { list: null, error: error.message }
    : { list: data as PastCorrection[], error: null };
}

export default function FixMistake() {
  const { accountId = '' } = useParams();
  const [search] = useSearchParams();
  const lineKey = search.get('line');
  const questionId = search.get('question') ? Number(search.get('question')) : null;

  const id = useId();
  const [direction, setDirection] = useState<Direction | ''>('');
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  // Only for a fix with no line (a question about a request): how the graphs count it.
  const [countsAs, setCountsAs] = useState<CountsAs>('earned');
  // An addition over $100: the amount typed a second time.
  const [again, setAgain] = useState('');
  // One key per correction, so a double tap can't post twice (the database refuses it).
  const [key, setKey] = useState(() => crypto.randomUUID());
  const [checking, setChecking] = useState(false);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [past, setPast] = useState<PastCorrection[] | null>(null);
  const [pastError, setPastError] = useState<string | null>(null);
  const checkRef = useRef<HTMLHeadingElement>(null);
  const doneRef = useRef<HTMLParagraphElement>(null);

  const args = {
    account_id: accountId,
    line_key: lineKey,
    question_id: questionId,
    direction: direction || null,
    amount: amountLooksOk(amount) ? amount : null,
    note,
    counts_as: countsAs,
  };
  const argsKey = JSON.stringify(args);
  const [preview, setPreview] = useState<{ key: string; result: FixPreview } | null>(null);
  const seq = useRef(0);

  useEffect(() => {
    const mine = ++seq.current;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc('correction_preview', {
        p_args: JSON.parse(argsKey),
      });
      if (mine !== seq.current) return;
      setPreview({
        key: argsKey,
        result: error ? { ...NOTHING, problem: error.message } : (data as FixPreview),
      });
    }, 400);
    return () => window.clearTimeout(t);
  }, [argsKey]);

  // Her corrections so far; asked again after each one Dad saves.
  const [pastVersion, setPastVersion] = useState(0);
  useEffect(() => {
    let live = true;
    void loadPast(accountId).then((r) => {
      if (!live) return;
      setPast(r.list);
      setPastError(r.error);
    });
    return () => {
      live = false;
    };
  }, [accountId, pastVersion]);

  useEffect(() => {
    if (checking) checkRef.current?.focus();
  }, [checking]);
  useEffect(() => {
    if (done) doneRef.current?.focus();
  }, [done]);

  // The latest context (kid, line, savings) stays shown while a new preview loads.
  const current = preview && preview.key === argsKey ? preview.result : null;
  const ctx = preview?.result ?? null;
  const kid = ctx?.kid ?? 'her';
  const typed = direction !== '' && amountLooksOk(amount) && note.trim() !== '';
  const ready = typed && current !== null && current.problem === null && current.cents !== null;
  const amountBad = amount.trim() !== '' && !amountLooksOk(amount);
  const problem = failed ?? (typed ? (current?.problem ?? null) : null);

  const save = async () => {
    if (!current || current.cents === null) return;
    setSaving(true);
    setFailed(null);
    const { data, error } = await supabase.rpc('correct_savings', {
      p_account_id: accountId,
      p_line_key: lineKey,
      p_question_id: questionId,
      p_direction: direction,
      p_amount: amount,
      p_note: note,
      p_counts_as: countsAs,
      // The extra check: the same amount again (a tap confirms a reduction; an
      // addition over $100 needs it typed a second time).
      p_confirm: current.needs_retype ? again : current.needs_check ? amount : null,
      p_key: key,
    });
    setSaving(false);
    if (error) {
      setFailed(error.message);
      if (!current.needs_retype) setChecking(false);
      return;
    }
    const { list } = await loadPast(accountId);
    const row = list?.find((c) => c.id === Number(data));
    setPastVersion((v) => v + 1);
    setDone(
      row?.summary && row.who && row.when ? TEXT.done(row.summary, row.who, row.when) : 'Done.',
    );
    setChecking(false);
    setDirection('');
    setAmount('');
    setNote('');
    setAgain('');
    setCountsAs('earned');
    setKey(crypto.randomUUID());
  };

  if (ctx?.kid === null && ctx.problem)
    return (
      <div className="set">
        <h1 className="set__title">Fix a mistake</h1>
        <p className="set__error" role="alert">
          {ctx.problem}
        </p>
        <Link to="/parent">Back to the dashboard</Link>
      </div>
    );

  return (
    <div className="set fix">
      <h1 className="set__title">{TEXT.title(kid)}</h1>
      <p className="set__muted">{TEXT.intro}</p>

      {done && (
        <p className="set__done" role="status" tabIndex={-1} ref={doneRef}>
          {done}
        </p>
      )}

      <section className="set__card" aria-labelledby={`${id}-what`}>
        <h2 id={`${id}-what`}>{TEXT.fixing}</h2>
        {ctx === null ? (
          <p className="set__muted">{TEXT.checking}</p>
        ) : (
          <>
            {ctx.line && (
              <p className="fix__line">
                <span className="fix__line-words">{ctx.line.words}</span>
                <span className="fix__line-day"> · {ctx.line.on}</span>
                {ctx.line.amount_cents !== null && (
                  <strong className="fix__line-amount">{formatCents(ctx.line.amount_cents)}</strong>
                )}
              </p>
            )}
            {ctx.question && (
              <>
                <p className="fix__label">
                  {TEXT.question} ({ctx.question.asked_on})
                </p>
                <blockquote className="fix__quote">{ctx.question.message}</blockquote>
                {!ctx.line && <p className="set__muted">{TEXT.questionOnly}</p>}
              </>
            )}
            {ctx.savings_cents !== null && ctx.held_cents !== null && ctx.free_cents !== null && (
              <p className="fix__figures">
                {TEXT.figures(ctx.savings_cents, ctx.held_cents, ctx.free_cents)}
              </p>
            )}
          </>
        )}
      </section>

      {ctx?.kid && (
        <section className="set__card" aria-labelledby={`${id}-form`}>
          <h2 id={`${id}-form`}>{TEXT.theFix}</h2>
          <div className="set__change">
            <fieldset className="set__choices">
              <legend>{TEXT.direction}</legend>
              {(['add', 'take'] as const).map((d) => (
                <label key={d} className="set__choice">
                  <input
                    type="radio"
                    name={`${id}-dir`}
                    value={d}
                    checked={direction === d}
                    disabled={checking || saving}
                    onChange={() => {
                      setDirection(d);
                      setFailed(null);
                      setDone(null);
                    }}
                  />
                  {d === 'add' ? TEXT.add : TEXT.take}
                </label>
              ))}
            </fieldset>
            <label htmlFor={`${id}-amt`}>{TEXT.amount}</label>
            <input
              id={`${id}-amt`}
              inputMode="decimal"
              autoComplete="off"
              value={amount}
              disabled={checking || saving}
              aria-describedby={`${id}-amt-help`}
              onChange={(e) => {
                setAmount(e.target.value);
                setFailed(null);
                setDone(null);
              }}
            />
            <p id={`${id}-amt-help`} className="set__muted">
              {amountBad ? TEXT.amountBad : TEXT.amountHelp}
            </p>
            <label htmlFor={`${id}-note`}>{TEXT.note}</label>
            <textarea
              id={`${id}-note`}
              rows={3}
              maxLength={300}
              value={note}
              disabled={checking || saving}
              aria-describedby={`${id}-note-help`}
              onChange={(e) => {
                setNote(e.target.value);
                setFailed(null);
                setDone(null);
              }}
            />
            <p id={`${id}-note-help`} className="set__muted">
              {TEXT.noteHelp}
            </p>
            {!ctx.line && (
              <fieldset className="set__choices">
                <legend>{TEXT.countsAs}</legend>
                {(['earned', 'money'] as const).map((c) => (
                  <label key={c} className="set__choice">
                    <input
                      type="radio"
                      name={`${id}-counts`}
                      value={c}
                      checked={countsAs === c}
                      disabled={checking || saving}
                      onChange={() => setCountsAs(c)}
                    />
                    {TEXT.countsChoice[c]}
                  </label>
                ))}
              </fieldset>
            )}

            <div className="set__sees" aria-live="polite">
              {!typed ? (
                <p className="set__muted">{TEXT.waiting}</p>
              ) : problem ? (
                <p className="set__error" role="alert">
                  {problem}
                </p>
              ) : current === null ? (
                <p className="set__muted">{TEXT.checking}</p>
              ) : (
                <>
                  {roundedLine(current, kid) && (
                    <p className="set__facts">{roundedLine(current, kid)}</p>
                  )}
                  {beforeAfter(current) && <p className="set__facts">{beforeAfter(current)}</p>}
                  {current.counts_as && (
                    <p className="set__facts">{TEXT.countsLine(current.counts_as)}</p>
                  )}
                  {current.warning && (
                    <p className="fix__warning" role="status">
                      ⚠️ {current.warning}
                    </p>
                  )}
                  {current.summary && (
                    <p className="set__record">
                      {TEXT.willRecord} <strong>{current.summary}</strong>
                    </p>
                  )}
                  {current.notices.map((n) => (
                    <div key={n.title + n.body}>
                      <p className="set__sees-label">{TEXT.sheSees(kid)}</p>
                      <div className="set__notice">
                        <p className="set__notice-title">{n.title}</p>
                        <p>{n.body}</p>
                      </div>
                    </div>
                  ))}
                </>
              )}
            </div>

            {checking && current && current.cents !== null && direction !== '' ? (
              <div className="fix__check" role="group" aria-labelledby={`${id}-check`}>
                <h3 id={`${id}-check`} tabIndex={-1} ref={checkRef}>
                  {checkHeading(direction, kid)}
                </h3>
                <p className={`fix__big fix__big--${direction}`}>
                  {direction === 'add' ? '+' : '−'}
                  {formatCents(Math.abs(current.cents))}
                </p>
                <p>{checkWhy(direction, current.check_over_cents)}</p>
                {current.needs_retype && (
                  <>
                    <label htmlFor={`${id}-again`}>{TEXT.again}</label>
                    <input
                      id={`${id}-again`}
                      inputMode="decimal"
                      autoComplete="off"
                      value={again}
                      disabled={saving}
                      onChange={(e) => {
                        setAgain(e.target.value);
                        setFailed(null);
                      }}
                    />
                  </>
                )}
                {failed && (
                  <p className="set__error" role="alert">
                    {failed}
                  </p>
                )}
                <div className="set__actions">
                  <button
                    type="button"
                    className="set__btn"
                    disabled={!ready || saving || (current.needs_retype && !amountLooksOk(again))}
                    onClick={() => void save()}
                  >
                    {saving ? TEXT.saving : checkYes(direction, current.cents)}
                  </button>
                  <button
                    type="button"
                    className="set__btn set__btn--quiet"
                    disabled={saving}
                    onClick={() => {
                      setChecking(false);
                      setAgain('');
                    }}
                  >
                    {TEXT.back}
                  </button>
                </div>
              </div>
            ) : (
              <div className="set__actions">
                <button
                  type="button"
                  className="set__btn"
                  disabled={!ready || saving}
                  onClick={() =>
                    current?.needs_check || current?.needs_retype ? setChecking(true) : void save()
                  }
                >
                  {saving
                    ? TEXT.saving
                    : yesLabel(
                        direction || 'add',
                        current?.cents ?? null,
                        kid,
                        (current?.needs_check || current?.needs_retype) ?? false,
                      )}
                </button>
              </div>
            )}
          </div>
        </section>
      )}

      <section className="set__card" aria-labelledby={`${id}-past`}>
        <h2 id={`${id}-past`}>{TEXT.pastTitle}</h2>
        {pastError ? (
          <p className="set__error" role="alert">
            {TEXT.loadError(pastError)}
          </p>
        ) : past === null ? (
          <p className="set__muted">{TEXT.checking}</p>
        ) : past.length === 0 ? (
          <p className="set__muted">{TEXT.pastNone}</p>
        ) : (
          <ul className="fix__past">
            {past.map((c) => (
              <li key={c.id}>
                <strong>{pastLine(c)}</strong>
                <span>“{c.note}”</span>
                <span className="set__muted">{TEXT.pastWho(c)}</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <p className="fix__links">
        {questionId !== null && <Link to="/parent/approvals">{TEXT.toApprovals}</Link>}
        <Link to={`/parent/view/${accountId}/history`}>{TEXT.toHistory(kid)}</Link>
      </p>
    </div>
  );
}
