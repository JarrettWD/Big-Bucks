// The learning features (Stage 11) against the LOCAL Supabase (demo data). Sky is the demo's test
// account; all six switches are on for test accounts only. These change Sky's view mode and sell a
// little of a fund, so they run in order, last:
//   - detailed: "What will it buy?" adds a line to her savings; What if? and Markets on Graphs;
//   - statements: a ready month adds up and ends at the Total worth graph's figure; print layout;
//   - "Why did you sell?" after a real sell, with "Mom and Dad can see this.", then in her history;
//   - basic: big numbers, three graphs plus What if?, the simple statement; and back again;
//   - Dad's "View as" reads her statements read-only;
//   - every new screen fits each screen size, in both views, with large text too.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money';
import { kid, kidSignIn, parentSignIn } from './helpers';
import { check, SIZES, TEXT } from './layoutCheck';

test.describe.configure({ mode: 'serial' });

async function sql<T = Record<string, string>>(q: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(q)) as T[];
  } finally {
    await db.close();
  }
}
const SKY = `(select account_id from public.profiles where username = '${kid('Sky').username}')`;

async function signInSky(page: Page) {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await expect(page.getByText('Hi, Sky!')).toBeVisible();
}

test('detailed: "What will it buy?" adds a line to her savings', async ({ page }) => {
  await signInSky(page);
  const toggle = page.getByRole('button', { name: '💡 What will it buy?' });
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.home__savings .infl__line')).toContainText('In a year, at today');
  await expect(page.locator('.home__savings .infl__line')).toContainText(
    'so it would buy about what',
  );
  await expect(
    page.getByText("That's normal. It's one reason people use GICs and funds too."),
  ).toBeVisible();
  await toggle.click(); // off again for the next tests
});

