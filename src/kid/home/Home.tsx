// Home: what she has, what needs her, and what happened lately.
//
//   hero        total worth
//   banner      a matured GIC to choose for, and the newest unread notice ("Got it")
//   savings     with what's on hold and free to use, and today's rate
//   GICs        each one, with its locked rate and when it's ready
//   funds       her mix and all three funds' last market day, with sparklines
//   activity    the last 5 lines, and "See all"
//
// All wording is in docs/MESSAGES.md §7. One column on phones, two from 840 px.

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Explain } from '../../components/Glossary';
import { daysBetween, formatDate, formatPct, formatRate, termLabel } from '../../lib/format';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { ActivityList } from './ActivityList';
import { Sparkline } from './Sparkline';
import { isWaiting, useHome, type Cents, type Fund, type Gic, type HomeData } from './useHome';
import './Home.css';

export default function Home() {
  const { profile, summary } = useKid();
  const { data, error, reload } = useHome(profile.accountId);

  if (error && !data)
    return (
      <div className="home">
        <section className="card">
          <p>Big Bucks couldn't load your money just now. Please try again in a minute.</p>
          <button type="button" className="btn" onClick={reload}>
            Try again
          </button>
        </section>
      </div>
    );
  if (!data) return <div className="home" aria-busy="true" aria-label="Loading your money" />;

  const refreshAll = () => {
    reload();
    summary.reload();
  };
  const year = Number(data.today.slice(0, 4));

  return (
    <div className="home">
      <section className="hero" aria-labelledby="h-total">
        <h1 id="h-total" className="hero__label">
          Total worth <Explain term="Total worth" light />
        </h1>
        <Money
          cents={data.balances.total_worth_cents}
          updating={data.updating}
          className="hero__amount"
        />
        <p className="hero__tag">Watch your bucks grow.</p>
      </section>
      <Banner data={data} year={year} onChange={refreshAll} />
      <SavingsCard data={data} year={year} />
      <GicCard data={data} year={year} />
      <FundsCard data={data} year={year} />
      <section className="card home__activity" aria-labelledby="h-activity">
        <div className="card__head">
          <h2 id="h-activity" className="card__title">
            Recent activity
          </h2>
        </div>
        <ActivityList rows={data.activity} thisYear={year} />
        {data.activity.length > 0 && (
          <Link className="btn btn--soft" to="/kid/history">
            See all
          </Link>
        )}
      </section>
    </div>
  );
}

/** An amount, or "Updating…" while the nightly check is fixing something. */
function Money({
  cents,
  updating,
  className,
}: {
  cents: Cents;
  updating: boolean;
  className?: string;
}) {
  if (updating)
    return (
      <p className={`${className ?? ''} money--updating`} role="status">
        Updating…
        <span className="money__why">
          Your numbers are being double-checked. They'll be back soon.
        </span>
      </p>
    );
  return <p className={className}>{formatCents(cents)}</p>;
}

function OptionIcon({ colour, icon }: { colour: string; icon: string }) {
  return (
    <span className="opt-icon" style={{ background: colour }} aria-hidden="true">
      {icon}
    </span>
  );
}

// ---------------------------------------------------------------- banner

