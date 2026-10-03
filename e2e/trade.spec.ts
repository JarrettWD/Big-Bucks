// Buy / Sell against the LOCAL Supabase (demo data). These use Sky, the demo's
// test account, so they don't disturb the Home tests, which use Robin and run at
// the same time. They change Sky's data, so they run in order.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money.ts';
import { AMOUNT_MESSAGES } from '../src/kid/trade/moves.ts';
import { kid, kidSignIn } from './helpers';

test.describe.configure({ mode: 'serial' });

const SKY = `(select account_id from public.profiles where username = 'demo_sky')`;

async function dbRow<T = Record<string, string>>(sql: string): Promise<T> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql))[0] as T;
  } finally {
    await db.close();
  }
}

async function openTrade(page: Page) {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await page.getByRole('link', { name: 'Buy / Sell' }).click();
  await expect(page.getByRole('heading', { name: 'Buy / Sell' })).toBeVisible();
}

const amountBox = (page: Page) => page.getByLabel('How much?');
const next = (page: Page) => page.getByRole('button', { name: 'Next', exact: true });

test('a deposit request goes to Dad, and shows as waiting', async ({ page }) => {
  await openTrade(page);
  await expect(page.getByLabel('From')).toHaveValue('cash');
  await expect(page.getByLabel('To')).toHaveValue('savings');
  const { room } = await dbRow<{ room: string }>(
    `select cap_room_cents::text as room from public.account_balances where account_id = ${SKY}`,
  );
  await expect(page.getByText(`You can put in up to ${formatCents(room)} more.`)).toBeVisible();

  await amountBox(page).fill('20');
  await expect(page.getByText('Dad needs to say yes first.', { exact: false })).toBeVisible();
  await next(page).click();
  await expect(page.getByRole('heading', { name: 'Ask Dad to put in $20.00?' })).toBeVisible();
  await page.getByRole('button', { name: 'Yes, do it' }).click();
  await expect(page.getByRole('heading', { name: 'Asked!' })).toBeVisible();
  await expect(page.locator('.waiting')).toContainText('Asked to put in $20.00');

  const r = await dbRow(
    `select type::text, amount_cents::text, status::text from public.requests
      where account_id = ${SKY} order by id desc limit 1`,
  );
  expect(r).toEqual({ type: 'deposit', amount_cents: '2000', status: 'pending' });
});

test('the amount box refuses bad amounts kindly, and only checks after a pause', async ({
  page,
}) => {
  await openTrade(page);
  await page.getByLabel('From').selectOption('savings');
  await page.getByLabel('To').selectOption('gic');

  for (const [text, message] of [
    ['-5', AMOUNT_MESSAGES.negative],
    ['abc', AMOUNT_MESSAGES.notNumber],
    ['1.234', AMOUNT_MESSAGES.tooManyDecimals],
    ['12,5', AMOUNT_MESSAGES.commaCents],
    ['0', AMOUNT_MESSAGES.zero],
  ]) {
    await amountBox(page).fill(text);
    await expect(page.getByText(message)).toBeVisible();
    await expect(amountBox(page)).toHaveAttribute('aria-invalid', 'true');
  }

  // Typing "125" a key at a time sends one check, after she stops.
  const checks: string[] = [];
  page.on('request', (req) => {
    if (req.url().includes('/rpc/move_preview') && req.method() === 'POST')
      checks.push(req.postData() ?? '');
  });
  await amountBox(page).fill('');
  await amountBox(page).pressSequentially('125', { delay: 80 });
  await expect(page.getByText('earns $0.27')).toBeVisible(); // 1 month at 2.5%: 26.04 cents, rounded up
  expect(checks).toHaveLength(1);
  expect(JSON.parse(checks[0])).toMatchObject({ p_kind: 'buy_gic', p_amount_cents: 12500 });

  // More than she has: the database's own words.
  const { avail } = await dbRow<{ avail: string }>(
    `select available_cents::text as avail from public.account_balances where account_id = ${SKY}`,
  );
  await amountBox(page).fill('99999');
  await expect(page.getByText(`You have ${formatCents(avail)} available.`)).toBeVisible();
  await expect(next(page)).toBeDisabled();
});

