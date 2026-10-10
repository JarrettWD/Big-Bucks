// Settings: rates (with specials), the deposit cap, how long Dad has to answer a
// request, inflation, dividend yields, feature switches, market-move notes, the ?
// explanations, resetting a girl's PIN (Logins), and the Download backup button
// (off until stage 5).
// Every change shows a summary and exactly what the girls will be told
// (parent_change_preview: the real action, rolled back), then one button that does
// it. The database checks the rules again and logs who did it and when.

import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { supabase } from '../../lib/supabase';
import { CancelChange, RateChange, SettingChange, WordingEdit } from './Changes';
import Logins from './Logins';
import {
  FEATURES,
  SWITCH_CHOICES,
  TEXT,
  parseDays,
  parsePercent,
  parseWords,
  type SettingCard,
  type SettingsData,
} from './settingsText';
import { parseAmount } from '../../kid/trade/moves';
import { formatCents } from '../../lib/money';
import './Settings.css';

async function fetchSettings(): Promise<{ data: SettingsData | null; error: string | null }> {
  const { data, error } = await supabase.rpc('parent_settings');
  return error ? { data: null, error: error.message } : { data: data as SettingsData, error: null };
}

/** Dollars typed by Dad → whole cents as text (string arithmetic only). */
function parseCap(text: string) {
  const r = parseAmount(text);
  if (r.state === 'ok') return { value: r.cents.toString() };
  return { error: r.state === 'empty' ? 'Type the new cap, like 1000.' : r.message };
}