function Banner({ data, year, onChange }: { data: HomeData; year: number; onChange: () => void }) {
  const waiting = data.gics.filter(isWaiting);
  // A GIC's "ready" notice isn't repeated here: a waiting GIC has its own card,
  // and one already chosen for needs nothing. Newest notice first, one at a time.
  const notices = data.notices.filter((n) => n.type !== 'gic_maturity');
  const shown = notices.slice(0, 1);
  const [busy, setBusy] = useState<number | null>(null);

  if (waiting.length === 0 && shown.length === 0) return null;

  const gotIt = async (id: number) => {
    setBusy(id);
    await supabase.rpc('mark_notices_read', { p_ids: [id] });
    setBusy(null);
    onChange();
  };

  return (
    <section className="banner" aria-label="Things for you">
      {waiting.map((g) => (
        <div key={g.gic_id} className="banner__card banner__card--celebrate">
          <p className="banner__title">
            <span aria-hidden="true">🎉 </span>Your GIC grew!
          </p>
          <p>
            Your {termLabel(g.term_months)} GIC earned {formatCents(g.interest_at_maturity_cents)},
            so you now have <strong>{formatCents(g.balance_cents)}</strong>. Choose what happens
            next by <strong>{formatDate(g.choose_by!, year)}</strong>.
          </p>
          <Link className="btn btn--gold" to={`/kid/gic/${g.gic_id}`}>
            Choose what's next
          </Link>
        </div>
      ))}
      {shown.map((n) => (
        <div key={n.id} className="banner__card">
          <p className="banner__title">{n.title}</p>
          {n.body && <p>{n.body}</p>}
          <button
            type="button"
            className="btn btn--soft"
            onClick={() => gotIt(n.id)}
            disabled={busy === n.id}
          >
            Got it
          </button>
        </div>
      ))}
      {notices.length > shown.length && (
        <Link className="banner__more" to="/kid/notices">
          {notices.length - shown.length === 1
            ? '1 more new notice'
            : `${notices.length - shown.length} more new notices`}
        </Link>
      )}
    </section>
  );
}

// ---------------------------------------------------------------- savings

function SavingsCard({ data, year }: { data: HomeData; year: number }) {
  const b = data.balances;
  const rate = data.rates.find((r) => r.vehicle === 'savings');
  const held = Number(b.held_cents) > 0;
  return (
    <section className="card home__savings" aria-labelledby="h-savings">
      <div className="card__head">
        <OptionIcon colour="var(--opt-savings)" icon="🐷" />
        <h2 id="h-savings" className="card__title">
          Savings <Explain term="Savings account" />
        </h2>
      </div>
      <Money cents={b.savings_cents} updating={data.updating} className="card__amount" />
      {held && !data.updating && (
        <dl className="pairs">
          <div>
            <dt>
              On hold <Explain term="On hold" />
            </dt>
            <dd>{formatCents(b.held_cents)}</dd>
          </div>
          <div>
            <dt>
              Free to use <Explain term="Available" />
            </dt>
            <dd>{formatCents(b.available_cents)}</dd>
          </div>
        </dl>
      )}
      {rate && (
        <p className="card__note">
          Earning <strong>{formatRate(rate.rate)}</strong> a year <Explain term="Interest rate" />
          {rate.next_rate && rate.next_effective && (
            <>
              <br />
              Changing to {formatRate(rate.next_rate)} on {formatDate(rate.next_effective, year)}
            </>
          )}
        </p>
      )}
    </section>
  );
}

// ---------------------------------------------------------------- GICs

function GicCard({ data, year }: { data: HomeData; year: number }) {
  return (
    <section className="card home__gics" aria-labelledby="h-gics">
      <div className="card__head">
        <OptionIcon colour="var(--opt-gic)" icon="🔒" />
        <h2 id="h-gics" className="card__title">
          GICs <Explain term="GIC" />
        </h2>
      </div>
      <Money cents={data.balances.gic_cents} updating={data.updating} className="card__amount" />
      {data.gics.length === 0 ? (
        <p className="muted">
          No GICs right now. A GIC locks your money away for a while and pays more interest than
          savings.
        </p>
      ) : (
        <ul className="gics">
          {data.gics.map((g) => (
            <GicRow key={g.gic_id} g={g} today={data.today} year={year} updating={data.updating} />
          ))}
        </ul>
      )}
    </section>
  );
}

