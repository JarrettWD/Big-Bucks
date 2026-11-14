// Fix a close (the price fix, 2026-11): Dad picks a fund and day, sees the stored close, types the
// official one and where it comes from, sees every trade and dividend that used it with its
// adjustment (always in her favour, or no change), then says yes. The database does it all:
// close_fix_preview only reads; correct_fund_price fixes, logs and tells each girl in one go.
// Opened from the Dashboard (a price alert, or the link under alerts); ?fund=&date= fill it in.

import { useEffect, useId, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import {
  FUNDS,
  TEXT,
  adjustmentLine,
  cleanClose,
  closeLooksOk,
  type ClosePreview,
} from './fixCloseText';
import '../settings/Settings.css';
import './Fix.css';

export default function FixClose() {
  const [search] = useSearchParams();
  const id = useId();
  const [fund, setFund] = useState(search.get('fund') ?? '');
  const [day, setDay] = useState(search.get('date') ?? '');
  const [close, setClose] = useState('');
  const [source, setSource] = useState('');
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const doneRef = useRef<HTMLParagraphElement>(null);

  const closeOk = closeLooksOk(close);
  const args = JSON.stringify({
    p_fund_id: fund,
    p_date: day,
    p_close: closeOk ? cleanClose(close) : null,
    version,
  });
  const [preview, setPreview] = useState<{
    key: string;
    data: ClosePreview | null;
    problem: string | null;
  } | null>(null);
  const seq = useRef(0);

  useEffect(() => {
    const a = JSON.parse(args) as { p_fund_id: string; p_date: string; p_close: string | null };
    if (a.p_fund_id === '' || a.p_date === '') return;
    const mine = ++seq.current;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc('close_fix_preview', {
        p_fund_id: a.p_fund_id,
        p_date: a.p_date,
        p_close: a.p_close,
      });
      if (mine !== seq.current) return;
      setPreview({
        key: args,
        data: error ? null : (data as ClosePreview),
        problem: error ? error.message : null,
      });
    }, 400);
    return () => window.clearTimeout(t);
  }, [args]);

  useEffect(() => {
    if (done) doneRef.current?.focus();
  }, [done]);

  const chosen = fund !== '' && day !== '';
  const current = chosen && preview?.key === args ? preview : null;
  const p = current?.data ?? null;
  const typed = closeOk && source.trim() !== '';
  const same = p !== null && p.new_close_words !== null && p.new_close_words === p.old_close_words;
  const ready = typed && p !== null && current?.problem === null && !same;
  const problem = failed ?? current?.problem ?? null;

  const save = async () => {
    if (!p) return;
    setSaving(true);
    setFailed(null);
    const { error } = await supabase.rpc('correct_fund_price', {
      p_fund_id: fund,
      p_date: day,
      p_close: cleanClose(close),
      p_note: source,
    });
    setSaving(false);
    if (error) {
      setFailed(error.message);
      return;
    }
    setDone(TEXT.done(p.fund_name, p.day_words, p.new_close_words ?? cleanClose(close)));
    setClose('');
    setSource('');
    setVersion((v) => v + 1);
  };

  const reset = () => {
    setFailed(null);
    setDone(null);
  };

  return (
    <div className="set fix">
      <h1 className="set__title">{TEXT.title}</h1>
      <p className="set__muted">{TEXT.intro}</p>

      {done && (
        <p className="set__done" role="status" tabIndex={-1} ref={doneRef}>
          {done}
        </p>
      )}

      <section className="set__card" aria-labelledby={`${id}-which`}>
        <h2 id={`${id}-which`}>Which close</h2>
        <div className="set__change">
          <label htmlFor={`${id}-fund`}>{TEXT.fund}</label>
          <select
            id={`${id}-fund`}
            value={fund}
            disabled={saving}
            onChange={(e) => {
              setFund(e.target.value);
              reset();
            }}
          >
            <option value="">Choose a fund</option>
            {FUNDS.map((f) => (
              <option key={f.id} value={f.id}>
                {f.name}
              </option>
            ))}
          </select>
          <label htmlFor={`${id}-day`}>{TEXT.day}</label>
          <input
            id={`${id}-day`}
            type="date"
            value={day}
            disabled={saving}
            onChange={(e) => {
              setDay(e.target.value);
              reset();
            }}
          />
          <div aria-live="polite">
            {!chosen ? (
              <p className="set__muted">{TEXT.waiting}</p>
            ) : current === null ? (
              <p className="set__muted">{TEXT.checking}</p>
            ) : p ? (
              <p className="set__facts">{TEXT.stored(p)}</p>
            ) : null}
          </div>
        </div>
      </section>

      {p && (
        <section className="set__card" aria-labelledby={`${id}-fix`}>
          <h2 id={`${id}-fix`}>{TEXT.rightClose}</h2>
          <div className="set__change">
            <label htmlFor={`${id}-close`}>{TEXT.official}</label>
            <input
              id={`${id}-close`}
              inputMode="decimal"
              autoComplete="off"
              value={close}
              disabled={saving}
              aria-describedby={`${id}-close-help`}
              onChange={(e) => {
                setClose(e.target.value);
                reset();
              }}
            />
            <p id={`${id}-close-help`} className="set__muted">
              {close.trim() !== '' && !closeOk ? TEXT.officialBad : TEXT.officialHelp}
            </p>
            <label htmlFor={`${id}-source`}>{TEXT.source}</label>
            <input
              id={`${id}-source`}
              autoComplete="off"
              maxLength={200}
              value={source}
              disabled={saving}
              aria-describedby={`${id}-source-help`}
              onChange={(e) => {
                setSource(e.target.value);
                reset();
              }}
            />
            <p id={`${id}-source-help`} className="set__muted">
              {TEXT.sourceHelp}
            </p>
          </div>
        </section>
      )}

      {chosen && (
        <section className="set__card" aria-labelledby={`${id}-changes`}>
          <h2 id={`${id}-changes`}>{TEXT.changes}</h2>
          <div className="set__sees" aria-live="polite">
            {problem ? (
              <p className="set__error" role="alert">
                {problem}
              </p>
            ) : !typed ? (
              <p className="set__muted">{TEXT.typeClose}</p>
            ) : p === null ? (
              <p className="set__muted">{TEXT.checking}</p>
            ) : same ? (
              <p className="set__muted">{TEXT.same}</p>
            ) : (
              <>
                <p className="set__facts">
                  {p.fund_name}, {p.day_words}: {p.old_close_words} → {p.new_close_words}
                </p>
                {p.adjustments.length === 0 ? (
                  <p className="set__muted">{TEXT.nothingUsed}</p>
                ) : (
                  <ul className="fix__adjustments">
                    {p.adjustments.map((a, i) => (
                      <li key={i}>{adjustmentLine(a)}</li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </div>
          <div className="set__actions">
            <button
              type="button"
              className="set__btn"
              disabled={!ready || saving}
              onClick={() => void save()}
            >
              {saving ? TEXT.saving : TEXT.yes}
            </button>
          </div>
        </section>
      )}

      <p>
        <Link to="/parent">{TEXT.back}</Link>
      </p>
    </div>
  );
}