test('What if? shows her total, then the three cases, gently', async ({ page }) => {
  await signInSky(page);
  await page.goto('./kid/graphs?g=whatif');
  await expect(page.getByRole('tab', { name: 'What if?' })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  const [w] = await sql<{ w: { actual_cents: number } }>(`select public.kid_what_if(${SKY}) as w`);
  const rows = page.locator('.whatif__row');
  await expect(rows).toHaveCount(4);
  await expect(rows.first()).toContainText('What you have');
  await expect(rows.first()).toContainText(formatCents(w.w.actual_cents));
  await expect(page.getByText('Nobody can know ahead of time.')).toBeVisible();
  await expect(page.locator('.whatif')).not.toContainText(/\blost\b|could have|wrong/i);
  await page.getByText('How was this calculated?').click();
  await expect(page.getByText('Each case uses your real deposits and withdrawals')).toBeVisible();
});

test('Compare the markets: three lines from the same start', async ({ page }) => {
  await signInSky(page);
  await page.goto('./kid/graphs?g=markets');
  await expect(page.getByRole('tab', { name: 'Markets' })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('.graph__legend li')).toHaveCount(3);
  await page.getByRole('button', { name: '1M' }).click();
  await expect(page.locator('.graph__legend li')).toHaveCount(3);
});

test("statements: a ready month adds up and ends at the graph's figure", async ({ page }) => {
  await signInSky(page);
  await page.getByRole('link', { name: '📄 Your statements' }).click();
  await expect(page.getByRole('heading', { name: 'Your statements 📄' })).toBeVisible();
  const [m] = await sql<{ month: string }>(
    `select (x ->> 'month') as month from jsonb_array_elements(public.kid_statement_months(${SKY}) -> 'months') x
      where (x ->> 'ready')::boolean order by 1 desc limit 1`,
  );
  const [s] = await sql<{ s: Record<string, string> }>(
    `select public.kid_statement(${SKY}, '${m.month}') as s`,
  );
  const [g] = await sql<{ total: string }>(
    `select total_cents::text as total from public.daily_balances(${SKY}, '${s.s.to}', '${s.s.to}')`,
  );
  expect(String(s.s.end_cents)).toBe(g.total);
  const lines = page.locator('.stmt__line');
  await expect(lines.filter({ hasText: 'Ending balance' })).toContainText(formatCents(g.total));
  await expect(lines.filter({ hasText: 'Fund gains or losses' })).toHaveCount(1);
  await expect(page.getByRole('button', { name: '🖨️ Print or save as PDF' })).toBeVisible();
  await page.emulateMedia({ media: 'print' });
  await expect(page.locator('.kid__tabs')).toBeHidden();
  await expect(page.locator('.stmt__line').first()).toBeVisible();
  await page.emulateMedia({ media: 'screen' });
});

test('"Why did you sell?" after a real sell, then in her history', async ({ page }) => {
  const [f] = await sql<{ fund_id: string }>(
    `select fund_id from public.fund_positions where account_id = ${SKY} and value_cents >= 3000 order by fund_id limit 1`,
  );
  test.skip(!f, 'Sky holds no fund worth $30 or more');
  await signInSky(page);
  await page
    .getByRole('navigation', { name: 'Main' })
    .getByRole('link', { name: 'Buy / Sell' })
    .click();
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  await page.getByLabel('From').selectOption(`fund:${f.fund_id}`);
  await page.getByLabel('How much?').fill('10');
  await page.getByRole('button', { name: 'Next', exact: true }).click();
  await page.getByRole('button', { name: /^Yes/ }).click();
  await expect(page.getByRole('heading', { name: 'Why did you sell? ✏️' })).toBeVisible();
  await expect(page.getByText('Mom and Dad can see this.')).toBeVisible();
  await page
    .getByRole('textbox', { name: 'Why did you sell? ✏️' })
    .fill('I wanted some money for my goal.');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Saved. You can find it in your history.')).toBeVisible();
  const [r] = await sql<{ n: string }>(
    `select count(*)::text as n from public.sell_reflections where account_id = ${SKY}
       and reflection = 'I wanted some money for my goal.'`,
  );
  expect(r.n).toBe('1');
  await page.goto('./kid/history');
  await expect(page.getByText('Why I sold: I wanted some money for my goal.')).toBeVisible();
});

test('basic: big numbers, fewer graphs, the simple statement; then back', async ({ page }) => {
  await signInSky(page);
  await page.getByRole('button', { name: '👀 Simpler view' }).click();
  await expect(page.getByRole('heading', { name: 'Your money' })).toBeVisible();
  await expect(page.getByRole('button', { name: '💡 What will it buy?' })).toHaveCount(0);
  const [v] = await sql<{ m: string }>(
    `select view_mode::text as m from public.accounts where id = ${SKY}`,
  );
  expect(v.m).toBe('basic');
  await page.goto('./kid/graphs');
  await expect(page.getByRole('tab')).toHaveText(['Total worth', 'Mix', 'Money in', 'What if?']);
  await page.goto('./kid/statements');
  await expect(page.locator('.stmt__line').filter({ hasText: 'Earned' })).toHaveCount(1);
  await expect(page.locator('.stmt__line').filter({ hasText: 'Dividends' })).toHaveCount(0);
  await page.goto('./kid');
  await page.getByRole('button', { name: '🔎 More detail' }).click();
  await expect(page.getByRole('button', { name: '💡 What will it buy?' })).toBeVisible();
});

test('Dad\'s "View as" reads her statements, read-only', async ({ page }) => {
  await parentSignIn(page);
  const [{ id }] = await sql<{ id: string }>(`select ${SKY}::text as id`);
  await page.goto(`./parent/view/${id}/statements`);
  await expect(page.getByRole('heading', { name: 'Your statements 📄' })).toBeVisible();
  await expect(page.locator('.stmt__line').filter({ hasText: 'Ending balance' })).toHaveCount(1);
  await page.goto(`./parent/view/${id}`);
  await expect(page.getByRole('button', { name: '👀 Simpler view' })).toHaveAttribute(
    'aria-disabled',
    'true',
  );
});

for (const mode of ['detailed', 'basic'] as const)
  for (const size of SIZES) {
    test(`the learning screens fit at ${size.name} in the ${mode} view, normal and large text`, async ({
      page,
    }) => {
      test.setTimeout(120_000);
      await sql(`update public.accounts set view_mode = '${mode}' where id = ${SKY}`);
      await signInSky(page);
      await page.setViewportSize({ width: size.width, height: size.height });
      for (const text of TEXT)
        for (const [path, name] of [
          ['./kid', 'home'],
          ['./kid/statements', 'statements'],
          ['./kid/graphs?g=whatif', 'whatif'],
          ...(mode === 'detailed' ? [['./kid/graphs?g=markets', 'markets'] as const] : []),
        ] as const) {
          await page.goto(path);
          await page.waitForLoadState('networkidle');
          await check(page, `learn-${mode}-${name}-${size.name}-${text.name}`, text.scale);
        }
      await sql(`update public.accounts set view_mode = 'detailed' where id = ${SKY}`);
    });
  }
