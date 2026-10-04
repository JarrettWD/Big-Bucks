// Settings (stage 8 B1: how long Dad has to answer a request; B2 adds the rest).
// Every change shows a summary and exactly what the girls will be told
// (parent_change_preview: the real action, rolled back), then one button that does
// it. The database checks the rules again and logs who did it and when.

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { TEXT, parseDays, type ChangePreview, type SettingsData } from './settingsText';
import './Settings.css';

async function fetchSettings(): Promise<{ data: SettingsData | null; error: string | null }> {
  const { data, error } = await supabase.rpc('parent_settings');
  return error ? { data: null, error: error.message } : { data: data as SettingsData, error: null };
}

export default function Settings() {
  const [data, setData] = useState<SettingsData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const doneRef = useRef<HTMLParagraphElement>(null);

  const apply = useCallback((r: { data: SettingsData | null; error: string | null }) => {
    setError(r.error);
    if (r.data) setData(r.data);
    return r.data;
  }, []);

  useEffect(() => {
    let alive = true;
    fetchSettings().then((r) => {
      if (alive) apply(r);
    });
    return () => {
      alive = false;
    };
  }, [apply]);

  useEffect(() => {
    if (done) doneRef.current?.focus();
  }, [done]);

  if (error && !data)
    return (
      <section className="set">
        <p className="set__error" role="alert">
          {TEXT.loadError(error)}
        </p>
        <button
          type="button"
          className="set__btn"
          onClick={async () => apply(await fetchSettings())}
        >
          {TEXT.retry}
        </button>
      </section>
    );
  if (!data) return <p className="set__muted">Loading…</p>;
  const e = data.expiry;

  return (
    <section className="set" aria-labelledby="set-title">
      <h1 id="set-title" className="set__title">
        {TEXT.title}
      </h1>
      {done && (
        <p className="set__done" role="status" tabIndex={-1} ref={doneRef}>
          {done}
        </p>
      )}

      <section className="set__card" aria-labelledby="set-expiry">
        <h2 id="set-expiry">{TEXT.expiryTitle}</h2>
        <p className="set__value">{TEXT.expiryNow(e.days)}</p>
        <p className="set__muted">{TEXT.expiryExplain}</p>
        {e.scheduled.map((s) => (
          <p key={s.from} className="set__scheduled">
            📅 {TEXT.scheduled(s.days, s.from)}
          </p>
        ))}
        {editing ? (
          <ExpiryChange
            data={data}
            onCancel={() => setEditing(false)}
            onDone={async (summary) => {
              setEditing(false);
              const fresh = apply(await fetchSettings());
              const last = fresh?.expiry.history[0];
              setDone(TEXT.done(summary, last?.who ?? '', last?.when ?? ''));
            }}
          />
        ) : (
          <button
            type="button"
            className="set__btn"
            onClick={() => {
              setDone(null);
              setEditing(true);
            }}
          >
            {TEXT.change}
          </button>
        )}
        <details className="set__history">
          <summary>{TEXT.history}</summary>
          <ul>
            {e.history.map((h, i) => (
              <li key={i}>
                <span>{TEXT.historyLine(h)}</span>
                <span className="set__muted">{TEXT.historyWho(h)}</span>
                {h.note && <span className="set__muted">“{h.note}”</span>}
              </li>
            ))}
          </ul>
        </details>
      </section>

      <p className="set__muted">{TEXT.more}</p>
    </section>
  );
}

