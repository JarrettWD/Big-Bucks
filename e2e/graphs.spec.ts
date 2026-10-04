// Stage 7 part 2c against the LOCAL Supabase (demo data): the Graphs tab. Each
// graph's figures are checked against the database's own read functions. These
// only read, so they run with the layout checks, before any test changes the demo.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatDate } from '../src/lib/format.ts';
import { formatCents } from '../src/lib/money.ts';
import { signedPct } from '../src/kid/graphs/graphData.ts';
import { earnedNote } from '../src/kid/graphs/graphText.ts';
import { kid, kidSignIn } from './helpers';

const ROBIN = `(select account_id from public.profiles where username = 'demo_robin')`;

async function rows<T = Record<string, string>>(sql: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql)) as T[];
  } finally {
    await db.close();
  }
}
const one = async <T = Record<string, string>>(sql: string) => (await rows<T>(sql))[0];

async function signIn(page: Page) {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await expect(page.getByText('Hi, Robin!')).toBeVisible();
}
async function openTab(page: Page, name: string) {
  await page.getByRole('tab', { name }).click();
  await expect(page.getByRole('tab', { name })).toHaveAttribute('aria-selected', 'true');
}
async function showTable(page: Page) {
  await page.getByRole('button', { name: 'Show as a table' }).click();
  await expect(page.locator('.gtable')).toBeVisible();
}
const today = async () => (await one<{ d: string }>(`select public.app_today()::text as d`)).d;
const year = async () => Number((await today()).slice(0, 4));

test('total worth over time: the last point is Home’s total, with ranges and a table', async ({
  page,
}) => {
  const { total } = await one<{ total: string }>(
    `select total_worth_cents::text as total from public.account_balances where account_id = ${ROBIN}`,
  );
  await signIn(page);
  await expect(page.locator('.hero__amount')).toHaveText(formatCents(total));

  await page.getByRole('link', { name: 'Graphs' }).click();
  await expect(page.getByRole('heading', { name: 'Total worth over time' })).toBeVisible();
  await expect(page.locator('.graph__figure .recharts-area')).not.toHaveCount(0);
  // The key names every option she has, with today's value.
  await expect(page.locator('.key__item', { hasText: 'Savings' })).toBeVisible();

  for (const [range, label] of [
    ['1M', '1 month'],
    ['All', 'All of it'],
  ] as const) {
    await page.getByRole('button', { name: label }).click();
    await expect(page.getByRole('button', { name: label })).toHaveAttribute('aria-pressed', 'true');
    const from = (
      await one<{ d: string }>(
        `select public.graph_ranges(${ROBIN}) -> 'worth' ->> '${range}' as d`,
      )
    ).d;
    const days = await rows<{ day: string; total: string; flow: string }>(
      `select balance_date::text as day, total_cents::text as total, net_flow_cents::text as flow
         from public.daily_balances(${ROBIN}, '${from}', public.app_today()) order by balance_date desc`,
    );
    if (!(await page.locator('.gtable').isVisible())) await showTable(page);
    const trs = page.locator('.gtable tbody tr');
    await expect(trs).toHaveCount(days.length);
    // Newest first: today's total is Home's total.
    await expect(trs.first().locator('td[data-label="Total"]')).toHaveText(formatCents(total));
    await expect(trs.last().locator('th')).toHaveText(
      formatDate(days[days.length - 1].day, await year()),
    );
    // A day money came in shows it, so it isn't mistaken for growth.
    const flowDay = days.find((d) => d.flow !== '0');
    if (flowDay) {
      const i = days.indexOf(flowDay);
      await expect(trs.nth(i).locator('td[data-label="Money in or out"]')).toHaveText(
        formatCents(flowDay.flow, { sign: true }),
      );
    }
  }
});

