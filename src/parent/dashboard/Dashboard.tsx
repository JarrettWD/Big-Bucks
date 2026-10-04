// Dad's dashboard: what needs him first (waiting requests, requests running out of
// time, alerts), then the girls' figures, what's coming due and what's happened.
// Everything comes from parent_dashboard(); the screen only lays it out.

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../auth/AuthProvider';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import {
  TEXT,
  gicText,
  moveText,
  noticeReadText,
  type DashAlert,
  type DashExpiring,
  type Dashboard as Dash,
} from './dashboardText';
import './Dashboard.css';

async function fetchDashboard(): Promise<{ data: Dash | null; error: string | null }> {
  const { data, error } = await supabase.rpc('parent_dashboard');
  return error ? { data: null, error: error.message } : { data: data as Dash, error: null };
}

export default function Dashboard() {
  const [dash, setDash] = useState<Dash | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const doneRef = useRef<HTMLParagraphElement>(null);
  const { profile } = useAuth();

  const apply = useCallback((r: { data: Dash | null; error: string | null }) => {
    setError(r.error);
    if (r.data) setDash(r.data);
    return r.data;
  }, []);
  const reload = useCallback(async () => apply(await fetchDashboard()), [apply]);

  useEffect(() => {
    let alive = true;
    fetchDashboard().then((r) => {
      if (alive) apply(r);
    });
    const onShow = () => {
      if (document.visibilityState === 'visible') void reload();
    };
    document.addEventListener('visibilitychange', onShow);
    const timer = window.setInterval(() => void reload(), 60_000);
    return () => {
      alive = false;
      document.removeEventListener('visibilitychange', onShow);
      window.clearInterval(timer);
    };
  }, [apply, reload]);

  useEffect(() => {
    if (done) doneRef.current?.focus();
  }, [done]);

  if (error && !dash)
    return (
      <section className="dash">
        <p className="dash__error" role="alert">
          {TEXT.loadError(error)}
        </p>
        <button type="button" className="dash__btn" onClick={() => void reload()}>
          {TEXT.retry}
        </button>
      </section>
    );
  if (!dash) return <p className="dash__muted">Loading…</p>;

  const waiting = dash.waiting.requests + dash.waiting.questions;
  const real = dash.kids.filter((k) => !k.is_test);
  const test = dash.kids.filter((k) => k.is_test);

  return (
    <section className="dash" aria-labelledby="dash-title">
      <h1 id="dash-title" className="dash__title">
        {TEXT.title}
      </h1>
      {done && (
        <p className="dash__done" role="status" tabIndex={-1} ref={doneRef}>
          {done}
        </p>
      )}

      <div className="dash__grid">
        <section className="dash__card dash__card--needs" aria-labelledby="dash-needs">
          <h2 id="dash-needs">{TEXT.needsYou}</h2>
          <p className="dash__big">{TEXT.waiting(waiting)}</p>
          {waiting > 0 && (
            <>
              <p className="dash__muted">
                {TEXT.waitingDetail(dash.waiting.requests, dash.waiting.questions)}
              </p>
              <Link className="dash__btn" to="/parent/approvals">
                {TEXT.openApprovals}
              </Link>
            </>
          )}
          {(dash.expiring.length > 0 || dash.expiring_test.length > 0) && (
            <div className="dash__expiring" aria-labelledby="dash-expiring">
              <h3 id="dash-expiring">⏳ {TEXT.expiring}</h3>
              <ExpiringList items={dash.expiring} />
              {dash.expiring_test.length > 0 && (
                <details className="dash__fold">
                  <summary>{TEXT.testAccounts(dash.expiring_test.length)}</summary>
                  <ExpiringList items={dash.expiring_test} />
                </details>
              )}
            </div>
          )}
          {dash.holidays.map((h) => (
            <p key={h.market} className="dash__warn">
              📅 {h.text}
            </p>
          ))}
        </section>

        <section className="dash__card" aria-labelledby="dash-alerts">
          <h2 id="dash-alerts">{TEXT.alerts}</h2>
          {dash.alerts.length === 0 && <p className="dash__muted">{TEXT.noAlerts}</p>}
          <AlertList
            items={dash.alerts}
            onDone={async () => {
              const fresh = await reload();
              setDone(TEXT.ackDone(profile?.displayName ?? 'you', fresh?.now ?? ''));
            }}
          />
          {dash.alerts_quiet.length > 0 && (
            <details className="dash__fold">
              <summary>{TEXT.testAccounts(dash.alerts_quiet.length)}</summary>
              <AlertList
                items={dash.alerts_quiet}
                onDone={async () => {
                  const fresh = await reload();
                  setDone(TEXT.ackDone(profile?.displayName ?? 'you', fresh?.now ?? ''));
                }}
              />
            </details>
          )}
        </section>

        <section className="dash__card" aria-labelledby="dash-kids">
          <h2 id="dash-kids">{TEXT.kids}</h2>
          <ul className="dash__kids">
            {real.map((k) => (
              <li key={k.account_id}>
                <span className="dash__kid">{k.kid}</span>
                <span className="dash__worth">{formatCents(k.total_worth_cents)}</span>
                <dl className="dash__facts">
                  <div>
                    <dt>{TEXT.savings}</dt>
                    <dd>{formatCents(k.savings_cents)}</dd>
                  </div>
                  <div>
                    <dt>{TEXT.gics}</dt>
                    <dd>{formatCents(k.gic_cents)}</dd>
                  </div>
                  <div>
                    <dt>{TEXT.funds}</dt>
                    <dd>{formatCents(k.stock_value_cents)}</dd>
                  </div>
                  <div>
                    <dt>{TEXT.putIn}</dt>
                    <dd>{formatCents(k.net_deposits_cents)}</dd>
                  </div>
                </dl>
              </li>
            ))}
          </ul>
          <div className="dash__owe">
            <span>{TEXT.owe}</span>
            <strong>{formatCents(dash.liability_cents)}</strong>
          </div>
          <p className="dash__muted">{TEXT.oweNote}</p>
          {test.length > 0 && (
            <>
              <h3>{TEXT.testList}</h3>
              <ul className="dash__plain">
                {test.map((k) => (
                  <li key={k.account_id}>
                    <span>
                      {k.kid} <span className="dash__test">Test</span>
                    </span>
                    <span>{formatCents(k.total_worth_cents)}</span>
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>

        <section className="dash__card" aria-labelledby="dash-gics">
          <h2 id="dash-gics">{TEXT.gicsTitle}</h2>
          {dash.maturities.length === 0 ? (
            <p className="dash__muted">{TEXT.noGics}</p>
          ) : (
            <ul className="dash__plain dash__stack">
              {dash.maturities.map((g) => (
                <li key={g.gic_id} className={g.waiting ? 'dash__soon' : undefined}>
                  <span className="dash__who">
                    {g.kid}
                    {g.is_test && <span className="dash__test">Test</span>}
                  </span>
                  <span>{gicText(g)}</span>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="dash__card" aria-labelledby="dash-moves">
          <h2 id="dash-moves">{TEXT.movesTitle}</h2>
          {dash.moves.length === 0 ? (
            <p className="dash__muted">{TEXT.noMoves}</p>
          ) : (
            <ul className="dash__plain dash__stack">
              {dash.moves.map((m) => (
                <li key={m.request_id}>
                  <span className="dash__who">
                    {m.kid}
                    {m.is_test && <span className="dash__test">Test</span>}
                  </span>
                  <span>{moveText(m)}</span>
                  <span className="dash__muted">{m.when}</span>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="dash__card" aria-labelledby="dash-notices">
          <h2 id="dash-notices">{TEXT.noticesTitle}</h2>
          {dash.notices.length === 0 ? (
            <p className="dash__muted">{TEXT.noNotices}</p>
          ) : (
            <ul className="dash__plain dash__stack">
              {dash.notices.map((n) => (
                <li key={n.title + n.sent}>
                  <span className="dash__notice">{n.title}</span>
                  <span className="dash__muted">{TEXT.sent(n.sent)}</span>
                  <ul className="dash__reads">
                    {n.kids.map((k) => (
                      <li key={k.kid} className={k.read ? 'is-read' : 'is-unread'}>
                        <span aria-hidden="true">{k.read ? '✓ ' : '○ '}</span>
                        {k.kid}
                        {k.is_test && <span className="dash__test">Test</span>}: {noticeReadText(k)}
                      </li>
                    ))}
                  </ul>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
      <p className="dash__muted dash__updated">{TEXT.updated(dash.now)}</p>
    </section>
  );
}

function ExpiringList({ items }: { items: DashExpiring[] }) {
  return (
    <ul className="dash__plain dash__stack">
      {items.map((e) => (
        <li key={e.request_id} className={e.seconds_left <= 0 ? 'dash__late' : 'dash__soon'}>
          <Link to="/parent/approvals">{e.text}</Link>
        </li>
      ))}
    </ul>
  );
}

function AlertList({ items, onDone }: { items: DashAlert[]; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState<number | null>(null);
  return (
    <ul className="dash__plain dash__stack">
      {items.map((a) => (
        <li key={a.id} className="dash__alert">
          <span className="dash__who">{a.kid ?? 'Big Bucks'}</span>
          <span>{a.message}</span>
          <span className="dash__muted">Since {a.since}</span>
          {open === a.id ? (
            <AckConfirm id={a.id} onCancel={() => setOpen(null)} onDone={onDone} />
          ) : (
            <button
              type="button"
              className="dash__btn dash__btn--quiet"
              onClick={() => setOpen(a.id)}
            >
              {TEXT.acknowledge}
            </button>
          )}
        </li>
      ))}
    </ul>
  );
}

function AckConfirm({
  id,
  onCancel,
  onDone,
}: {
  id: number;
  onCancel: () => void;
  onDone: () => Promise<void>;
}) {
  const hid = useId();
  const headingRef = useRef<HTMLHeadingElement>(null);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  useEffect(() => {
    headingRef.current?.focus();
  }, []);
  const go = async () => {
    setSaving(true);
    const { error } = await supabase.rpc('acknowledge_alert', { p_alert_id: id });
    if (error) {
      setSaving(false);
      setFailed(error.message);
      return;
    }
    await onDone();
  };
  return (
    <div className="dash__confirm" role="group" aria-labelledby={hid}>
      <h4 id={hid} tabIndex={-1} ref={headingRef}>
        {TEXT.ackHeading}
      </h4>
      <p>{TEXT.ackLine}</p>
      {failed && (
        <p className="dash__error" role="alert">
          {failed}
        </p>
      )}
      <div className="dash__actions">
        <button type="button" className="dash__btn" disabled={saving} onClick={() => void go()}>
          {saving ? TEXT.saving : TEXT.ackYes}
        </button>
        <button
          type="button"
          className="dash__btn dash__btn--quiet"
          disabled={saving}
          onClick={onCancel}
        >
          {TEXT.back}
        </button>
      </div>
    </div>
  );
}
