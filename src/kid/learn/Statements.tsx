// Her monthly statements (stage 11): where her money started, what came in and went out, what
// it earned, and where it ended. Every figure is the database's (kid_statement), from the
// ledger, and adds up exactly; a month shows once it's final (it's over and its nightly jobs
// are done). Basic mode shows the simple form. "Print or save as PDF" uses the browser's own
// print. Wording: MESSAGES §14. "View as" reads the same.

import { useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import { formatCents } from '../../lib/money';
import { useKid } from '../KidShell';
import { kidRpc } from '../kidView';
import { interestNote, monthName, readyOn, startLine, TEXT } from './learnText';
import '../home/Home.css';
import './Learn.css';

interface Month {
  month: string;
  ready: boolean;
  ready_on: string;
}
type Cents = number | string;
interface Statement {
  on: boolean;
  month: string;
  ready: boolean;
  ready_on?: string;
  balanced?: boolean;
  from?: string;
  to?: string;
  opened_this_month?: boolean;
  start_cents?: Cents;
  money_in_cents?: Cents;
  money_out_cents?: Cents;
  interest_cents?: Cents;
  dividends_cents?: Cents;
  fund_gains_cents?: Cents;
  fixes_cents?: Cents;
  end_cents?: Cents;
  funds?: {
    fund: string;
    name: string;
    start_cents: Cents;
    end_cents: Cents;
    paid_cents: Cents;
    got_cents: Cents;
  }[];
}

export default function Statements() {
  const { view, summary } = useKid();
  const [months, setMonths] = useState<Month[] | null>(null);
  const [picked, setPicked] = useState<string | null>(null);
  const [st, setSt] = useState<Statement | null>(null);

  useEffect(() => {
    let live = true;
    void kidRpc<{ on: boolean; months?: Month[] }>(view, 'kid_statement_months', {
      p_account_id: view.accountId,
    }).then(({ data }) => {
      if (!live) return;
      const list = data?.months ?? [];
      setMonths(list);
      // The newest ready month, else the newest.
      const ready = [...list].reverse().find((m) => m.ready);
      setPicked((ready ?? list[list.length - 1])?.month ?? null);
    });
    return () => {
      live = false;
    };
  }, [view]);

  useEffect(() => {
    if (!picked) return;
    let live = true;
    void kidRpc<Statement>(view, 'kid_statement', {
      p_account_id: view.accountId,
      p_month: picked,
    }).then(({ data }) => {
      if (live) setSt(data);
    });
    return () => {
      live = false;
    };
  }, [view, picked]);

  if (!summary.loading && !summary.features.statements) return <Navigate to={view.base} replace />;
  if (!months)
    return <div className="stmt" aria-busy="true" aria-label="Loading your statements" />;
  const year = Number((months[months.length - 1]?.month ?? '2026').slice(0, 4));
  const basic = summary.viewMode === 'basic';

  return (
    <div className="stmt">
      <h1 className="stmt__title">{TEXT.statementsTitle}</h1>
      <p className="muted">{TEXT.statementsIntro}</p>
      {months.length === 0 ? (
        <p className="muted">{TEXT.none}</p>
      ) : (
        <div className="stmt__months" role="group" aria-label="Month">
          {months.map((m) => (
            <button
              key={m.month}
              type="button"
              className="btn btn--soft btn--small stmt__month"
              aria-pressed={picked === m.month}
              onClick={() => setPicked(m.month)}
            >
              {monthName(m.month)}
            </button>
          ))}
        </div>
      )}
      {st && picked && st.month === picked && (
        <section className="card" aria-labelledby="h-stmt">
          <h2 id="h-stmt" className="card__title">
            {monthName(picked)}
          </h2>
          {!st.ready ? (
            <p className="muted">{readyOn(picked, st.ready_on!, year)}</p>
          ) : st.balanced === false ? (
            <p className="muted">{TEXT.checking}</p>
          ) : (
            <>
              <StatementLines st={st} basic={basic} year={year} />
              <p className="muted">{interestNote(picked)}</p>
            </>
          )}
        </section>
      )}
      {st?.ready && st.balanced !== false && (
        <button type="button" className="btn btn--soft stmt__print" onClick={() => window.print()}>
          {TEXT.print}
        </button>
      )}
    </div>
  );
}

function StatementLines({ st, basic, year }: { st: Statement; basic: boolean; year: number }) {
  const n = (c: Cents | undefined) => Number(c ?? 0);
  const earned =
    n(st.interest_cents) + n(st.dividends_cents) + n(st.fund_gains_cents) + n(st.fixes_cents);
  const signed = (c: number) => (c < 0 ? `−${formatCents(-c)}` : formatCents(c));
  const rows: [string, string, boolean?][] = [
    [startLine(st.from!, Boolean(st.opened_this_month), year), formatCents(st.start_cents!)],
  ];
  rows.push([TEXT.moneyIn, `+${formatCents(st.money_in_cents!)}`]);
  rows.push([TEXT.moneyOut, `−${formatCents(st.money_out_cents!)}`]);
  if (basic) rows.push([TEXT.earned, earned >= 0 ? `+${formatCents(earned)}` : signed(earned)]);
  else {
    rows.push([TEXT.interest, `+${formatCents(st.interest_cents!)}`]);
    rows.push([TEXT.dividends, `+${formatCents(st.dividends_cents!)}`]);
    rows.push([
      TEXT.fundGains,
      n(st.fund_gains_cents) >= 0
        ? `+${formatCents(st.fund_gains_cents!)}`
        : signed(n(st.fund_gains_cents)),
    ]);
    if (n(st.fixes_cents) !== 0)
      rows.push([
        TEXT.fixes,
        n(st.fixes_cents) > 0 ? `+${formatCents(st.fixes_cents!)}` : signed(n(st.fixes_cents)),
      ]);
  }
  rows.push([TEXT.end, formatCents(st.end_cents!), true]);
  return (
    <dl className="stmt__lines">
      {rows.map(([label, value, total]) => (
        <div key={label} className={total ? 'stmt__line stmt__line--total' : 'stmt__line'}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}
