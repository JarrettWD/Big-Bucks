// The four kinds of change on the Settings screen. Each shows a summary and
// exactly what the girls will be told (the real action, run by the database and
// rolled back), then one button that does it. The database checks the rules again
// and logs who did it and when.
//   SettingChange: a dated setting (cap, expiry, inflation, a yield, a switch, a standard note)
//   RateChange:    a new savings or GIC rate, regular or a limited-time special
//   WordingEdit:   a note already written, or a ? explanation
//   CancelChange:  cancel a rate or setting change that hasn't started

import { useId, useState, type ReactNode } from 'react';
import { ChangeActions, PreviewBox } from './Preview';
import { runAction, useFocusOnOpen, usePreview } from './usePreview';
import { TEXT, parsePercent, type Parsed, type RateRow, type SettingsData } from './settingsText';

export interface SettingInput {
  kind: 'text' | 'textarea' | 'choice';
  label: string;
  initial: string;
  inputMode?: 'numeric' | 'decimal';
  choices?: readonly { value: string; label: string }[];
  /** What's typed → the value the database stores, or a message. */
  parse: (text: string) => Parsed;
}

export function SettingChange({
  settingKey,
  heading,
  input,
  yes,
  today,
  noteLabel = TEXT.noteLabel,
  quiet,
  rule,
  onBack,
  onDone,
}: {
  settingKey: string;
  heading: string;
  /** A rule to show under the heading (for example 7 days' notice for a cut). */
  rule?: string;
  input: SettingInput;
  /** The button's words, from the parsed value. */
  yes: (value: string) => string;
  today: string;
  noteLabel?: string;
  quiet?: string;
  onBack: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const headingRef = useFocusOnOpen<HTMLHeadingElement>();
  const [text, setText] = useState(input.initial);
  const [starts, setStarts] = useState(today);
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);

  const parsed = input.parse(text);
  const typo = 'error' in parsed ? parsed.error : null;
  const args =
    'value' in parsed
      ? { key: settingKey, value: parsed.value, effective_date: starts, note: note.trim() || null }
      : null;
  const current = usePreview('set_setting', args);

  const go = async () => {
    if (!args || !current?.summary) return;
    setSaving(true);
    setFailed(null);
    const problem = await runAction('set_setting', {
      p_key: args.key,
      p_value: args.value,
      p_effective_date: args.effective_date,
      p_note: args.note,
    });
    if (problem) {
      setSaving(false);
      setFailed(problem);
      return;
    }
    await onDone();
  };

  const problem = typo ?? failed ?? current?.problem ?? null;
  const facts = current?.facts;
  return (
    <div className="set__change" role="group" aria-labelledby={`${id}-h`}>
      <h3 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {heading}
      </h3>
      {rule && <p className="set__rule">{rule}</p>}
      {input.kind === 'choice' ? (
        <fieldset className="set__choices">
          <legend>{input.label}</legend>
          {input.choices?.map((c) => (
            <label key={c.value} className="set__choice">
              <input
                type="radio"
                name={`${id}-c`}
                value={c.value}
                checked={text === c.value}
                onChange={() => setText(c.value)}
              />
              {c.label}
            </label>
          ))}
        </fieldset>
      ) : (
        <>
          <label htmlFor={`${id}-v`}>{input.label}</label>
          {input.kind === 'textarea' ? (
            <textarea
              id={`${id}-v`}
              rows={3}
              value={text}
              onChange={(ev) => setText(ev.target.value)}
              aria-describedby={`${id}-p`}
            />
          ) : (
            <input
              id={`${id}-v`}
              inputMode={input.inputMode}
              autoComplete="off"
              value={text}
              onChange={(ev) => setText(ev.target.value)}
              aria-describedby={`${id}-p`}
            />
          )}
        </>
      )}
      <label htmlFor={`${id}-s`}>{TEXT.startsLabel}</label>
      <input
        id={`${id}-s`}
        type="date"
        min={today}
        value={starts}
        onChange={(ev) => setStarts(ev.target.value || today)}
      />
      <label htmlFor={`${id}-n`}>{noteLabel}</label>
      <input
        id={`${id}-n`}
        value={note}
        maxLength={200}
        onChange={(ev) => setNote(ev.target.value)}
      />

      <PreviewBox
        id={`${id}-p`}
        current={current}
        problem={problem}
        facts={facts && facts.after !== facts.before ? TEXT.fromTo(facts) : null}
        quiet={quiet}
      />
      <ChangeActions
        yes={'value' in parsed ? yes(parsed.value) : yes(input.initial)}
        blocked={current === null || problem !== null || !current.summary}
        saving={saving}
        onYes={() => void go()}
        onBack={onBack}
      />
    </div>
  );
}

