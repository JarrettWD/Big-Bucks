// The dashboard's words, for Dad. Every amount and date comes from
// parent_dashboard(); this only chooses the words. Nothing here is shown to the girls.

import { formatCents } from '../../lib/money';
import { formatRate, termLabel } from '../../lib/format';
import { FUND_NAMES } from '../../kid/home/activityText';

type Cents = number | string;

export interface DashKid {
  account_id: string;
  kid: string;
  is_test: boolean;
  total_worth_cents: Cents;
  savings_cents: Cents;
  gic_cents: Cents;
  stock_value_cents: Cents;
  net_deposits_cents: Cents;
}
export interface DashExpiring {
  request_id: number;
  kid: string;
  is_test: boolean;
  text: string;
  seconds_left: number;
}
export interface DashMove {
  request_id: number;
  kid: string;
  is_test: boolean;
  when: string;
  from_vehicle: string | null;
  to_vehicle: string | null;
  fund_id: string | null;
  gic_term: number | null;
  amount_cents: Cents | null;
  sell_all: boolean;
  status: string;
}
export interface DashGic {
  gic_id: number;
  kid: string;
  is_test: boolean;
  amount_cents: Cents;
  interest_cents: Cents;
  term_months: number;
  rate: string | number;
  matures: string;
  days_left: number;
  waiting: boolean;
  choose_by: string | null;
}
export interface DashAlert {
  id: number;
  kind: string;
  kid: string | null;
  message: string;
  since: string;
  is_quiet: boolean;
}
export interface DashNotice {
  title: string;
  sent: string;
  kids: { kid: string; is_test: boolean; read: string | null }[];
}
export interface DashHoliday {
  market: string;
  through: string;
  text: string;
}
export interface Dashboard {
  now: string;
  kids: DashKid[];
  liability_cents: Cents;
  waiting: { requests: number; questions: number };
  expiring: DashExpiring[];
  expiring_test: DashExpiring[];
  moves: DashMove[];
  maturities: DashGic[];
  alerts: DashAlert[];
  alerts_quiet: DashAlert[];
  notices: DashNotice[];
  holidays: DashHoliday[];
}

const fund = (id: string | null) => (id ? (FUND_NAMES[id] ?? id) : 'a fund');

/** One automatic move in a line: "Bought a 1-year GIC with $100.00". */
export function moveText(m: DashMove): string {
  const amount = m.amount_cents === null ? '' : formatCents(m.amount_cents);
  if (m.to_vehicle === 'gic')
    return `Bought a ${m.gic_term ? `${termLabel(m.gic_term)} ` : ''}GIC with ${amount}`;
  if (m.from_vehicle === 'gic') return `Moved ${amount} from a GIC to savings`;
  const settled = m.status === 'settled' ? '' : ' (settles at the next close)';
  if (m.to_vehicle === 'stock') return `Buy ${amount} of the ${fund(m.fund_id)} fund${settled}`;
  if (m.from_vehicle === 'stock')
    return m.sell_all
      ? `Sell all of the ${fund(m.fund_id)} fund${settled}`
      : `Sell ${amount} of the ${fund(m.fund_id)} fund${settled}`;
  return `Moved ${amount}`;
}

/** A GIC that's waiting for her, or maturing soon. */
export function gicText(g: DashGic): string {
  const what = `${formatCents(g.amount_cents)} ${termLabel(g.term_months)} GIC at ${formatRate(g.rate)}`;
  if (g.waiting) return `${what} matured ${g.matures}. Waiting for her choice (by ${g.choose_by}).`;
  const when =
    g.days_left === 0 ? 'today' : g.days_left === 1 ? 'tomorrow' : `in ${g.days_left} days`;
  return `${what} matures ${g.matures} (${when}), earning ${formatCents(g.interest_cents)}.`;
}

export function noticeReadText(k: { read: string | null }): string {
  return k.read ? `Read ${k.read}` : 'Not read yet';
}

export const TEXT = {
  title: 'Dashboard',
  needsYou: 'Needs you',
  waiting: (n: number) =>
    n === 0
      ? 'Nothing waiting for you.'
      : n === 1
        ? '1 thing waiting for you'
        : `${n} things waiting for you`,
  waitingDetail: (r: number, q: number) =>
    `${r} ${r === 1 ? 'deposit or withdrawal' : 'deposits and withdrawals'}, ${q} ${q === 1 ? 'question' : 'questions'}`,
  openApprovals: 'Open Approvals',
  expiring: 'Running out of time',
  testAccounts: (n: number) => `Test accounts (${n})`,
  alerts: 'Alerts',
  noAlerts: 'No open alerts.',
  acknowledge: 'Acknowledge',
  ackHeading: 'Mark this alert as dealt with?',
  ackLine:
    "It moves off the dashboard and the daily health check stops reporting it. It's recorded with your name and the time.",
  ackYes: 'Yes, mark it dealt with',
  back: 'Back',
  saving: 'Saving…',
  ackDone: (who: string, when: string) => `Done. Alert acknowledged. Recorded: ${who}, ${when}.`,
  kids: 'The girls',
  worth: 'Total worth',
  savings: 'Savings',
  gics: 'GICs',
  funds: 'Funds',
  putIn: 'Put in (net)',
  owe: 'What you owe them',
  oweNote: 'Real cash you owe the girls, all options together. Test accounts are left out.',
  testList: 'Test accounts (not included)',
  gicsTitle: 'GICs coming due',
  noGics: 'Nothing maturing in the next 30 days.',
  movesTitle: 'Automatic moves (last 14 days)',
  noMoves: 'No moves in the last 14 days.',
  noticesTitle: 'Have they read it? (last 30 days)',
  noNotices: 'No rate, cap or rule notices in the last 30 days.',
  sent: (when: string) => `Sent ${when}`,
  holidaysTitle: 'Market holidays',
  updated: (now: string) => `Up to date as of ${now}.`,
  loadError: (e: string) => `Couldn't load the dashboard: ${e}`,
  retry: 'Try again',
};