test('buying a GIC: what each term earns, a summary, then the GIC', async ({ page }) => {
  await openTrade(page);
  await page.getByLabel('From').selectOption('savings');
  await page.getByLabel('To').selectOption('gic');
  await amountBox(page).fill('25');
  await expect(page.getByRole('button', { name: /3 months.*earns \$0\.19/ })).toBeVisible(); // 0.1875
  await expect(page.getByRole('button', { name: 'Pick how long first' })).toBeDisabled();
  await page.getByRole('button', { name: /3 months/ }).click();
  await next(page).click();

  await expect(
    page.getByRole('heading', { name: 'Put $25.00 into a 3-month GIC at 3.0%?' }),
  ).toBeVisible();
  await expect(page.getByText('It earns $0.19 of interest by')).toBeVisible();
  await page.getByRole('button', { name: 'Yes, do it' }).click();
  await expect(page.getByRole('heading', { name: '🎉 Done!' })).toBeVisible();

  const g = await dbRow(
    `select principal_cents::text, term_months::text, rate::text, status::text from public.gic_holdings
      where account_id = ${SKY} order by id desc limit 1`,
  );
  expect(g).toEqual({ principal_cents: '2500', term_months: '3', rate: '3.000', status: 'active' });
});

test('breaking a GIC early warns about the interest lost, in dollars', async ({ page }) => {
  // Sky's 6-month GIC from the demo has been growing for about 3 months.
  const g = await dbRow<{ id: string; lost: string; balance: string }>(
    `select gic_id::text as id, interest_so_far_cents::text as lost, balance_cents::text as balance
       from public.gic_positions where account_id = ${SKY} and status = 'active' and term_months = 6`,
  );
  expect(Number(g.lost)).toBeGreaterThan(0);

  await openTrade(page);
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  // Her GICs are one choice in the list, then a card each; she has two by now.
  await page.getByLabel('From').selectOption({ label: '🔒 One of your GICs' });
  const cards = page.getByRole('radio');
  await expect(cards).toHaveCount(2);
  await expect(page.getByRole('radio', { name: /3-month GIC at 3\.0%/ })).toBeVisible();
  const card = page.getByRole('radio', {
    name: new RegExp(`^\\${formatCents(g.balance)} 6-month GIC at 4\\.0% Ready `),
  });
  await page.locator('.gic-card', { has: card }).click(); // she taps the card
  await expect(card).toBeChecked();
  await expect(page.getByLabel('To')).toHaveValue('savings');
  await expect(amountBox(page)).toHaveCount(0); // a GIC comes out whole
  await expect(
    page.getByText(
      `Moving money out of this GIC before it's ready means you lose all ${formatCents(g.lost)} of interest earned so far.`,
      { exact: false },
    ),
  ).toBeVisible();

  await next(page).click();
  await expect(
    page.getByRole('heading', { name: 'Take your 6-month GIC out early?' }),
  ).toBeVisible();
  await expect(
    page.getByText(`You give up the ${formatCents(g.lost)} of interest it has earned so far.`),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Yes, do it' }).click();
  await expect(page.getByText(`Your ${formatCents(g.balance)} is in savings.`)).toBeVisible();

  const after = await dbRow(`select status::text from public.gic_holdings where id = ${g.id}`);
  expect(after).toEqual({ status: 'broken' });
});

test('selling a fund worth less than she paid shows that, calmly, in dollars', async ({ page }) => {
  // The demo has Sky buy the TSX just before it eases down.
  const f = await dbRow<{ value: string; cost: string; gain: string }>(
    `select value_cents::text as value, cost_cents::text as cost, gain_cents::text as gain
       from public.fund_positions where account_id = ${SKY} and fund_id = 'tsx'`,
  );
  expect(Number(f.gain)).toBeLessThan(0);

  await openTrade(page);
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  await page.getByLabel('From').selectOption('fund:tsx');
  await page.getByText('Sell all of it').click();
  await expect(
    page.getByText(
      `Your TSX is worth ${formatCents(f.value)} right now, but you paid ${formatCents(f.cost)}. Selling now makes a loss of ${formatCents(-Number(f.gain))} final.`,
      { exact: false },
    ),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: 'What does "Loss" mean?' })).toBeVisible();
  await next(page).click();
  await expect(page.getByRole('heading', { name: 'Sell all of your TSX?' })).toBeVisible();
  await expect(
    page.getByText(`It's worth ${formatCents(-Number(f.gain))} less than you paid.`),
  ).toBeVisible();
  // She holds on: nothing is sold.
  await page.getByRole('button', { name: 'Go back' }).click();
  await expect(page.getByRole('heading', { name: 'Buy / Sell' })).toBeVisible();
});

