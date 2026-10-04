// Approvals: Dad's deposits, withdrawals and "Something looks wrong?" questions.
//
// Every decision opens a confirmation first: a plain summary, the words she'll
// see (the database's own notice, from parent_decision_preview: the real action,
// rolled back), then one button that does it. The database checks every rule
// again and logs who did it and when (parent_actions).

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { useOutletContext } from 'react-router-dom';
import { describeActivity } from '../../kid/home/activityText';
import { formatDate } from '../../lib/format';
import { supabase } from '../../lib/supabase';
import type { Inbox, InboxState, OpenQuestion, WaitingRequest } from '../useInbox';
import {
  TEXT,
  approveCashLine,
  approveHeading,
  declineHeading,
  declineLine,
  expiryLine,
  requestFacts,
  requestIcon,
  requestTitle,
  secondsLeft,
  waitLine,
} from './approvalsText';
import './Approvals.css';

type Kind = 'approve' | 'decline' | 'answer';
interface Open {
  kind: Kind;
  id: number;
}
interface Preview {
  problem: string | null;
  notices: { title: string; body: string }[];
  summary: string | null;
}

/** Re-renders every `ms` so the countdowns move. */
function useNow(ms: number): number {
  const [now, setNow] = useState(() => performance.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(performance.now()), ms);
    return () => window.clearInterval(t);
  }, [ms]);
  return now;
}

