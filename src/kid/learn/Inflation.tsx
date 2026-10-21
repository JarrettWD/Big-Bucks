// The inflation view (stage 11): "What will it buy?" on Home. When she turns it on (remembered
// on this device only, like a graph range), each option card gets one line about what its
// money will buy, worked out by the database (kid_inflation). Never in basic mode.

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { Explain } from '../../components/Glossary';
import { useKid } from '../KidShell';
import { kidRpc } from '../kidView';
import { fundInflation, gicInflation, savingsInflation, TEXT } from './learnText';
import './Learn.css';

export interface InflationData {
  on: boolean;
  inflation_rate: string;
  savings: {
    now_cents: number;
    savings_rate: string;
    in_a_year_cents: number;
    buys_like_cents: number;
  };
  gics: {
    gic_id: number;
    at_maturity_cents: number;
    buys_like_cents: number;
    maturity_date: string;
  }[];
  funds: { fund: string; name: string; year_change_pct: string | null }[];
}

const KEY = 'bb:what-will-it-buy';
const Ctx = createContext<{ data: InflationData | null; year: number }>({ data: null, year: 0 });

function remembered(): boolean {
  try {
    return localStorage.getItem(KEY) === 'on';
  } catch {
    return false;
  }
}

/** Is the inflation view available on this screen? (Its switch is on, and she's in detailed mode.) */
// eslint-disable-next-line react-refresh/only-export-components
export function useInflationAvailable(): boolean {
  const { summary } = useKid();
  return Boolean(summary.features.inflation) && summary.viewMode === 'detailed';
}

/** Wraps Home: the toggle's state and, while it's on, the database's figures. */
export function InflationProvider({
  year,
  children,
}: {
  year: number;
  children: (toggle: ReactNode) => ReactNode;
}) {
  const { view } = useKid();
  const available = useInflationAvailable();
  const [on, setOn] = useState(remembered);
  const [data, setData] = useState<InflationData | null>(null);

  useEffect(() => {
    if (!available || !on) return;
    let live = true;
    void kidRpc<InflationData>(view, 'kid_inflation', { p_account_id: view.accountId }).then(
      ({ data: d }) => {
        if (live && d?.on) setData(d);
      },
    );
    return () => {
      live = false;
    };
  }, [available, on, view]);

  const flip = () => {
    const next = !on;
    setOn(next);
    try {
      localStorage.setItem(KEY, next ? 'on' : 'off');
    } catch {
      // a private window: it just isn't remembered
    }
  };

  const toggle = available ? (
    <button type="button" className="infl__toggle" aria-pressed={on} onClick={flip}>
      {TEXT.whatBuy}
    </button>
  ) : null;

  return (
    <Ctx.Provider value={{ data: available && on ? data : null, year }}>
      {children(toggle)}
    </Ctx.Provider>
  );
}

function Line({ children }: { children: ReactNode }) {
  return (
    <p className="infl__line">
      <span aria-hidden="true">💡 </span>
      {children}
    </p>
  );
}

export function SavingsInflation() {
  const { data } = useContext(Ctx);
  if (!data) return null;
  return (
    <Line>
      {savingsInflation(data.savings, data.inflation_rate)} <Explain term="Inflation" />
    </Line>
  );
}

export function GicInflation({ gicId }: { gicId: number }) {
  const { data, year } = useContext(Ctx);
  const g = data?.gics.find((x) => x.gic_id === gicId);
  if (!data || !g) return null;
  return (
    <Line>
      {gicInflation(g, year)} <Explain term="Matures" />
    </Line>
  );
}

export function FundInflation({ fundId }: { fundId: string }) {
  const { data } = useContext(Ctx);
  const f = data?.funds.find((x) => x.fund === fundId);
  if (!data || !f) return null;
  return <Line>{fundInflation(f, data.inflation_rate)}</Line>;
}

/** Under her total: the gentle closing note. */
export function TotalInflation() {
  const { data } = useContext(Ctx);
  if (!data) return null;
  return <p className="infl__total">{TEXT.inflationNote}</p>;
}
