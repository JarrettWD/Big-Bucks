// "See all": her whole history, newest first, 30 lines at a time, and her
// questions to Dad with his answers (the thread stays in her history).

import { useCallback, useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useKid } from './KidShell';
import { kidRpc } from './kidView';
import { ActivityList, QuestionList } from './home/ActivityList';
import { useQuestions } from './useQuestions';
import type { ActivityRow } from './home/activityText';
import './home/Home.css';

const PAGE = 30;

export default function History() {
  const { view } = useKid();
  const [rows, setRows] = useState<ActivityRow[]>([]);
  const [more, setMore] = useState(true);
  const [busy, setBusy] = useState(false);
  const [year, setYear] = useState(0);
  const shared = useQuestions(view);
  const { questions } = shared;
  const { hash } = useLocation();

  // From a "Dad answered" notice: go straight to her questions.
  useEffect(() => {
    if (hash === '#questions' && questions.length > 0)
      document.getElementById('questions')?.scrollIntoView();
  }, [hash, questions.length]);

  const loadMore = useCallback(
    async (after: ActivityRow) => {
      setBusy(true);
      const { data } = await kidRpc(view, 'my_activity', {
        p_account_id: view.accountId,
        p_limit: PAGE,
        p_before_at: after.at,
        p_before_key: after.item_key,
      });
      const page = (data ?? []) as ActivityRow[];
      setRows((r) => [...r, ...page]);
      setMore(page.length === PAGE);
      setBusy(false);
    },
    [view],
  );

  useEffect(() => {
    let alive = true;
    Promise.all([
      kidRpc(view, 'app_today'),
      kidRpc(view, 'my_activity', { p_account_id: view.accountId, p_limit: PAGE }),
    ]).then(([t, a]) => {
      if (!alive) return;
      const page = (a.data ?? []) as ActivityRow[];
      setYear(Number(String(t.data ?? '').slice(0, 4)));
      setRows(page);
      setMore(page.length === PAGE);
    });
    return () => {
      alive = false;
    };
  }, [view]);

  return (
    <div className="home home--single">
      <section className="card" aria-labelledby="h-history">
        <h1 id="h-history" className="card__title">
          Your history
        </h1>
        {year > 0 && <ActivityList rows={rows} thisYear={year} shared={shared} />}
        {more && rows.length > 0 && (
          <button
            type="button"
            className="btn btn--soft"
            onClick={() => loadMore(rows[rows.length - 1])}
            disabled={busy}
          >
            {busy ? 'Loading…' : 'Show more'}
          </button>
        )}
        <Link className="btn" to={view.base}>
          Back to Home
        </Link>
      </section>

      <section className="card" id="questions" aria-labelledby="h-questions">
        <h2 id="h-questions" className="card__title">
          Your questions
        </h2>
        {questions.length === 0 ? (
          <p className="muted">
            No questions yet. If a line ever looks wrong, tap it and choose "Something looks
            wrong?".
          </p>
        ) : (
          year > 0 && <QuestionList questions={questions} thisYear={year} />
        )}
      </section>
    </div>
  );
}