export default function Approvals() {
  const { inbox, error, loadedAt, reload } = useOutletContext<InboxState>();
  const [open, setOpen] = useState<Open | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const doneRef = useRef<HTMLParagraphElement>(null);
  const now = useNow(15_000);
  const elapsed = now - loadedAt;

  // When a 24-hour wait or an expiry runs out, ask the database again: it decides.
  useEffect(() => {
    if (!inbox) return;
    const crossed = inbox.requests.some(
      (r) =>
        (r.wait_seconds > 0 && secondsLeft(r.wait_seconds, elapsed) === 0) ||
        (r.expires_seconds > 0 && secondsLeft(r.expires_seconds, elapsed) === 0),
    );
    if (crossed) void reload();
  }, [inbox, elapsed, reload]);

  useEffect(() => {
    if (done) doneRef.current?.focus();
  }, [done]);

  const finished = useCallback((fresh: Inbox | null) => {
    setOpen(null);
    const last = fresh?.recent[0];
    setDone(last ? TEXT.done(last.summary, last.who, last.when) : 'Done.');
  }, []);

  if (error && !inbox)
    return (
      <section className="appr">
        <p className="appr__error" role="alert">
          {TEXT.loadError(error)}
        </p>
        <button type="button" className="appr__btn" onClick={() => void reload()}>
          {TEXT.retry}
        </button>
      </section>
    );
  if (!inbox) return <p className="appr__muted">Loading…</p>;

  const openFor = (kind: Kind, id: number) => {
    setDone(null);
    setOpen({ kind, id });
  };

  return (
    <section className="appr" aria-labelledby="appr-title">
      <h1 id="appr-title" className="appr__title">
        {TEXT.title}
      </h1>
      {done && (
        <p className="appr__done" role="status" tabIndex={-1} ref={doneRef}>
          {done}
        </p>
      )}

      <div className="appr__cols">
        <section className="appr__group" aria-labelledby="appr-money">
          <h2 id="appr-money">
            {TEXT.money} <span className="appr__count">{inbox.requests.length}</span>
          </h2>
          {inbox.requests.length === 0 && <p className="appr__muted">{TEXT.moneyEmpty}</p>}
          <ul className="appr__list">
            {inbox.requests.map((r) => (
              <RequestCard
                key={r.id}
                r={r}
                elapsed={elapsed}
                open={open?.id === r.id && open.kind !== 'answer' ? open.kind : null}
                onOpen={(k) => openFor(k, r.id)}
                onClose={() => setOpen(null)}
                onDone={async () => finished(await reload())}
              />
            ))}
          </ul>
        </section>

        <section className="appr__group" aria-labelledby="appr-questions">
          <h2 id="appr-questions">
            {TEXT.questions} <span className="appr__count">{inbox.questions.length}</span>
          </h2>
          {inbox.questions.length === 0 && <p className="appr__muted">{TEXT.questionsEmpty}</p>}
          <ul className="appr__list">
            {inbox.questions.map((q) => (
              <QuestionCard
                key={q.id}
                q={q}
                open={open?.kind === 'answer' && open.id === q.id}
                onOpen={() => openFor('answer', q.id)}
                onClose={() => setOpen(null)}
                onDone={async () => finished(await reload())}
              />
            ))}
          </ul>
        </section>
      </div>

      <section className="appr__group appr__recent" aria-labelledby="appr-recent">
        <h2 id="appr-recent">{TEXT.recent}</h2>
        {inbox.recent.length === 0 ? (
          <p className="appr__muted">{TEXT.recentEmpty}</p>
        ) : (
          <ul className="appr__recent-list">
            {inbox.recent.map((a) => (
              <li key={a.id}>
                <span className="appr__recent-what">
                  {a.summary}
                  {a.is_test && <TestTag />}
                </span>
                <span className="appr__recent-who">
                  {a.who} · {a.when}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
      <p className="appr__muted appr__updated">{TEXT.updated(inbox.now)}</p>
    </section>
  );
}

function TestTag() {
  return <span className="appr__test">{TEXT.test}</span>;
}

function RequestCard({
  r,
  elapsed,
  open,
  onOpen,
  onClose,
  onDone,
}: {
  r: WaitingRequest;
  elapsed: number;
  open: 'approve' | 'decline' | null;
  onOpen: (k: 'approve' | 'decline') => void;
  onClose: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const wait = secondsLeft(r.wait_seconds, elapsed);
  const expires = secondsLeft(r.expires_seconds, elapsed);
  const locked = wait > 0 || expires <= 0;
  return (
    <li className="appr__card">
      <div className="appr__head">
        <span className="appr__icon" aria-hidden="true">
          {requestIcon(r)}
        </span>
        <h3 className="appr__what">
          {requestTitle(r)}
          <span className="appr__kid">
            {r.kid}
            {r.is_test && <TestTag />}
          </span>
        </h3>
      </div>
      <p className="appr__line">{TEXT.asked(r.asked)}</p>
      <dl className="appr__facts">
        {requestFacts(r).map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
      {wait > 0 && (
        <p className="appr__wait" id={`${id}-wait`}>
          <span aria-hidden="true">🔒 </span>
          {waitLine(r, wait)}
        </p>
      )}
      <p
        className={expires < 24 * 3600 ? 'appr__line appr__line--soon' : 'appr__line'}
        id={`${id}-exp`}
      >
        {expiryLine(r, expires)}
      </p>

      {open === null ? (
        <div className="appr__actions">
          <button
            type="button"
            className="appr__btn"
            disabled={locked}
            aria-describedby={wait > 0 ? `${id}-wait` : expires <= 0 ? `${id}-exp` : undefined}
            onClick={() => onOpen('approve')}
          >
            {TEXT.approve}
          </button>
          <button
            type="button"
            className="appr__btn appr__btn--quiet"
            onClick={() => onOpen('decline')}
          >
            {TEXT.decline}
          </button>
        </div>
      ) : open === 'approve' ? (
        <Decision
          kind="approve"
          targetId={r.id}
          kid={r.kid}
          heading={approveHeading(r)}
          lines={[approveCashLine(r)]}
          label={TEXT.noteLabel(r.kid)}
          required={false}
          confirm={TEXT.yesApprove(r)}
          onCancel={onClose}
          onDone={onDone}
        />
      ) : (
        <Decision
          kind="decline"
          targetId={r.id}
          kid={r.kid}
          heading={declineHeading(r)}
          lines={[declineLine(r)]}
          label={TEXT.reasonLabel(r.kid)}
          required
          confirm={TEXT.yesDecline}
          onCancel={onClose}
          onDone={onDone}
        />
      )}
    </li>
  );
}

function QuestionCard({
  q,
  open,
  onOpen,
  onClose,
  onDone,
}: {
  q: OpenQuestion;
  open: boolean;
  onOpen: () => void;
  onClose: () => void;
  onDone: () => Promise<void>;
}) {
  const line = q.line ? describeActivity(q.line) : null;
  return (
    <li className="appr__card">
      <div className="appr__head">
        <span className="appr__icon" aria-hidden="true">
          💬
        </span>
        <h3 className="appr__what">
          {q.kid}
          {q.is_test && <TestTag />}
          <span className="appr__kid">{TEXT.asked(q.asked)}</span>
        </h3>
      </div>
      <blockquote className="appr__quote">{q.message}</blockquote>
      {line && q.line ? (
        <div className="appr__about">
          <p className="appr__about-label">{TEXT.aboutLine}</p>
          <p className="appr__about-line">
            <span aria-hidden="true">{line.icon} </span>
            <span className="appr__about-title">{line.title}</span>
            {line.detail && <span className="appr__about-detail"> · {line.detail}</span>}
            <span className="appr__about-day"> · {formatDate(line.day)}</span>
            <strong className="appr__about-amount">{line.amount}</strong>
          </p>
          {q.line.note && (
            <p className="appr__about-calc">
              {TEXT.calc} {q.line.note}
            </p>
          )}
        </div>
      ) : (
        <p className="appr__muted">{TEXT.noLine}</p>
      )}
      {open ? (
        <Decision
          kind="answer"
          targetId={q.id}
          kid={q.kid}
          heading={TEXT.answerHeading(q.kid)}
          lines={[]}
          label={TEXT.answerLabel(q.kid)}
          required
          confirm={TEXT.sendAnswer}
          onCancel={onClose}
          onDone={onDone}
        />
      ) : (
        <div className="appr__actions">
          <button type="button" className="appr__btn" onClick={onOpen}>
            {TEXT.answer}
          </button>
        </div>
      )}
    </li>
  );
}

const ACTIONS: Record<Kind, { fn: string; id: string; text: string }> = {
  approve: { fn: 'approve_request', id: 'p_request_id', text: 'p_note' },
  decline: { fn: 'decline_request', id: 'p_request_id', text: 'p_reason' },
  answer: { fn: 'answer_question', id: 'p_question_id', text: 'p_reply' },
};

/** The confirmation: summary, Dad's words, what she'll see, then one button. */
function Decision({
  kind,
  targetId,
  kid,
  heading,
  lines,
  label,
  required,
  confirm,
  onCancel,
  onDone,
}: {
  kind: Kind;
  targetId: number;
  kid: string;
  heading: string;
  lines: string[];
  label: string;
  required: boolean;
  confirm: string;
  onCancel: () => void;
  onDone: () => Promise<void>;
}) {
  const id = useId();
  const headingRef = useRef<HTMLHeadingElement>(null);
  const [text, setText] = useState('');
  // The latest preview, and the exact words it was made for: the button only works
  // once the preview matches what's typed, so Dad confirms what he saw.
  const [preview, setPreview] = useState<{ text: string; result: Preview } | null>(null);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const seq = useRef(0);
  const empty = text.trim() === '';
  const waitingForWords = required && empty;
  const current = preview && preview.text === text ? preview.result : null;
  const checking = !waitingForWords && current === null;

  useEffect(() => {
    headingRef.current?.focus();
  }, []);

  // Ask the database what she'd see, after Dad pauses typing.
  useEffect(() => {
    const mine = ++seq.current;
    if (waitingForWords) return;
    const t = window.setTimeout(
      async () => {
        const { data, error } = await supabase.rpc('parent_decision_preview', {
          p_kind: kind,
          p_id: targetId,
          p_text: empty ? null : text,
        });
        if (mine !== seq.current) return;
        setPreview({
          text,
          result: error
            ? { problem: error.message, notices: [], summary: null }
            : (data as Preview),
        });
      },
      text === '' ? 0 : 500,
    );
    return () => window.clearTimeout(t);
  }, [kind, targetId, text, empty, waitingForWords]);

  const go = async () => {
    setSaving(true);
    setFailed(null);
    const a = ACTIONS[kind];
    const { error } = await supabase.rpc(a.fn, { [a.id]: targetId, [a.text]: empty ? null : text });
    if (error) {
      setSaving(false);
      setFailed(error.message);
      return;
    }
    await onDone();
  };

  const blocked = saving || waitingForWords || current === null || current.problem !== null;
  const shown = waitingForWords ? null : (current ?? preview?.result ?? null);
  const problem = failed ?? current?.problem ?? null;

  return (
    <div className="appr__decide" role="group" aria-labelledby={`${id}-h`}>
      <h4 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {heading}
      </h4>
      {lines.map((l) => (
        <p key={l}>{l}</p>
      ))}
      <label htmlFor={`${id}-t`}>{label}</label>
      <textarea
        id={`${id}-t`}
        value={text}
        rows={3}
        maxLength={500}
        onChange={(e) => setText(e.target.value)}
        aria-describedby={`${id}-sees`}
      />
      <div className="appr__sees" id={`${id}-sees`} aria-live="polite">
        <p className="appr__sees-label">{TEXT.sheSees(kid)}</p>
        {waitingForWords ? (
          <p className="appr__muted">{TEXT.previewWaiting}</p>
        ) : checking && !shown ? (
          <p className="appr__muted">{TEXT.checking}</p>
        ) : (
          shown?.notices.map((n) => (
            <div className="appr__notice" key={n.title + n.body}>
              <p className="appr__notice-title">{n.title}</p>
              {n.body && <p className="appr__notice-body">{n.body}</p>}
            </div>
          ))
        )}
      </div>
      {problem && (
        <p className="appr__error" role="alert">
          {problem}
        </p>
      )}
      <div className="appr__actions">
        <button type="button" className="appr__btn" disabled={blocked} onClick={() => void go()}>
          {saving ? TEXT.saving : confirm}
        </button>
        <button
          type="button"
          className="appr__btn appr__btn--quiet"
          disabled={saving}
          onClick={onCancel}
        >
          {TEXT.back}
        </button>
      </div>
    </div>
  );
}