test('growth by option: time-weighted %, and the $ / % switch', async ({ page }) => {
  const from = (
    await one<{ d: string }>(`select public.graph_ranges(${ROBIN}) -> 'worth' ->> '3M' as d`)
  ).d;
  const last = await rows<{ option: string; pct: string; earned: string }>(
    `select option, growth_pct::text as pct, earned_cents::text as earned
       from public.growth_by_option(${ROBIN}, '${from}', public.app_today()) where day = public.app_today()`,
  );
  const names: Record<string, string> = {
    savings: 'Savings',
    gic: 'GICs',
    dow: 'Dow Jones',
    nasdaq100: 'Nasdaq-100',
    tsx: 'TSX',
  };
  expect(last.length, 'Robin has several options').toBeGreaterThan(2);

  await signIn(page);
  await page.goto('./kid/graphs');
  await openTab(page, 'Growth');
  await expect(page.getByRole('button', { name: 'Percent' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  for (const p of last)
    await expect(page.locator('.key__item', { hasText: names[p.option] })).toContainText(
      signedPct(p.pct),
    );

  await page.getByRole('button', { name: 'Dollars' }).click();
  for (const p of last)
    await expect(page.locator('.key__item', { hasText: names[p.option] })).toContainText(
      formatCents(p.earned, { sign: true }),
    );
  await showTable(page);
  const first = page.locator('.gtable tbody tr').first();
  for (const p of last)
    await expect(first.locator(`td[data-label="${names[p.option]}"]`)).toHaveText(
      formatCents(p.earned, { sign: true }),
    );
});

test('money in vs money earned, my mix and the GIC ladder match the database', async ({ page }) => {
  const money = await one<{ earned: string; total: string; money_in: string }>(
    `select earned_cents::text as earned, total_cents::text as total, net_deposits_cents::text as money_in
       from public.money_in_vs_earned(${ROBIN}) order by day desc limit 1`,
  );
  const mix = await rows<{ name: string; mix_pct: number; value: string }>(
    `select name, mix_pct, value_cents::text as value from public.my_mix(${ROBIN})`,
  );
  const ladder = await rows<{ maturity: string; ready: boolean; at: string }>(
    `select maturity_date::text as maturity, ready, at_maturity_cents::text as at from public.gic_ladder(${ROBIN})`,
  );
  const y = await year();

  await signIn(page);
  await page.goto('./kid/graphs?g=money');
  await expect(page.getByRole('heading', { name: 'Money in vs money earned' })).toBeVisible();
  // The amount she's earned, big, above the graph.
  await expect(page.locator('.earned__amount')).toHaveText(
    formatCents(money.earned, { sign: true }),
  );
  await expect(page.locator('.earned .graph__headline')).toHaveText(earnedNote(money.earned));
  await expect(page.locator('.key__item', { hasText: 'Total worth' })).toContainText(
    formatCents(money.total),
  );
  await expect(page.locator('.key__item', { hasText: 'Money in' })).toContainText(
    formatCents(money.money_in),
  );
  // Two ? words, each beside its name.
  await expect(page.getByRole('button', { name: 'What does "Net deposits" mean?' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'What does "Money earned" mean?' })).toBeVisible();

  await openTab(page, 'Mix');
  expect(mix.reduce((s, m) => s + m.mix_pct, 0)).toBe(100);
  const items = page.locator('.key--mix .key__item');
  await expect(items).toHaveCount(mix.length);
  for (const [i, m] of mix.entries()) {
    await expect(items.nth(i)).toContainText(`${m.name} ${m.mix_pct}%`);
    await expect(items.nth(i)).toContainText(formatCents(m.value));
  }

  await openTab(page, 'GICs');
  const bars = page.locator('.ladder__row');
  await expect(bars).toHaveCount(ladder.length);
  for (const [i, g] of ladder.entries())
    await expect(bars.nth(i).locator('.ladder__ready')).toHaveText(
      g.ready
        ? `Ready now: ${formatCents(g.at)}`
        : `Ready ${formatDate(g.maturity, y)}: ${formatCents(g.at)}`,
    );
});

test('stock fund detail: her buys and sells, the market-move note, and $ / %', async ({ page }) => {
  const from = (
    await one<{ d: string }>(`select public.graph_ranges(${ROBIN}) -> 'fund' ->> '3M' as d`)
  ).d;
  const chart = (
    await one<{
      c: {
        trades: { d: string }[];
        notes: { d: string; body: string }[];
        closes: { pct: number }[];
      };
    }>(`select public.fund_chart(${ROBIN}, 'nasdaq100', '${from}') as c`)
  ).c;
  expect(chart.notes.length, 'the demo has a Nasdaq-100 market-move note').toBeGreaterThan(0);
  const y = await year();

  await signIn(page);
  await page.goto('./kid/graphs?g=funds');
  await page.getByRole('button', { name: 'Nasdaq-100' }).click();
  await expect(page.getByRole('button', { name: 'Nasdaq-100' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(page.locator('.notes-list li')).toHaveCount(chart.notes.length);
  await expect(page.locator('.notes-list li').first()).toHaveText(
    `${formatDate(chart.notes[0].d, y)} · ${chart.notes[0].body}`,
  );
  // Her trades are listed (and marked on the line).
  for (const t of chart.trades)
    await expect(
      page.locator('.graph__list li', { hasText: formatDate(t.d, y) }).first(),
    ).toBeVisible();

  await showTable(page);
  await page.getByRole('button', { name: 'Percent' }).click();
  await expect(
    page.locator('.gtable tbody tr').first().locator('td[data-label="Change"]'),
  ).toHaveText(signedPct(chart.closes[chart.closes.length - 1].pct));
  // The fund's change and her money's change, labelled apart (3M, the default range).
  const range = chart as unknown as { range_growth_pct: number; range_earned_cents: number };
  await expect(
    page.locator('.figures__row', { hasText: 'The fund’s change while you had it' }),
  ).toContainText(signedPct(range.range_growth_pct));
  await expect(page.locator('.figures__row', { hasText: 'Your money’s change' })).toContainText(
    formatCents(range.range_earned_cents, { sign: true }),
  );
  // "Since your first buy" is offered for a fund she has bought, with what she paid.
  await page.getByRole('button', { name: 'Since your first buy' }).click();
  await expect(page.locator('.figures__row', { hasText: 'You paid' })).toBeVisible();
});

test('the tabs work from the keyboard', async ({ page }) => {
  await signIn(page);
  await page.goto('./kid/graphs');
  await page.getByRole('tab', { name: 'Total worth' }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'Growth' })).toBeFocused();
  await expect(page.getByRole('tab', { name: 'Growth' })).toHaveAttribute('aria-selected', 'true');
  await page.keyboard.press('End');
  await expect(page.getByRole('tab', { name: 'Funds' })).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByRole('tabpanel')).toContainText('Stock fund detail');
});