function ExpiryChange({
  data,
  onCancel,
  onDone,
}: {
  data: SettingsData;
  onCancel: () => void;
  onDone: (summary: string) => Promise<void>;
}) {
  const id = useId();
  const headingRef = useRef<HTMLHeadingElement>(null);
  const e = data.expiry;
  const [daysText, setDaysText] = useState(String(e.days));
  const [starts, setStarts] = useState(data.today);
  const [note, setNote] = useState('');
  const [preview, setPreview] = useState<{ key: string; result: ChangePreview } | null>(null);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const seq = useRef(0);

  const days = parseDays(daysText, e.min, e.max);
  const typo = typeof days === 'string' ? days : null;
  const args = {
    key: 'request_expiry_days',
    value: String(days),
    effective_date: starts,
    note: note.trim() || null,
  };
  const key = JSON.stringify(args);
  const current = preview && preview.key === key ? preview.result : null;

  useEffect(() => {
    headingRef.current?.focus();
  }, []);

  // What the change would do, after Dad pauses typing.
  useEffect(() => {
    const mine = ++seq.current;
    if (typo) return;
    const t = window.setTimeout(async () => {
      const { data: d, error } = await supabase.rpc('parent_change_preview', {
        p_action: 'set_setting',
        p_args: JSON.parse(key),
      });
      if (mine !== seq.current) return;
      setPreview({
        key,
        result: error
          ? { problem: error.message, notices: [], notices_on: null, summary: null }
          : (d as ChangePreview),
      });
    }, 400);
    return () => window.clearTimeout(t);
  }, [key, typo]);

  const go = async () => {
    if (!current?.summary) return;
    setSaving(true);
    setFailed(null);
    const { error } = await supabase.rpc('set_setting', {
      p_key: args.key,
      p_value: args.value,
      p_effective_date: args.effective_date,
      p_note: args.note,
    });
    if (error) {
      setSaving(false);
      setFailed(error.message);
      return;
    }
    await onDone(current.summary);
  };

  const problem = typo ?? failed ?? current?.problem ?? null;
  const blocked = saving || typo !== null || current === null || current.problem !== null;

  return (
    <div className="set__change" role="group" aria-labelledby={`${id}-h`}>
      <h3 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {TEXT.changeHeading}
      </h3>
      <label htmlFor={`${id}-d`}>{TEXT.daysLabel(e.min, e.max)}</label>
      <input
        id={`${id}-d`}
        inputMode="numeric"
        autoComplete="off"
        value={daysText}
        onChange={(ev) => setDaysText(ev.target.value)}
        aria-describedby={`${id}-p`}
      />
      <label htmlFor={`${id}-s`}>{TEXT.startsLabel}</label>
      <input
        id={`${id}-s`}
        type="date"
        min={data.today}
        value={starts}
        onChange={(ev) => setStarts(ev.target.value || data.today)}
      />
      <label htmlFor={`${id}-n`}>{TEXT.noteLabel}</label>
      <input
        id={`${id}-n`}
        value={note}
        maxLength={200}
        onChange={(ev) => setNote(ev.target.value)}
      />

      <div className="set__sees" id={`${id}-p`} aria-live="polite">
        {current?.summary && !problem && (
          <p className="set__record">
            {TEXT.willRecord} <strong>{current.summary}</strong>
          </p>
        )}
        {problem ? (
          <p className="set__error" role="alert">
            {problem}
          </p>
        ) : current === null ? (
          <p className="set__muted">{TEXT.checking}</p>
        ) : current.notices.length === 0 ? (
          <p className="set__muted">{TEXT.noNotice}</p>
        ) : (
          current.notices.map((n) => (
            <div key={n.title}>
              <p className="set__sees-label">{TEXT.theySee(current.notices_on, n.kids)}</p>
              <div className="set__notice">
                <p className="set__notice-title">{n.title}</p>
                <p>{n.body}</p>
              </div>
            </div>
          ))
        )}
      </div>

      <div className="set__actions">
        <button type="button" className="set__btn" disabled={blocked} onClick={() => void go()}>
          {saving ? TEXT.saving : typeof days === 'number' ? TEXT.yes(days) : TEXT.yes(e.days)}
        </button>
        <button
          type="button"
          className="set__btn set__btn--quiet"
          disabled={saving}
          onClick={onCancel}
        >
          {TEXT.back}
        </button>
      </div>
    </div>
  );
}