export function RateChange({
  row,
  data,
  onBack,
  onDone,
}: {
  row: RateRow;
  data: SettingsData;
  onBack: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const headingRef = useFocusOnOpen<HTMLHeadingElement>();
  const [text, setText] = useState(row.rate);
  const [special, setSpecial] = useState(false);
  const [starts, setStarts] = useState(data.rate_from);
  const [ends, setEnds] = useState(data.rate_to);
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);

  const parsed = parsePercent(text);
  const typo = 'error' in parsed ? parsed.error : null;
  const args =
    'value' in parsed
      ? {
          vehicle: row.vehicle,
          gic_term: row.gic_term,
          rate: parsed.value,
          effective_date: starts,
          end_date: special ? ends : null,
          note: note.trim() || null,
        }
      : null;
  const current = usePreview('add_rate', args);

  const go = async () => {
    if (!args || !current?.summary) return;
    setSaving(true);
    setFailed(null);
    const problem = await runAction('add_rate', {
      p_vehicle: args.vehicle,
      p_gic_term: args.gic_term,
      p_rate: args.rate,
      p_effective_date: args.effective_date,
      p_note: args.note,
      p_end_date: args.end_date,
    });
    if (problem) {
      setSaving(false);
      setFailed(problem);
      return;
    }
    await onDone();
  };

  const problem = typo ?? failed ?? current?.problem ?? null;
  const facts = current?.facts ?? null;
  return (
    <div className="set__change" role="group" aria-labelledby={`${id}-h`}>
      <h3 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {TEXT.rateHeading(row.what)}
      </h3>
      <label htmlFor={`${id}-r`}>{TEXT.rateLabel}</label>
      <input
        id={`${id}-r`}
        inputMode="decimal"
        autoComplete="off"
        value={text}
        onChange={(ev) => setText(ev.target.value)}
        aria-describedby={`${id}-p`}
      />
      <label className="set__check">
        <input type="checkbox" checked={special} onChange={(ev) => setSpecial(ev.target.checked)} />
        {TEXT.specialLabel}
      </label>
      {special && <p className="set__muted">{TEXT.specialHelp}</p>}
      <p className="set__rule">{TEXT.cutRule(data.cut_from_text)}</p>
      <label htmlFor={`${id}-s`}>{TEXT.rateStartsLabel(special)}</label>
      <input
        id={`${id}-s`}
        type="date"
        min={data.today}
        value={starts}
        onChange={(ev) => setStarts(ev.target.value || data.rate_from)}
      />
      {special && (
        <>
          <label htmlFor={`${id}-e`}>{TEXT.rateEndsLabel}</label>
          <input
            id={`${id}-e`}
            type="date"
            min={starts}
            value={ends}
            onChange={(ev) => setEnds(ev.target.value || data.rate_to)}
          />
        </>
      )}
      <label htmlFor={`${id}-n`}>{TEXT.rateNoteLabel}</label>
      <input
        id={`${id}-n`}
        value={note}
        maxLength={200}
        onChange={(ev) => setNote(ev.target.value)}
      />

      <PreviewBox
        id={`${id}-p`}
        current={current}
        problem={problem}
        facts={facts ? TEXT.rateFacts(facts) : null}
        extra={TEXT.lockedIn}
      />
      <ChangeActions
        yes={TEXT.yesRate(problem ? null : facts)}
        blocked={current === null || problem !== null || !current.summary}
        saving={saving}
        onYes={() => void go()}
        onBack={onBack}
      />
    </div>
  );
}

