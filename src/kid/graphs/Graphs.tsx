// The Graphs tab: six graphs, one at a time, picked with tabs at the top
// (Dad's decision, 2026-10-03). Each graph has one sentence on what it shows,
// a ? for its key words, names beside every colour (never colour alone), and
// "Show as a table" so every number can be read without seeing the graph.
//
//   graph_ranges(account)                 today, and where each range starts
//   daily_balances(account, from, to)     Total worth over time
//   growth_by_option(account, from, to)   Growth by option ($ or %)
//   money_in_vs_earned(account)           Money in vs money earned
//   my_mix(account)                       My mix today
//   gic_ladder(account)                   GIC ladder
//   fund_chart(account, fund, from)       Stock fund detail ($ or %)
//
// Every figure and date comes from the database. This file is loaded only when
// the Graphs tab opens, so Recharts never slows the other screens.
// Wording: docs/MESSAGES.md §10.

import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import {
  Area,
  AreaChart,
  CartesianGrid,
  ComposedChart,
  Cell,
  Line,
  LineChart,
  Pie,
  PieChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { Explain } from '../../components/Glossary';
import { Updating } from '../../components/Updating';
import { INK, MOVE } from '../../lib/colours';
import { daysBetween, formatDate, formatRate, termLabel } from '../../lib/format';
import { formatCents, toCents, type Cents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { kidRpc, useKidView } from '../kidView';
import {
  GRAPH_TABS,
  WORTH_RANGES,
  axisDollars,
  formatPrice,
  fundFrom,
  fundRanges,
  fundRows,
  growthRows,
  ladderWidth,
  lastPoints,
  optionList,
  plot,
  signedPct,
  worthFrom,
  worthRows,
  type DailyBalance,
  type FundChart,
  type FundInfo,
  type FundRange,
  type FundRow,
  type GraphTab,
  type GrowthPoint,
  type LadderRow,
  type MixRow,
  type MoneyInRow,
  type OptionInfo,
  type Ranges,
  type WorthRange,
} from './graphData';
import * as T from './graphText';
import '../home/Home.css';
import './Graphs.css';

const CHART_HEIGHT = 280;
const SAVINGS_OUTLINE = INK.outline;

// ---------------------------------------------------------------- data loading

/** Calls a read function (through parent_view when Dad is viewing); reloads when its arguments change. */
function useRpc<R>(fn: string, args: Record<string, unknown> | null) {
  const view = useKidView();
  const [state, setState] = useState<{ key: string; data: R | null; error: boolean }>({
    key: '',
    data: null,
    error: false,
  });
  const [tick, setTick] = useState(0);
  const key = args ? `${fn}|${JSON.stringify(args)}|${tick}` : '';
  useEffect(() => {
    if (!args) return;
    let alive = true;
    kidRpc<R>(view, fn, args).then(({ data, error }) => {
      if (alive) setState({ key, data: error ? null : (data as R), error: !!error });
    });
    return () => {
      alive = false;
    };
    // `key` covers fn and args.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const retry = useCallback(() => setTick((t) => t + 1), []);
  const current = state.key === key;
  return {
    data: current ? state.data : null,
    error: current && state.error,
    loading: !current,
    retry,
  };
}

interface Base {
  accountId: string;
  ranges: Ranges;
  options: OptionInfo[];
  funds: FundInfo[];
  year: number;
}

export default function Graphs() {
  const { view, summary } = useKid();
  const [params, setParams] = useSearchParams();
  const asked = params.get('g') as GraphTab | null;
  const tab: GraphTab = asked && GRAPH_TABS.includes(asked) ? asked : 'worth';
  const accountId = view.accountId;
  const ranges = useRpc<Ranges>('graph_ranges', accountId ? { p_account_id: accountId } : null);
  const [funds, setFunds] = useState<FundInfo[] | null>(null);
  const [fundsError, setFundsError] = useState(false);
  const tabRefs = useRef<Record<string, HTMLButtonElement | null>>({});
  const id = useId();

  useEffect(() => {
    let alive = true;
    supabase
      .from('funds')
      .select('id, name, colour, sort_order')
      .order('sort_order')
      .then(({ data, error }) => {
        if (!alive) return;
        if (error) setFundsError(true);
        else setFunds((data ?? []) as FundInfo[]);
      });
    return () => {
      alive = false;
    };
  }, []);

  const pick = (t: GraphTab, focus = false) => {
    setParams(t === 'worth' ? {} : { g: t }, { replace: true });
    if (focus) tabRefs.current[t]?.focus();
  };
  const onTabKey = (e: React.KeyboardEvent) => {
    const i = GRAPH_TABS.indexOf(tab);
    const go: Record<string, number> = {
      ArrowRight: i + 1,
      ArrowLeft: i - 1,
      Home: 0,
      End: GRAPH_TABS.length - 1,
    };
    if (!(e.key in go)) return;
    e.preventDefault();
    pick(GRAPH_TABS[(go[e.key] + GRAPH_TABS.length) % GRAPH_TABS.length], true);
  };

  let body: ReactNode;
  if (summary.updating) body = <Updating updating>{null}</Updating>;
  else if (ranges.error || fundsError) body = <Failed retry={ranges.retry} />;
  else if (!accountId || !ranges.data || !funds)
    body = <p className="muted graph__loading">{T.LOADING}</p>;
  else {
    const base: Base = {
      accountId,
      ranges: ranges.data,
      options: optionList(funds),
      funds,
      year: Number(ranges.data.today.slice(0, 4)),
    };
    body = (
      <>
        {tab === 'worth' && <WorthGraph base={base} />}
        {tab === 'growth' && <GrowthGraph base={base} />}
        {tab === 'money' && <MoneyGraph base={base} />}
        {tab === 'mix' && <MixGraph base={base} />}
        {tab === 'gics' && <LadderGraph base={base} />}
        {tab === 'funds' && <FundGraph base={base} />}
      </>
    );
  }

  return (
    <div className="graphs">
      <h1 className="graphs__title">{T.TITLE}</h1>
      <div className="graphs__tabs" role="tablist" aria-label={T.TITLE} onKeyDown={onTabKey}>
        {GRAPH_TABS.map((t) => (
          <button
            key={t}
            ref={(el) => {
              tabRefs.current[t] = el;
            }}
            type="button"
            role="tab"
            id={`${id}-tab-${t}`}
            aria-selected={t === tab}
            aria-controls={`${id}-panel`}
            tabIndex={t === tab ? 0 : -1}
            className="graphs__tab"
            onClick={() => pick(t)}
          >
            {T.TAB_LABEL[t]}
          </button>
        ))}
      </div>
      <section
        className="card graph"
        role="tabpanel"
        id={`${id}-panel`}
        aria-labelledby={`${id}-tab-${tab}`}
      >
        <div className="graph__head">
          <h2 className="graph__title">{T.HEADING[tab]}</h2>
          <p className="muted">{T.WHAT[tab]}</p>
          <ul className="graph__terms" aria-label={T.WORDS}>
            {T.TERMS[tab].map((term) => (
              <li key={term}>
                {term}
                <Explain term={term} />
              </li>
            ))}
          </ul>
        </div>
        {body}
      </section>
    </div>
  );
}

// ---------------------------------------------------------------- shared pieces

function Failed({ retry }: { retry: () => void }) {
  return (
    <div className="graph__msg">
      <p>{T.LOAD_FAILED}</p>
      <button type="button" className="btn btn--soft" onClick={retry}>
        {T.TRY_AGAIN}
      </button>
    </div>
  );
}

/** Loading, failed or empty; otherwise the graph. */
function Loaded<R>({
  q,
  empty,
  children,
}: {
  q: { data: R | null; error: boolean; loading: boolean; retry: () => void };
  empty: (d: R) => boolean;
  children: (d: R) => ReactNode;
}) {
  if (q.error) return <Failed retry={q.retry} />;
  if (q.loading || q.data === null) return <p className="muted graph__loading">{T.LOADING}</p>;
  if (empty(q.data)) return <p className="graph__msg">{T.NOTHING_YET}</p>;
  return <>{children(q.data)}</>;
}

/** A row of buttons where one is chosen (ranges, $ / %, which fund). */
function Choice<K extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { key: K; short: string; long: string }[];
  value: K;
  onChange: (k: K) => void;
}) {
  return (
    <div className="choice" role="group" aria-label={label}>
      {options.map((o) => (
        <button
          key={o.key}
          type="button"
          className="choice__btn"
          aria-pressed={o.key === value}
          aria-label={o.short === o.long ? undefined : o.long}
          onClick={() => onChange(o.key)}
        >
          {o.short}
        </button>
      ))}
    </div>
  );
}

function RangeChoice<K extends WorthRange | FundRange>({
  ranges,
  value,
  onChange,
}: {
  ranges: K[];
  value: K;
  onChange: (k: K) => void;
}) {
  return (
    <Choice
      label={T.RANGE_GROUP}
      options={ranges.map((r) => ({ key: r, ...T.RANGE_LABEL[r] }))}
      value={value}
      onChange={onChange}
    />
  );
}

type Unit = 'pct' | 'cents';
function UnitChoice({ value, onChange }: { value: Unit; onChange: (u: Unit) => void }) {
  return (
    <Choice
      label={T.UNIT_GROUP}
      options={[
        { key: 'cents' as Unit, ...T.UNIT_DOLLARS },
        { key: 'pct' as Unit, ...T.UNIT_PERCENT },
      ]}
      value={value}
      onChange={onChange}
    />
  );
}

/** A small sample of a series' mark: a line (with its pattern) or a filled square. */
function Swatch({
  o,
  kind,
}: {
  o: { colour: string; dash?: string; key?: string };
  kind: 'line' | 'fill';
}) {
  const outline = o.key === 'savings';
  return (
    <svg className="swatch" width="28" height="14" viewBox="0 0 28 14" aria-hidden="true">
      {kind === 'fill' ? (
        <rect
          x="4"
          y="1"
          width="20"
          height="12"
          rx="3"
          fill={o.colour}
          stroke={outline ? SAVINGS_OUTLINE : o.colour}
          strokeWidth={outline ? 1.5 : 0}
        />
      ) : (
        <>
          {outline && (
            <line x1="1" y1="7" x2="27" y2="7" stroke={SAVINGS_OUTLINE} strokeWidth="5.5" />
          )}
          <line
            x1="1"
            y1="7"
            x2="27"
            y2="7"
            stroke={o.colour}
            strokeWidth="3"
            strokeDasharray={o.dash || undefined}
          />
        </>
      )}
    </svg>
  );
}

/** The key: each series named beside its mark, with a figure. */
function Key({ items }: { items: { o: OptionInfo; kind: 'line' | 'fill'; value?: string }[] }) {
  return (
    <ul className="key">
      {items.map(({ o, kind, value }) => (
        <li key={o.key} className="key__item">
          <Swatch o={o} kind={kind} />
          <span className="key__name">{o.name}</span>{' '}
          {value && <span className="key__value">{value}</span>}
        </li>
      ))}
    </ul>
  );
}

/** "Show as a table": the same numbers, readable without the graph. */
function TableToggle({ caption, children }: { caption: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <div className="graph__table">
      <button
        type="button"
        className="btn btn--soft btn--small"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen(!open)}
      >
        {open ? T.HIDE_TABLE : T.SHOW_TABLE}
      </button>
      {open && (
        <div id={id} className="gtable__wrap">
          <table className="gtable">
            <caption>{caption}</caption>
            {children}
          </table>
        </div>
      )}
    </div>
  );
}

function Cells({ cells }: { cells: { label: string; value: ReactNode }[] }) {
  return (
    <>
      {cells.map((c, i) =>
        i === 0 ? (
          <th key={i} scope="row" data-label={c.label}>
            {c.value}
          </th>
        ) : (
          <td key={i} data-label={c.label}>
            {c.value}
          </td>
        ),
      )}
    </>
  );
}

function Head({ labels }: { labels: string[] }) {
  return (
    <thead>
      <tr>
        {labels.map((l) => (
          <th key={l} scope="col">
            {l}
          </th>
        ))}
      </tr>
    </thead>
  );
}

/** The chart area: a figure with its sentence for screen readers, keyboard-explorable. */
function Figure({ label, children }: { label: string; children: ReactNode }) {
  return (
    <figure className="graph__figure" aria-label={label}>
      <ResponsiveContainer width="100%" height={CHART_HEIGHT}>
        {children as React.ReactElement}
      </ResponsiveContainer>
    </figure>
  );
}

/** A tooltip box: the day, then lines of text (the chart's own words, never colour alone). */
function Tip({
  title,
  lines,
}: {
  title: string;
  lines: { name: string; value: string; o?: OptionInfo }[];
}) {
  return (
    <div className="tip">
      <p className="tip__title">{title}</p>
      {lines.map((l) => (
        <p key={l.name} className="tip__line">
          {l.o && <Swatch o={l.o} kind="line" />}
          <span>{l.name}</span>
          <strong>{l.value}</strong>
        </p>
      ))}
    </div>
  );
}

const axisProps = {
  tick: { fill: INK.inkSoft, fontSize: 12 },
  tickLine: false,
  axisLine: { stroke: '#d9d4ec' },
} as const;

function xAxis(year: number) {
  return (
    <XAxis
      dataKey="day"
      {...axisProps}
      minTickGap={28}
      tickFormatter={(d: string) => formatDate(d, year)}
    />
  );
}

/** A dot on a day money moved in or out. Filled for in, hollow for out. */
function flowDot(flowOf: (payload: unknown) => Cents | undefined, colour: string) {
  return (props: { cx?: number; cy?: number; payload?: unknown; index?: number }) => {
    const f = props.payload === undefined ? undefined : flowOf(props.payload);
    if (f === undefined || props.cx === undefined || props.cy === undefined || toCents(f) === 0n)
      return <g key={props.index} />;
    const into = toCents(f) > 0n;
    return (
      <circle
        key={props.index}
        cx={props.cx}
        cy={props.cy}
        r={5}
        fill={into ? colour : '#fff'}
        stroke={into ? '#fff' : colour}
        strokeWidth={2.5}
      />
    );
  };
}

function FlowKey({ colour }: { colour: string }) {
  return (
    <p className="flowkey">
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="5" fill={colour} stroke="#fff" strokeWidth="2" />
      </svg>
      <span>{T.DOT_IN}</span>
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="5" fill="#fff" stroke={colour} strokeWidth="2.5" />
      </svg>
      <span>{T.DOT_OUT}</span>
      <span className="flowkey__why">{T.DOT_KEY}</span>
    </p>
  );
}

// ---------------------------------------------------------------- 1. Total worth over time

function WorthGraph({ base }: { base: Base }) {
  const [range, setRange] = useState<WorthRange>('3M');
  const q = useRpc<DailyBalance[]>('daily_balances', {
    p_account_id: base.accountId,
    p_from: worthFrom(base.ranges, range),
    p_to: base.ranges.today,
  });
  return (
    <>
      <div className="graph__controls">
        <RangeChoice ranges={WORTH_RANGES} value={range} onChange={setRange} />
      </div>
      <Loaded q={q} empty={(d) => d.every((r) => toCents(r.total_cents) === 0n)}>
        {(d) => {
          const { rows, shown } = worthRows(d, base.options);
          const last = rows[rows.length - 1];
          const data = rows.map((r) => ({ day: r.day, ...r.plot, flow: r.flow }));
          return (
            <>
              <Figure label={`${T.HEADING.worth}: ${formatCents(last.total)} today`}>
                <AreaChart data={data} margin={{ top: 12, right: 12, bottom: 0, left: 4 }}>
                  <CartesianGrid vertical={false} stroke="#ebe7f7" />
                  {xAxis(base.year)}
                  <YAxis {...axisProps} width={64} tickFormatter={axisDollars} />
                  <Tooltip
                    content={({ active, label }) => {
                      const r = rows.find((x) => x.day === label);
                      if (!active || !r) return null;
                      return (
                        <Tip
                          title={formatDate(r.day, base.year)}
                          lines={[
                            ...shown.map((o) => ({
                              name: o.name,
                              value: formatCents(r.values[o.key] ?? 0),
                              o,
                            })),
                            { name: T.COL_TOTAL, value: formatCents(r.total) },
                            ...(toCents(r.flow) !== 0n
                              ? [{ name: T.flowWords(r.flow), value: '' }]
                              : []),
                          ]}
                        />
                      );
                    }}
                  />
                  {shown.map((o) => (
                    <Area
                      key={o.key}
                      type="linear"
                      dataKey={o.key}
                      name={o.name}
                      stackId="worth"
                      stroke={o.key === 'savings' ? SAVINGS_OUTLINE : '#fff'}
                      strokeWidth={o.key === 'savings' ? 1.5 : 2}
                      fill={o.colour}
                      fillOpacity={0.9}
                      isAnimationActive={false}
                    />
                  ))}
                  <Line
                    dataKey="total"
                    stroke="none"
                    legendType="none"
                    tooltipType="none"
                    isAnimationActive={false}
                    dot={flowDot((p) => (p as { flow: Cents }).flow, INK.ink)}
                    activeDot={false}
                  />
                </AreaChart>
              </Figure>
              <Key
                items={shown.map((o) => ({
                  o,
                  kind: 'fill',
                  value: formatCents(last.values[o.key] ?? 0),
                }))}
              />
              <FlowKey colour={INK.ink} />
              <TableToggle caption={T.HEADING.worth}>
                <Head
                  labels={[T.COL_DAY, ...shown.map((o) => o.name), T.COL_TOTAL, T.COL_IN_OUT]}
                />
                <tbody>
                  {[...rows].reverse().map((r) => (
                    <tr key={r.day}>
                      <Cells
                        cells={[
                          { label: T.COL_DAY, value: formatDate(r.day, base.year) },
                          ...shown.map((o) => ({
                            label: o.name,
                            value: formatCents(r.values[o.key] ?? 0),
                          })),
                          { label: T.COL_TOTAL, value: formatCents(r.total) },
                          {
                            label: T.COL_IN_OUT,
                            value:
                              toCents(r.flow) === 0n ? '—' : formatCents(r.flow, { sign: true }),
                          },
                        ]}
                      />
                    </tr>
                  ))}
                </tbody>
              </TableToggle>
            </>
          );
        }}
      </Loaded>
    </>
  );
}

// ---------------------------------------------------------------- 2. Growth by option

function GrowthGraph({ base }: { base: Base }) {
  const [range, setRange] = useState<WorthRange>('3M');
  const [unit, setUnit] = useState<Unit>('pct');
  const q = useRpc<GrowthPoint[]>('growth_by_option', {
    p_account_id: base.accountId,
    p_from: worthFrom(base.ranges, range),
    p_to: base.ranges.today,
  });
  return (
    <>
      <div className="graph__controls">
        <RangeChoice ranges={WORTH_RANGES} value={range} onChange={setRange} />
        <UnitChoice value={unit} onChange={setUnit} />
      </div>
      <Loaded q={q} empty={(d) => d.length === 0}>
        {(d) => {
          const { rows, shown } = growthRows(d, base.options);
          const last = lastPoints(d);
          const show = (p: GrowthPoint) => T.growthKey(p.growth_pct, p.earned_cents, unit);
          const pick = (o: OptionInfo) => (r: (typeof rows)[number]) =>
            unit === 'pct' ? r.pct[o.key] : r.cents[o.key];
          return (
            <>
              <Figure
                label={`${T.HEADING.growth}: ${shown.map((o) => `${o.name} ${show(last[o.key])}`).join(', ')}`}
              >
                <LineChart data={rows} margin={{ top: 12, right: 12, bottom: 0, left: 4 }}>
                  <CartesianGrid vertical={false} stroke="#ebe7f7" />
                  {xAxis(base.year)}
                  <YAxis
                    {...axisProps}
                    width={64}
                    tickFormatter={(v: number) => (unit === 'pct' ? `${v}%` : axisDollars(v))}
                  />
                  <ReferenceLine y={0} stroke={INK.inkSoft} />
                  <Tooltip
                    content={({ active, label }) => {
                      const r = rows.find((x) => x.day === label);
                      if (!active || !r) return null;
                      return (
                        <Tip
                          title={formatDate(r.day, base.year)}
                          lines={shown
                            .filter((o) => r.points[o.key])
                            .map((o) => {
                              const p = r.points[o.key];
                              const moved =
                                toCents(p.flow_cents) !== 0n
                                  ? ` · ${T.flowWords(p.flow_cents)}`
                                  : '';
                              return { name: o.name + moved, value: show(p), o };
                            })}
                        />
                      );
                    }}
                  />
                  {shown
                    .filter((o) => o.key === 'savings')
                    .map((o) => (
                      <Line
                        key="savings-outline"
                        dataKey={pick(o)}
                        stroke={SAVINGS_OUTLINE}
                        strokeWidth={5.5}
                        dot={false}
                        activeDot={false}
                        legendType="none"
                        tooltipType="none"
                        isAnimationActive={false}
                      />
                    ))}
                  {shown.map((o) => (
                    <Line
                      key={o.key}
                      dataKey={pick(o)}
                      name={o.name}
                      stroke={o.colour}
                      strokeWidth={3}
                      strokeDasharray={o.dash || undefined}
                      isAnimationActive={false}
                      dot={flowDot(
                        (r) => (r as (typeof rows)[number]).points[o.key]?.flow_cents,
                        o.colour,
                      )}
                      activeDot={{ r: 5, stroke: '#fff', strokeWidth: 2 }}
                    />
                  ))}
                </LineChart>
              </Figure>
              <Key items={shown.map((o) => ({ o, kind: 'line', value: show(last[o.key]) }))} />
              <FlowKey colour={INK.ink} />
              {shown.some((o) => o.key === 'savings') && (
                <p className="muted savings-steps">{T.SAVINGS_STEPS}</p>
              )}
              <p className="graph__lesson">{T.LESSON.growth}</p>
              <TableToggle caption={T.HEADING.growth}>
                <Head labels={[T.COL_DAY, ...shown.map((o) => o.name)]} />
                <tbody>
                  {[...rows].reverse().map((r) => (
                    <tr key={r.day}>
                      <Cells
                        cells={[
                          { label: T.COL_DAY, value: formatDate(r.day, base.year) },
                          ...shown.map((o) => ({
                            label: o.name,
                            value: r.points[o.key] ? show(r.points[o.key]) : '—',
                          })),
                        ]}
                      />
                    </tr>
                  ))}
                </tbody>
              </TableToggle>
            </>
          );
        }}
      </Loaded>
    </>
  );
}

// ---------------------------------------------------------------- 3. Money in vs money earned

const MONEY_IN: OptionInfo = {
  key: 'money_in',
  name: T.LINE_MONEY_IN,
  colour: INK.inkSoft,
  dash: '7 5',
};
const TOTAL_LINE: OptionInfo = { key: 'total', name: T.LINE_TOTAL, colour: '#5B3FD1', dash: '' };

function MoneyGraph({ base }: { base: Base }) {
  const q = useRpc<MoneyInRow[]>('money_in_vs_earned', { p_account_id: base.accountId });
  return (
    <Loaded q={q} empty={(d) => d.length === 0}>
      {(d) => {
        const last = d[d.length - 1];
        const data = d.map((r) => ({
          day: r.day,
          money_in: plot(r.net_deposits_cents),
          total: plot(r.total_cents),
        }));
        return (
          <>
            <div className="earned">
              <p className="earned__label">{T.EARNED_LABEL}</p>
              <p className="earned__amount">{formatCents(last.earned_cents, { sign: true })}</p>
              <p className="graph__headline">{T.earnedNote(last.earned_cents)}</p>
            </div>
            <Figure label={`${T.HEADING.money}: ${T.earnedSentence(last.earned_cents)}`}>
              <ComposedChart data={data} margin={{ top: 12, right: 12, bottom: 0, left: 4 }}>
                <CartesianGrid vertical={false} stroke="#ebe7f7" />
                {xAxis(base.year)}
                <YAxis {...axisProps} width={64} tickFormatter={axisDollars} />
                <Tooltip
                  content={({ active, label }) => {
                    const r = d.find((x) => x.day === label);
                    if (!active || !r) return null;
                    return (
                      <Tip
                        title={formatDate(r.day, base.year)}
                        lines={[
                          { name: T.LINE_TOTAL, value: formatCents(r.total_cents), o: TOTAL_LINE },
                          {
                            name: T.LINE_MONEY_IN,
                            value: formatCents(r.net_deposits_cents),
                            o: MONEY_IN,
                          },
                          {
                            name: T.COL_EARNED,
                            value: formatCents(r.earned_cents, { sign: true }),
                          },
                        ]}
                      />
                    );
                  }}
                />
                <Area
                  dataKey="total"
                  name={T.LINE_TOTAL}
                  stroke={TOTAL_LINE.colour}
                  strokeWidth={3}
                  fill={TOTAL_LINE.colour}
                  fillOpacity={0.1}
                  isAnimationActive={false}
                  type="linear"
                />
                <Line
                  dataKey="money_in"
                  name={T.LINE_MONEY_IN}
                  stroke={MONEY_IN.colour}
                  strokeWidth={3}
                  strokeDasharray={MONEY_IN.dash}
                  dot={false}
                  type="stepAfter"
                  isAnimationActive={false}
                />
              </ComposedChart>
            </Figure>
            <Key
              items={[
                { o: TOTAL_LINE, kind: 'line', value: formatCents(last.total_cents) },
                { o: MONEY_IN, kind: 'line', value: formatCents(last.net_deposits_cents) },
              ]}
            />
            <TableToggle caption={T.HEADING.money}>
              <Head labels={[T.COL_DAY, T.LINE_MONEY_IN, T.LINE_TOTAL, T.COL_EARNED]} />
              <tbody>
                {[...d].reverse().map((r) => (
                  <tr key={r.day}>
                    <Cells
                      cells={[
                        { label: T.COL_DAY, value: formatDate(r.day, base.year) },
                        { label: T.LINE_MONEY_IN, value: formatCents(r.net_deposits_cents) },
                        { label: T.LINE_TOTAL, value: formatCents(r.total_cents) },
                        { label: T.COL_EARNED, value: formatCents(r.earned_cents, { sign: true }) },
                      ]}
                    />
                  </tr>
                ))}
              </tbody>
            </TableToggle>
          </>
        );
      }}
    </Loaded>
  );
}

// ---------------------------------------------------------------- 4. My mix today

function MixGraph({ base }: { base: Base }) {
  const q = useRpc<MixRow[]>('my_mix', { p_account_id: base.accountId });
  return (
    <Loaded q={q} empty={(d) => d.length === 0}>
      {(d) => {
        const opt = (k: string) => base.options.find((o) => o.key === k)!;
        const data = d.map((r) => ({ name: r.name, key: r.option, value: plot(r.value_cents) }));
        return (
          <>
            <div className="mix">
              <figure
                className="mix__figure"
                aria-label={`${T.HEADING.mix}: ${d.map((r) => `${r.name} ${r.mix_pct}%`).join(', ')}`}
              >
                <ResponsiveContainer width="100%" height={240}>
                  <PieChart>
                    <Pie
                      data={data}
                      dataKey="value"
                      nameKey="name"
                      innerRadius="58%"
                      outerRadius="92%"
                      startAngle={90}
                      endAngle={-270}
                      paddingAngle={d.length > 1 ? 1 : 0}
                      isAnimationActive={false}
                    >
                      {data.map((x) => (
                        <Cell
                          key={x.key}
                          fill={opt(x.key).colour}
                          stroke={x.key === 'savings' ? SAVINGS_OUTLINE : '#fff'}
                          strokeWidth={x.key === 'savings' ? 1.5 : 2}
                        />
                      ))}
                    </Pie>
                  </PieChart>
                </ResponsiveContainer>
              </figure>
              <ul className="key key--mix">
                {d.map((r) => (
                  <li key={r.option} className="key__item">
                    <Swatch o={opt(r.option)} kind="fill" />
                    <span className="key__name">{r.name}</span>{' '}
                    <span className="key__value">
                      <strong>{r.mix_pct}%</strong> · {formatCents(r.value_cents)}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
            <p className="graph__lesson">{d.length === 1 ? T.allIn(d[0].name) : T.LESSON.mix}</p>
            <TableToggle caption={T.HEADING.mix}>
              <Head labels={[T.COL_OPTION, T.COL_VALUE, T.COL_SHARE]} />
              <tbody>
                {d.map((r) => (
                  <tr key={r.option}>
                    <Cells
                      cells={[
                        { label: T.COL_OPTION, value: r.name },
                        { label: T.COL_VALUE, value: formatCents(r.value_cents) },
                        { label: T.COL_SHARE, value: `${r.mix_pct}%` },
                      ]}
                    />
                  </tr>
                ))}
              </tbody>
            </TableToggle>
          </>
        );
      }}
    </Loaded>
  );
}

// ---------------------------------------------------------------- 5. GIC ladder

function LadderGraph({ base }: { base: Base }) {
  const q = useRpc<LadderRow[]>('gic_ladder', { p_account_id: base.accountId });
  const { today, ladder_until: until } = base.ranges;
  if (q.data && q.data.length === 0) return <p className="graph__msg">{T.NO_GICS}</p>;
  return (
    <Loaded q={q} empty={() => false}>
      {(d) => (
        <>
          <ol className="ladder" aria-label={T.HEADING.gics}>
            {d.map((g) => (
              <li key={g.gic_id} className="ladder__row">
                <p className="ladder__label">
                  {T.ladderLine(g, termLabel(g.term_months), formatRate(g.rate))}
                </p>
                <div className="ladder__track" aria-hidden="true">
                  <div
                    className={g.ready ? 'ladder__bar ladder__bar--ready' : 'ladder__bar'}
                    style={{ width: `${ladderWidth(g.maturity_date, today, until, daysBetween)}%` }}
                  />
                </div>
                <p className="ladder__ready">
                  {T.ladderReady(g.maturity_date, g.ready, g.at_maturity_cents, base.year)}
                </p>
              </li>
            ))}
          </ol>
          <div className="ladder__axis" aria-hidden="true">
            <span>{T.LADDER_TODAY}</span>
            <span>{T.LADDER_1Y}</span>
            <span>{T.LADDER_2Y}</span>
          </div>
          <TableToggle caption={T.HEADING.gics}>
            <Head labels={[T.COL_GIC, T.COL_START, T.COL_READY, T.COL_AT_READY]} />
            <tbody>
              {d.map((g) => (
                <tr key={g.gic_id}>
                  <Cells
                    cells={[
                      {
                        label: T.COL_GIC,
                        value: T.ladderLine(g, termLabel(g.term_months), formatRate(g.rate)),
                      },
                      { label: T.COL_START, value: formatDate(g.start_date, base.year) },
                      {
                        label: T.COL_READY,
                        value: g.ready ? T.READY_NOW : formatDate(g.maturity_date, base.year),
                      },
                      { label: T.COL_AT_READY, value: formatCents(g.at_maturity_cents) },
                    ]}
                  />
                </tr>
              ))}
            </tbody>
          </TableToggle>
        </>
      )}
    </Loaded>
  );
}

// ---------------------------------------------------------------- 6. Stock fund detail

/** The fund's change and her money's change, labelled apart, and why they differ. */
function FundFiguresBlock({ figures }: { figures: T.FundFigures }) {
  if (figures.none) return <p className="graph__headline">{figures.none}</p>;
  return (
    <div className="figures">
      <dl className="figures__list">
        {figures.lines.map((l) => (
          <div key={l.label} className="figures__row">
            <dt>{l.label}</dt>
            <dd>{l.value}</dd>
          </div>
        ))}
      </dl>
      {figures.why && <p className="figures__why">{figures.why}</p>}
    </div>
  );
}

function tradeMark(colourUp: string, colourDown: string, note: string) {
  return (props: { cx?: number; cy?: number; payload?: FundRow; index?: number }) => {
    const { cx, cy, payload: r } = props;
    if (cx === undefined || cy === undefined || !r) return <g key={props.index} />;
    const marks: ReactNode[] = [];
    if (r.note)
      marks.push(
        <path
          key="n"
          d={`M${cx} ${cy - 18} l6 6 l-6 6 l-6 -6 z`}
          fill="#fff"
          stroke={note}
          strokeWidth={2}
        />,
      );
    if (r.buy)
      marks.push(
        <path
          key="b"
          d={`M${cx} ${cy - 8} l7 12 h-14 z`}
          fill={colourUp}
          stroke="#fff"
          strokeWidth={2}
        />,
      );
    if (r.sell)
      marks.push(
        <path
          key="s"
          d={`M${cx} ${cy + 8} l7 -12 h-14 z`}
          fill={colourDown}
          stroke="#fff"
          strokeWidth={2}
        />,
      );
    return <g key={props.index}>{marks}</g>;
  };
}

function FundGraph({ base }: { base: Base }) {
  const [fund, setFund] = useState(base.funds[0]?.id ?? 'dow');
  const [rangeWanted, setRange] = useState<FundRange>('3M');
  const [unit, setUnit] = useState<Unit>('cents');
  const allowed = fundRanges(base.ranges, fund);
  const range = allowed.includes(rangeWanted) ? rangeWanted : '3M';
  const from = fundFrom(base.ranges, fund, range);
  const q = useRpc<FundChart>('fund_chart', {
    p_account_id: base.accountId,
    p_fund_id: fund,
    p_from: from,
  });
  const info = base.options.find((o) => o.key === fund)!;
  return (
    <>
      <div className="graph__controls">
        <Choice
          label={T.FUND_GROUP}
          options={base.funds.map((f) => ({ key: f.id, short: f.name, long: f.name }))}
          value={fund}
          onChange={setFund}
        />
        <RangeChoice ranges={allowed} value={range} onChange={setRange} />
        <UnitChoice value={unit} onChange={setUnit} />
      </div>
      <Loaded q={q} empty={(c) => c.closes.length === 0}>
        {(c) => {
          const rows = fundRows(c);
          return (
            <>
              <FundFiguresBlock figures={T.fundFigures(info.name, range, c)} />
              <p className="muted">{T.fundChange(info.name, c.change_pct)}</p>
              <Figure label={`${info.name}: ${T.fundChange(info.name, c.change_pct)}`}>
                <LineChart data={rows} margin={{ top: 24, right: 12, bottom: 0, left: 4 }}>
                  <CartesianGrid vertical={false} stroke="#ebe7f7" />
                  {xAxis(base.year)}
                  <YAxis
                    {...axisProps}
                    width={64}
                    domain={['auto', 'auto']}
                    tickFormatter={(v: number) => (unit === 'pct' ? `${v}%` : `$${v}`)}
                  />
                  {unit === 'pct' && <ReferenceLine y={0} stroke={INK.inkSoft} />}
                  <Tooltip
                    content={({ active, label }) => {
                      const r = rows.find((x) => x.day === label);
                      if (!active || !r) return null;
                      return (
                        <Tip
                          title={formatDate(r.day, base.year)}
                          lines={[
                            { name: T.COL_PRICE, value: formatPrice(r.closeText), o: info },
                            { name: T.COL_CHANGE, value: signedPct(r.pctText) },
                            ...[r.buy, r.sell]
                              .filter((t) => t)
                              .map((t) => ({ name: T.tradeWords(t!), value: '' })),
                            ...(r.note ? [{ name: r.note, value: '' }] : []),
                          ]}
                        />
                      );
                    }}
                  />
                  <Line
                    dataKey={unit === 'pct' ? 'pct' : 'close'}
                    name={info.name}
                    stroke={info.colour}
                    strokeWidth={2.5}
                    isAnimationActive={false}
                    dot={tradeMark(MOVE.up, MOVE.down, INK.ink)}
                    activeDot={{ r: 5, stroke: '#fff', strokeWidth: 2 }}
                  />
                </LineChart>
              </Figure>
              <ul className="key">
                <li className="key__item">
                  <svg
                    className="swatch"
                    width="28"
                    height="16"
                    viewBox="0 0 28 16"
                    aria-hidden="true"
                  >
                    <path d="M14 2 l7 12 h-14 z" fill={MOVE.up} />
                  </svg>
                  <span className="key__name">{T.BUY}</span>
                </li>
                <li className="key__item">
                  <svg
                    className="swatch"
                    width="28"
                    height="16"
                    viewBox="0 0 28 16"
                    aria-hidden="true"
                  >
                    <path d="M14 14 l7 -12 h-14 z" fill={MOVE.down} />
                  </svg>
                  <span className="key__name">{T.SELL}</span>
                </li>
                <li className="key__item">
                  <svg
                    className="swatch"
                    width="28"
                    height="16"
                    viewBox="0 0 28 16"
                    aria-hidden="true"
                  >
                    <path
                      d="M14 2 l6 6 l-6 6 l-6 -6 z"
                      fill="#fff"
                      stroke={INK.ink}
                      strokeWidth="2"
                    />
                  </svg>
                  <span className="key__name">{T.NOTES_HEADING}</span>
                </li>
              </ul>
              {c.trades.length > 0 && (
                <ul className="graph__list">
                  {c.trades.map((t, i) => (
                    <li key={i}>
                      <strong>{formatDate(t.d, base.year)}</strong> · {T.tradeWords(t)}
                    </li>
                  ))}
                </ul>
              )}
              {c.notes.length > 0 && (
                <>
                  <h3 className="graph__sub">{T.NOTES_HEADING}</h3>
                  <ul className="graph__list notes-list">
                    {c.notes.map((n, i) => (
                      <li key={i}>
                        <strong>{formatDate(n.d, base.year)}</strong> · {n.body}
                      </li>
                    ))}
                  </ul>
                </>
              )}
              <p className="graph__lesson">{T.LESSON.funds}</p>
              <TableToggle caption={`${T.HEADING.funds}: ${info.name}`}>
                <Head labels={[T.COL_DAY, T.COL_PRICE, T.COL_CHANGE, T.COL_YOU]} />
                <tbody>
                  {[...rows].reverse().map((r) => (
                    <tr key={r.day}>
                      <Cells
                        cells={[
                          { label: T.COL_DAY, value: formatDate(r.day, base.year) },
                          { label: T.COL_PRICE, value: formatPrice(r.closeText) },
                          { label: T.COL_CHANGE, value: signedPct(r.pctText) },
                          {
                            label: T.COL_YOU,
                            value:
                              [r.buy, r.sell]
                                .filter((t) => t)
                                .map((t) => T.tradeWords(t!))
                                .join('; ') || '—',
                          },
                        ]}
                      />
                    </tr>
                  ))}
                </tbody>
              </TableToggle>
            </>
          );
        }}
      </Loaded>
    </>
  );
}