test('a fund trade: when it settles, then one trade per fund per day', async ({ page }) => {
  const { settles } = await dbRow<{ settles: string }>(
    `select public.fmt_close(public.next_settlement('tsx')) as settles`,
  );
  await openTrade(page);
  await page.getByLabel('From').selectOption('savings');
  await page.getByLabel('To').selectOption('fund:tsx');
  await amountBox(page).fill('10');
  await expect(page.getByText(`Your buy happens at ${settles}`, { exact: false })).toBeVisible();
  await next(page).click();
  await expect(page.getByRole('heading', { name: 'Buy $10.00 of TSX?' })).toBeVisible();
  await page.getByRole('button', { name: 'Yes, do it' }).click();
  await expect(page.getByText(`Your TSX buy happens at ${settles}.`)).toBeVisible();
  await expect(page.locator('.waiting')).toContainText('Buying TSX: $10.00');

  const r = await dbRow(
    `select fund_id, amount_cents::text, held_cents::text, status::text from public.requests
      where account_id = ${SKY} order by id desc limit 1`,
  );
  expect(r).toEqual({
    fund_id: 'tsx',
    amount_cents: '1000',
    held_cents: '1000',
    status: 'pending',
  });

  // Again today: the TSX says so, and there's nothing to type.
  await page.getByRole('button', { name: 'Make another move' }).click();
  await page.getByLabel('From').selectOption('savings');
  await expect(page.getByLabel('To').locator('option[value="fund:tsx"]')).toHaveText(
    /traded today, again tomorrow/,
  );
  await page.getByLabel('To').selectOption('fund:tsx');
  await expect(page.getByText("You've already traded the TSX fund today.")).toBeVisible();
  await expect(amountBox(page)).toHaveCount(0);
  await expect(next(page)).toBeDisabled();
});

test('a withdrawal waits 24 hours, and says when Dad can approve it', async ({ page }) => {
  await openTrade(page);
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  await page.getByLabel('From').selectOption('savings');
  await expect(page.getByLabel('To')).toHaveValue('cash');
  await amountBox(page).fill('5');
  const warning = page.getByText('Withdrawals wait at least 24 hours', { exact: false });
  await expect(warning).toBeVisible();
  await next(page).click();
  await page.getByRole('button', { name: 'Yes, do it' }).click();
  await expect(page.getByRole('heading', { name: 'Asked!' })).toBeVisible();

  const { approve } = await dbRow<{ approve: string }>(
    `select public.fmt_moment(created_at + interval '24 hours') as approve from public.requests
      where account_id = ${SKY} and type = 'withdraw' and status = 'pending' order by id desc limit 1`,
  );
  await expect(page.locator('.waiting')).toContainText(`Dad can say yes from ${approve}`);
});