export default function Settings() {
  const [data, setData] = useState<SettingsData | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** Which change is open (one at a time), e.g. "rate:gic:12", "cap", "term:GIC". */
  const [open, setOpen] = useState<string | null>(null);
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

  const start = (which: string) => {
    setDone(null);
    setOpen(which);
  };
  const back = () => setOpen(null);
  const finished = async () => {
    setOpen(null);
    const fresh = apply(await fetchSettings());
    const last = fresh?.recent[0];
    if (last) setDone(TEXT.done(last.summary, last.who, last.when));
  };

  /** One planned change: when and what, with Cancel (which opens its confirmation). */
  const scheduledLine = (kind: 'rate' | 'setting', id: number, from: string, words: string) => {
    const which = `cancel:${kind}:${id}`;
    return (
      <div key={which} className="set__planned">
        <div className="set__scheduled">
          <span>📅 {words}</span>
          {open !== which && (
            <button
              type="button"
              className="set__btn set__btn--small set__btn--quiet"
              aria-label={TEXT.cancelLabel(from)}
              onClick={() => start(which)}
            >
              {TEXT.cancelChange}
            </button>
          )}
        </div>
        {open === which && (
          <CancelChange kind={kind} id={id} what={words} onBack={back} onDone={finished} />
        )}
      </div>
    );
  };

  /** A dated setting: its value, what's scheduled, Change, and its history. */
  const settingRow = (
    which: string,
    label: string,
    card: SettingCard,
    change: Omit<Parameters<typeof SettingChange>[0], 'today' | 'onBack' | 'onDone'>,
    opts: { buttonLabel?: string; long?: boolean } = {},
  ) => (
    <div className="set__row" key={which}>
      <div className="set__row-head">
        <span className="set__row-label">{label}</span>
        {!opts.long && <span className="set__row-value">{card.text}</span>}
        {open !== which && <ChangeButton label={opts.buttonLabel} onClick={() => start(which)} />}
      </div>
      {opts.long && <p className="set__words">{card.text}</p>}
      {card.scheduled.map((s) =>
        scheduledLine('setting', s.id, s.from, TEXT.scheduledText(s.text, s.from)),
      )}
      {open === which && (
        <SettingChange {...change} today={data.today} onBack={back} onDone={finished} />
      )}
      <History items={card.history.map((h) => ({ line: TEXT.historyText(h), ...h }))} />
    </div>
  );

  const e = data.expiry;
  const notesShown = data.notes.length;

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

      <nav className="set__jump" aria-label={TEXT.jump}>
        {Object.entries(TEXT.sections).map(([k, label]) => (
          <a key={k} href={`#set-${k}`}>
            {label}
          </a>
        ))}
      </nav>

      {/* Rates ------------------------------------------------------------------------ */}
      <section className="set__card" id="set-rates" aria-labelledby="set-rates-h">
        <h2 id="set-rates-h">{TEXT.sections.rates}</h2>
        <p className="set__muted">{TEXT.ratesExplain}</p>
        <ul className="set__rates">
          {data.rates.map((r) => {
            const which = `rate:${r.vehicle}:${r.gic_term ?? ''}`;
            return (
              <li key={which} className="set__row">
                <div className="set__row-head">
                  <span className="set__row-label">{r.what}</span>
                  <span className="set__row-value">{r.text}</span>
                  {open !== which && (
                    <ChangeButton label={TEXT.changeRate(r.what)} onClick={() => start(which)} />
                  )}
                </div>
                {r.special_to && (
                  <p className="set__special">⭐ {TEXT.specialUntil(r.special_to, r.regular)}</p>
                )}
                {r.scheduled.map((s) =>
                  scheduledLine(
                    'rate',
                    s.id,
                    s.from,
                    `${s.special ? '⭐ ' : ''}${r.what}: ${s.text}`,
                  ),
                )}
                {open === which && (
                  <RateChange row={r} data={data} onBack={back} onDone={finished} />
                )}
              </li>
            );
          })}
        </ul>
        <details className="set__history">
          <summary>{TEXT.rateHistory}</summary>
          <ul>
            {data.rate_history.map((h, i) => (
              <li key={i}>
                <span>
                  {h.special ? '⭐ ' : ''}
                  {h.what}: {h.text}
                  {h.cancelled ? TEXT.cancelledTag : ''}
                </span>
                <span className="set__muted">{TEXT.historyWho(h)}</span>
                {h.note && <span className="set__muted">“{h.note}”</span>}
              </li>
            ))}
          </ul>
        </details>
      </section>

      {/* Cap and limits ----------------------------------------------------------------- */}
      <div className="set__group" id="set-limits">
        <section className="set__card" aria-labelledby="set-cap">
          <h2 id="set-cap">{TEXT.capTitle}</h2>
          <p className="set__muted">{TEXT.capExplain}</p>
          {settingRow('cap', TEXT.capRow, data.cap, {
            settingKey: 'deposit_cap_cents',
            heading: TEXT.capHeading,
            rule: TEXT.capRule(data.cut_from_text),
            input: {
              kind: 'text',
              label: TEXT.capLabel,
              initial: data.cap.text.replace(/^\$/, '').replace(/\.00$/, ''),
              inputMode: 'decimal',
              parse: parseCap,
            },
            yes: (v) => TEXT.yesCap(formatCents(v)),
            noteLabel: TEXT.capNoteLabel,
          })}
        </section>

        <section className="set__card" aria-labelledby="set-expiry">
          <h2 id="set-expiry">{TEXT.expiryTitle}</h2>
          <p className="set__value">{TEXT.expiryNow(e.days)}</p>
          <p className="set__muted">{TEXT.expiryExplain}</p>
          {e.scheduled.map((s) =>
            scheduledLine('setting', s.id, s.from, TEXT.scheduled(s.days, s.from)),
          )}
          {open === 'expiry' ? (
            <SettingChange
              settingKey="request_expiry_days"
              heading={TEXT.changeHeading}
              input={{
                kind: 'text',
                label: TEXT.daysLabel(e.min, e.max),
                initial: String(e.days),
                inputMode: 'numeric',
                parse: (t) => {
                  const d = parseDays(t, e.min, e.max);
                  return typeof d === 'number' ? { value: String(d) } : { error: d };
                },
              }}
              yes={(v) => TEXT.yes(Number(v))}
              quiet={TEXT.noNoticeSame}
              today={data.today}
              onBack={back}
              onDone={finished}
            />
          ) : (
            <button type="button" className="set__btn" onClick={() => start('expiry')}>
              {TEXT.change}
            </button>
          )}
          <History
            items={e.history.map((h) => ({ line: TEXT.historyLine(h), ...h }))}
            label={TEXT.history}
          />
        </section>
      </div>

      {/* Inflation and dividends --------------------------------------------------------- */}
      <div className="set__group" id="set-money">
        <section className="set__card" aria-labelledby="set-inflation">
          <h2 id="set-inflation">{TEXT.inflationTitle}</h2>
          <p className="set__muted">{TEXT.inflationExplain}</p>
          {settingRow('inflation', TEXT.perYear, data.inflation, {
            settingKey: 'inflation_rate',
            heading: TEXT.inflationHeading,
            input: {
              kind: 'text',
              label: TEXT.percentLabel,
              initial: data.inflation.value,
              inputMode: 'decimal',
              parse: parsePercent,
            },
            yes: (v) => TEXT.yesPercent(v),
          })}
        </section>

        <section className="set__card" aria-labelledby="set-yields">
          <h2 id="set-yields">{TEXT.yieldsTitle}</h2>
          <p className="set__muted">{TEXT.yieldsExplain}</p>
          {data.yields.map((y) =>
            settingRow(
              `yield:${y.fund_id}`,
              y.name,
              y.card,
              {
                settingKey: `dividend_yield:${y.fund_id}`,
                heading: TEXT.yieldHeading(y.name),
                rule: TEXT.cutRule(data.cut_from_text),
                noteLabel: TEXT.yieldNoteLabel,
                input: {
                  kind: 'text',
                  label: TEXT.yieldLabel,
                  initial: y.card.value,
                  inputMode: 'decimal',
                  parse: parsePercent,
                },
                yes: (v) => TEXT.yesPercent(v),
              },
              { buttonLabel: TEXT.changeYield(y.name) },
            ),
          )}
        </section>
      </div>

      {/* Feature switches ----------------------------------------------------------------- */}
      <section className="set__card" id="set-features" aria-labelledby="set-features-h">
        <h2 id="set-features-h">{TEXT.featuresTitle}</h2>
        <p className="set__muted">{TEXT.featuresExplain}</p>
        {data.features.map((f) => {
          const about = FEATURES[f.name] ?? { name: f.name, about: '' };
          return (
            <div key={f.name}>
              {about.about && <p className="set__muted set__about">{about.about}</p>}
              {settingRow(
                `feature:${f.name}`,
                about.name,
                f.card,
                {
                  settingKey: `feature:${f.name}`,
                  heading: TEXT.featureHeading(about.name),
                  input: {
                    kind: 'choice',
                    label: TEXT.switchLabel,
                    initial: f.card.value,
                    choices: SWITCH_CHOICES,
                    parse: (v) => ({ value: v }),
                  },
                  yes: (v) => TEXT.yesSwitch(SWITCH_CHOICES.find((c) => c.value === v)?.label ?? v),
                },
                { buttonLabel: TEXT.changeFeature(about.name) },
              )}
            </div>
          );
        })}
      </section>

      {/* Wording ----------------------------------------------------------------------- */}
      <div className="set__group" id="set-wording">
        <section className="set__card" aria-labelledby="set-notes">
          <h2 id="set-notes">{TEXT.notesTitle}</h2>
          <p className="set__muted">{TEXT.notesExplain}</p>
          {(['up', 'down'] as const).map((d) =>
            settingRow(
              `note_${d}`,
              d === 'up' ? TEXT.noteUp : TEXT.noteDown,
              d === 'up' ? data.note_up : data.note_down,
              {
                settingKey: `market_move_note_${d}`,
                heading: TEXT.noteHeading(d === 'up'),
                input: {
                  kind: 'textarea',
                  label: TEXT.noteWordsLabel,
                  initial: (d === 'up' ? data.note_up : data.note_down).value,
                  parse: (t) => parseWords(t, 300),
                },
                yes: () => TEXT.yesWords,
              },
              { buttonLabel: TEXT.changeNote(d === 'up'), long: true },
            ),
          )}
          <h3 className="set__sub">{TEXT.writtenTitle(notesShown, data.notes_total)}</h3>
          {notesShown === 0 ? (
            <p className="set__muted">{TEXT.noNotes}</p>
          ) : (
            <ul className="set__list">
              {data.notes.map((n) => (
                <li key={n.id} className="set__row">
                  <span className="set__row-label">{TEXT.noteFor(n)}</span>
                  {open === `note:${n.id}` ? (
                    <WordingEdit
                      action="edit_note"
                      target={n.id}
                      initial={n.body}
                      max={300}
                      label={TEXT.noteWordsLabel}
                      onBack={back}
                      onDone={finished}
                    />
                  ) : (
                    <>
                      <p className="set__words">{n.body}</p>
                      <button
                        type="button"
                        className="set__btn set__btn--small set__btn--quiet"
                        aria-label={TEXT.editNote(n)}
                        onClick={() => start(`note:${n.id}`)}
                      >
                        Edit
                      </button>
                    </>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>

        <GlossarySection data={data} open={open} start={start} back={back} finished={finished} />
      </div>

      {/* Logins: PIN reset ---------------------------------------------------------------- */}
      <Logins />

      {/* Backup ------------------------------------------------------------------------ */}
      <section className="set__card" id="set-backup" aria-labelledby="set-backup-h">
        <h2 id="set-backup-h">{TEXT.backupTitle}</h2>
        <button type="button" className="set__btn" disabled aria-describedby="set-backup-off">
          ⬇ {TEXT.backupButton}
        </button>
        <p className="set__muted" id="set-backup-off">
          {TEXT.backupOff}
        </p>
      </section>

      {data.recent.length > 0 && (
        <section className="set__card" aria-labelledby="set-recent">
          <h2 id="set-recent">{TEXT.recentTitle}</h2>
          <ul className="set__list set__recent">
            {data.recent.map((r, i) => (
              <li key={i}>
                <span>{r.summary}</span>
                <span className="set__muted">{TEXT.historyWho(r)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </section>
  );
}

function ChangeButton({ label, onClick }: { label?: string; onClick: () => void }) {
  return (
    <button type="button" className="set__btn set__btn--small" aria-label={label} onClick={onClick}>
      {TEXT.change}
    </button>
  );
}

function History({
  items,
  label = TEXT.history,
}: {
  items: { line: string; note: string | null; who: string; when: string | null }[];
  label?: string;
}) {
  if (items.length === 0) return null;
  return (
    <details className="set__history">
      <summary>{label}</summary>
      <ul>
        {items.map((h, i) => (
          <li key={i}>
            <span>{h.line}</span>
            <span className="set__muted">{TEXT.historyWho(h)}</span>
            {h.note && <span className="set__muted">“{h.note}”</span>}
          </li>
        ))}
      </ul>
    </details>
  );
}

function GlossarySection({
  data,
  open,
  start,
  back,
  finished,
}: {
  data: SettingsData;
  open: string | null;
  start: (which: string) => void;
  back: () => void;
  finished: () => Promise<void>;
}): ReactNode {
  const id = useId();
  const [find, setFind] = useState('');
  const q = find.trim().toLowerCase();
  const shown = data.glossary.filter(
    (g) => !q || g.term.toLowerCase().includes(q) || g.text.toLowerCase().includes(q),
  );
  return (
    <section className="set__card" aria-labelledby="set-glossary">
      <h2 id="set-glossary">{TEXT.glossaryTitle}</h2>
      <p className="set__muted">{TEXT.glossaryExplain}</p>
      <details className="set__history">
        <summary>{TEXT.glossaryShow(data.glossary.length)}</summary>
        <label htmlFor={`${id}-f`} className="set__find-label">
          {TEXT.glossaryFilter}
        </label>
        <input
          id={`${id}-f`}
          className="set__find"
          type="search"
          value={find}
          onChange={(ev) => setFind(ev.target.value)}
        />
        {shown.length === 0 && <p className="set__muted">{TEXT.glossaryNone}</p>}
        <ul className="set__list">
          {shown.map((g) => (
            <li key={g.term} className="set__row">
              <span className="set__row-label">{g.term}</span>
              {open === `term:${g.term}` ? (
                <WordingEdit
                  action="edit_glossary"
                  target={g.term}
                  initial={g.text}
                  max={400}
                  label={TEXT.glossaryWordsLabel}
                  onBack={back}
                  onDone={finished}
                />
              ) : (
                <>
                  <p className="set__words">{g.text}</p>
                  <button
                    type="button"
                    className="set__btn set__btn--small set__btn--quiet"
                    aria-label={TEXT.editTerm(g.term)}
                    onClick={() => start(`term:${g.term}`)}
                  >
                    Edit
                  </button>
                </>
              )}
            </li>
          ))}
        </ul>
      </details>
    </section>
  );
}
