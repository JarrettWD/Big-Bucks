// Her history lines, used on Home (the last 5) and on the "See all" page. Tap a
// line to open it:
//   - "How was this calculated?": the working the database wrote on the line when
//     it posted (interest, dividends, GIC interest, fund buys and sales, a GIC
//     broken early, a penalty). Nothing is worked out here.
//   - her questions about the line, with Dad's answers
//   - "Something looks wrong?": a question to Dad with the line attached
// Wording is listed in docs/MESSAGES.md §7 and §9.

import { useId, useState } from 'react';
import { Link } from 'react-router-dom';
import { formatDate } from '../../lib/format';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { useKidView } from '../kidView';
import { useQuestions, type Question } from '../useQuestions';
import { describeActivity, type ActivityLine, type ActivityRow } from './activityText';

/** Lines whose note is the database's working ("$100.00 × 5.0% × 12/12 = $5.00"). */
const WORKING_KINDS = new Set([
  'interest',
  'gic_interest',
  'dividend',
  'fund_buy',
  'fund_sell',
  'gic_break',
  'penalty',
]);

/**
 * A page that also lists her questions (History) passes its own list in, so a
 * question sent from a line shows in both places at once.
 */
export function ActivityList({
  rows,
  thisYear,
  shared,
}: {
  rows: ActivityRow[];
  thisYear: number;
  shared?: { questions: Question[]; reload: () => void };
}) {
  const { view } = useKid();
  const own = useQuestions(shared ? null : view);
  const { questions, reload } = shared ?? own;
  const [open, setOpen] = useState<string | null>(null);
  const id = useId();

  if (rows.length === 0)
    return <p className="muted">Nothing here yet. Your story starts with your first deposit!</p>;
  return (
    <ul className="activity">
      {rows.map((r) => {
        const line = describeActivity(r);
        const isOpen = open === line.key;
        const panel = `${id}-${line.key}`;
        return (
          <li key={line.key} className="activity__item">
            <button
              type="button"
              className={`activity__row activity__row--${line.tone}`}
              aria-expanded={isOpen}
              aria-controls={panel}
              onClick={() => setOpen(isOpen ? null : line.key)}
            >
              <span className="activity__icon" aria-hidden="true">
                {line.icon}
              </span>
              <span className="activity__text">
                <span className="activity__title">{line.title}</span>
                {line.detail && <span className="activity__detail">{line.detail}</span>}
                <span className="activity__date">{formatDate(line.day, thisYear)}</span>
              </span>
              {line.amount && <span className="activity__amount">{line.amount}</span>}
            </button>
            {isOpen && (
              <LineDetails
                id={panel}
                row={r}
                line={line}
                thisYear={thisYear}
                questions={questions.filter(
                  (q) => q.transaction_id !== null && r.transaction_ids?.includes(q.transaction_id),
                )}
                onAsked={reload}
              />
            )}
          </li>
        );
      })}
    </ul>
  );
}

function LineDetails(p: {
  id: string;
  row: ActivityRow;
  line: ActivityLine;
  thisYear: number;
  questions: Question[];
  onAsked: () => void;
}) {
  const view = useKidView();
  const working = WORKING_KINDS.has(p.row.kind) && p.row.note ? p.row.note : null;
  return (
    <div id={p.id} className="activity__more">
      {working && (
        <div className="working">
          <h3 className="working__title">How was this calculated?</h3>
          <p className="working__text">{working}</p>
        </div>
      )}
      {view.viewing && p.row.kind !== 'request_pending' && (
        // Dad's "View as" stays read-only: this only leads to his own parent screen.
        <p className="activity__fix">
          <Link
            to={`/parent/fix/${view.accountId}?line=${encodeURIComponent(p.row.item_key)}`}
            aria-describedby={`${p.id}-fixhelp`}
          >
            Fix a mistake
          </Link>
          <span id={`${p.id}-fixhelp`} className="activity__fix-help">
            Opens your own parent screen for this line. Nothing changes here.
          </span>
        </p>
      )}
      {p.questions.length > 0 && <QuestionList questions={p.questions} thisYear={p.thisYear} />}
      <AskDad row={p.row} line={p.line} thisYear={p.thisYear} onAsked={p.onAsked} />
    </div>
  );
}

export function QuestionList({ questions, thisYear }: { questions: Question[]; thisYear: number }) {
  return (
    <ul className="questions">
      {questions.map((q) => (
        <li key={q.id} className="question">
          <p>
            <strong>You asked</strong> ({formatDate(q.asked_on, thisYear)}): {q.message}
          </p>
          {q.answered && q.reply ? (
            <p className="question__reply">
              <strong>Dad answered</strong>
              {q.answered_on ? ` (${formatDate(q.answered_on, thisYear)})` : ''}: {q.reply}
            </p>
          ) : (
            <p className="question__waiting">Waiting for Dad's answer.</p>
          )}
        </li>
      ))}
    </ul>
  );
}

/** "Something looks wrong?": a question to Dad about this line. */
function AskDad(p: {
  row: ActivityRow;
  line: ActivityLine;
  thisYear: number;
  onAsked: () => void;
}) {
  const view = useKidView();
  const [state, setState] = useState<'closed' | 'open' | 'sent'>('closed');
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const id = useId();

  // A ledger line goes with the question itself. A request (waiting, declined or
  // expired) has no ledger line yet, so the question says which line it means.
  const txn = p.row.transaction_ids?.[0] ?? null;
  const about =
    txn === null
      ? `About "${p.line.title}${p.line.amount ? `, ${p.line.amount}` : ''}" on ${formatDate(p.line.day, p.thisYear)}: `
      : '';

  const send = async () => {
    // Checked here too: the "About …" part alone isn't a question.
    if (text.trim() === '') {
      setError('Write your question first.');
      return;
    }
    setBusy(true);
    setError('');
    const { error } = await supabase.rpc('ask_question', {
      p_message: about + text.trim(),
      p_transaction_id: txn,
    });
    setBusy(false);
    if (error) {
      setError(error.message);
      return;
    }
    setText('');
    setState('sent');
    p.onAsked();
  };

  if (state === 'sent')
    return (
      <p className="ask__sent" role="status">
        Sent! Dad will answer here, and you'll get a notice when he does.
      </p>
    );
  if (state === 'closed')
    return (
      <button
        type="button"
        className="btn btn--soft btn--small"
        onClick={() => setState('open')}
        disabled={view.viewing}
        aria-describedby={view.viewing ? 'viewing-banner' : undefined}
      >
        Something looks wrong?
      </button>
    );
  return (
    <div className="ask">
      <label className="ask__label" htmlFor={`${id}-q`}>
        What looks wrong? Dad will see this line with your question.
      </label>
      <textarea
        id={`${id}-q`}
        className="ask__text"
        rows={3}
        maxLength={1800}
        value={text}
        aria-describedby={error ? `${id}-err` : undefined}
        onChange={(e) => setText(e.target.value)}
      />
      {error && (
        <p id={`${id}-err`} className="ask__error" role="alert">
          {error}
        </p>
      )}
      <div className="confirm__buttons">
        <button type="button" className="btn btn--small" onClick={send} disabled={busy}>
          {busy ? 'Sending…' : 'Send to Dad'}
        </button>
        <button
          type="button"
          className="btn btn--soft btn--small"
          onClick={() => {
            setState('closed');
            setError('');
          }}
          disabled={busy}
        >
          Cancel
        </button>
      </div>
    </div>
  );
}