function GicRow({
  g,
  today,
  year,
  updating,
}: {
  g: Gic;
  today: string;
  year: number;
  updating: boolean;
}) {
  const waiting = isWaiting(g);
  const total = daysBetween(g.start_date, g.maturity_date);
  const done = Math.min(Math.max(daysBetween(g.start_date, today), 0), total);
  const left = total - done;
  const pct = total > 0 ? Math.round((done / total) * 100) : 100;
  return (
    <li className="gic">
      <div className="gic__top">
        <span className="gic__amount">{updating ? 'Updating…' : formatCents(g.balance_cents)}</span>
        <span className="gic__terms">
          {termLabel(g.term_months)} at {formatRate(g.rate)}
        </span>
      </div>
      {waiting ? (
        <div className="gic__ready">
          <span>
            <span aria-hidden="true">🎉 </span>Ready now!
          </span>
          <Link className="btn btn--small" to={`/kid/gic/${g.gic_id}`}>
            Choose
          </Link>
        </div>
      ) : (
        <>
          <div
            className="progress"
            role="progressbar"
            aria-label={`${termLabel(g.term_months)} GIC`}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={pct}
            aria-valuetext={`${left} days to go`}
          >
            <span style={{ width: `${pct}%` }} />
          </div>
          <p className="gic__when">
            Ready {formatDate(g.maturity_date, year)} · {left === 1 ? '1 day' : `${left} days`} to
            go
            <br />
            Earns {formatCents(g.interest_at_maturity_cents)} by then
          </p>
        </>
      )}
    </li>
  );
}

// ---------------------------------------------------------------- funds

function FundsCard({ data, year }: { data: HomeData; year: number }) {
  const owned = data.funds.filter((f) => f.owned && f.mix_pct !== null);
  const lastDay = data.funds.map((f) => f.latest_close_date).find(Boolean);
  return (
    <section className="card home__funds" aria-labelledby="h-funds">
      <div className="card__head">
        <OptionIcon colour="var(--bb-purple)" icon="📈" />
        <h2 id="h-funds" className="card__title">
          Stock funds <Explain term="Stock fund" />
        </h2>
      </div>
      <Money
        cents={data.balances.stock_value_cents}
        updating={data.updating}
        className="card__amount"
      />
      {owned.length > 0 && !data.updating && (
        <div className="mix">
          <p className="mix__label">
            Your mix <Explain term="Diversification" />
          </p>
          <div className="mix__bar" aria-hidden="true">
            {owned.map((f) => (
              <span key={f.fund_id} style={{ width: `${f.mix_pct}%`, background: f.colour }} />
            ))}
          </div>
          <ul className="mix__legend">
            {owned.map((f) => (
              <li key={f.fund_id}>
                <span className="dot" style={{ background: f.colour }} aria-hidden="true" />
                {f.name} {f.mix_pct}%
              </li>
            ))}
          </ul>
        </div>
      )}
      {lastDay && (
        <p className="funds__day">
          Last market day, {formatDate(lastDay, year)} <Explain term="Daily change" />
        </p>
      )}
      <ul className="funds">
        {data.funds.map((f) => (
          <FundRow key={f.fund_id} f={f} updating={data.updating} />
        ))}
      </ul>
    </section>
  );
}

function FundRow({ f, updating }: { f: Fund; updating: boolean }) {
  const pct = f.day_change_pct === null ? null : String(f.day_change_pct);
  const dir =
    pct === null ? null : pct.startsWith('-') ? 'down' : /^0(\.0+)?$/.test(pct) ? 'flat' : 'up';
  return (
    <li className="fund">
      <span className="dot dot--big" style={{ background: f.colour }} aria-hidden="true" />
      <span className="fund__text">
        <span className="fund__name">{f.name}</span>
        <span className="fund__mine">
          {!f.owned
            ? "You don't own any yet"
            : updating
              ? 'Updating…'
              : `Yours: ${formatCents(f.value_cents)}`}
        </span>
      </span>
      {dir && pct !== null && (
        <span className={`move move--${dir}`}>
          {dir === 'up' && (
            <>
              <span aria-hidden="true">▲ </span>Up {formatPct(pct)}
            </>
          )}
          {dir === 'down' && (
            <>
              <span aria-hidden="true">▼ </span>Down {formatPct(pct)}
            </>
          )}
          {dir === 'flat' && (
            <>
              <span aria-hidden="true">● </span>No change
            </>
          )}
        </span>
      )}
      <Sparkline points={f.spark} colour={f.colour} />
    </li>
  );
}