export function WordingEdit({
  action,
  target,
  initial,
  max,
  label,
  children,
  onBack,
  onDone,
}: {
  action: 'edit_note' | 'edit_glossary';
  /** The note's id, or the glossary term. */
  target: number | string;
  initial: string;
  max: number;
  label: string;
  children?: ReactNode;
  onBack: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const headingRef = useFocusOnOpen<HTMLHeadingElement>();
  const [text, setText] = useState(initial);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);

  const t = text.trim();
  const typo =
    t === ''
      ? 'Type some words.'
      : t.length > max
        ? `Use at most ${max} letters (now ${t.length}).`
        : null;
  const args = typo
    ? null
    : action === 'edit_note'
      ? { note_id: target, body: t }
      : { term: target, text: t };
  const current = usePreview(action, args);

  const go = async () => {
    if (!args || !current?.summary) return;
    setSaving(true);
    setFailed(null);
    const problem =
      action === 'edit_note'
        ? await runAction('edit_note', { p_note_id: target, p_body: t })
        : await runAction('edit_glossary', { p_term: target, p_text: t });
    if (problem) {
      setSaving(false);
      setFailed(problem);
      return;
    }
    await onDone();
  };

  const problem = typo ?? failed ?? current?.problem ?? null;
  return (
    <div className="set__change" role="group" aria-labelledby={`${id}-h`}>
      <h3 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {TEXT.editHeading}
      </h3>
      {children}
      <label htmlFor={`${id}-v`}>{label}</label>
      <textarea
        id={`${id}-v`}
        rows={4}
        value={text}
        onChange={(ev) => setText(ev.target.value)}
        aria-describedby={`${id}-p`}
      />
      <PreviewBox id={`${id}-p`} current={current} problem={problem} quiet={TEXT.wordingQuiet} />
      <ChangeActions
        yes={TEXT.yesWords}
        blocked={current === null || problem !== null || !current.summary}
        saving={saving}
        onYes={() => void go()}
        onBack={onBack}
      />
    </div>
  );
}

export function CancelChange({
  kind,
  id: targetId,
  what,
  onBack,
  onDone,
}: {
  kind: 'rate' | 'setting';
  id: number;
  /** The change in words, e.g. "Savings: 1.5% from Oct 12". */
  what: string;
  onBack: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const headingRef = useFocusOnOpen<HTMLHeadingElement>();
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);

  const args = { kind, id: targetId, note: note.trim() || null };
  const current = usePreview('cancel_change', args);

  const go = async () => {
    if (!current?.summary) return;
    setSaving(true);
    setFailed(null);
    const problem = await runAction('cancel_change', {
      p_kind: kind,
      p_id: targetId,
      p_note: args.note,
    });
    if (problem) {
      setSaving(false);
      setFailed(problem);
      return;
    }
    await onDone();
  };

  const problem = failed ?? current?.problem ?? null;
  return (
    <div className="set__change" role="group" aria-labelledby={`${id}-h`}>
      <h3 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {TEXT.cancelHeading}
      </h3>
      <p className="set__facts">{what}</p>
      <p className="set__muted">{TEXT.cancelExplain}</p>
      <label htmlFor={`${id}-n`}>{TEXT.cancelNoteLabel}</label>
      <input
        id={`${id}-n`}
        value={note}
        maxLength={200}
        onChange={(ev) => setNote(ev.target.value)}
      />
      <PreviewBox id={`${id}-p`} current={current} problem={problem} quiet={TEXT.cancelQuiet} />
      <ChangeActions
        yes={TEXT.yesCancel}
        blocked={current === null || problem !== null || !current.summary}
        saving={saving}
        onYes={() => void go()}
        onBack={onBack}
      />
    </div>
  );
}
