// Dad's "View as <kid>" against the LOCAL Supabase (demo data). It only reads, so it
// runs with the layout checks, before other tests change the demo. Each check is
// against what Robin herself gets (her own read functions, called as her).
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { LocalDb, type Who } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';

async function withDb<T>(run: (db: LocalDb) => Promise<T>): Promise<T> {
  const db = await LocalDb.connect();
  try {
    return await run(db);
  } finally {
    await db.close();
  }
}
const ROBIN = `(select account_id from public.profiles where username = 'demo_robin')`;

/** One value, read as Robin herself (her own permissions and functions). */
async function asRobin<T>(sql: string): Promise<T> {
  return withDb(async (db) => {
    const [p] = await db.q<{ user_id: string }>(
      `select user_id::text from public.profiles where username = 'demo_robin'`,
    );
    const who: Who = { role: 'authenticated', sub: p.user_id, aal: 'aal1' };
    const r = await db.call(who, sql);
    if (!r.ok) throw new Error(r.error);
    return r.value as T;
  });
}

/** Everything viewing could change for Robin, as one line. */
const footprint = () =>
  withDb(async (db) => {
    const [r] = await db.q<{ f: string }>(
      `select concat_ws('/',
         (select count(*) from public.notifications where account_id = ${ROBIN}),
         (select count(*) from public.notifications where account_id = ${ROBIN} and read_at is null),
         (select count(*) from public.requests where account_id = ${ROBIN}),
         (select count(*) from public.transactions where account_id = ${ROBIN}),
         (select count(*) from public.questions where account_id = ${ROBIN}),
         (select count(*) from public.gic_holdings where account_id = ${ROBIN}),
         (select count(*) from public.parent_actions)) as f`,
    );
    return r.f;
  });

async function viewRobin(page: Page) {
  await parentSignIn(page);
  await page.getByRole('link', { name: 'View as Robin' }).click();
  await expect(page.getByRole('note')).toContainText("Viewing Robin's screens — read-only");
}

test('View as Robin: the banner, her real Home, and every action switched off', async ({
  page,
}) => {
  const before = await footprint();
  const worth = await asRobin<string>(
    `select total_worth_cents::text from public.account_balances where account_id = public.my_account_id()`,
  );
  await viewRobin(page);
  await expect(page.getByText('Hi, Robin!')).toBeVisible();
  await expect(page.locator('.hero__amount')).toHaveText(formatCents(worth));

  // Only Home and Graphs: Buy / Sell and the Wish List are hers to use.
  const tabs = page.getByRole('navigation', { name: 'Main' }).getByRole('link');
  await expect(tabs).toHaveText([/Home/, /Graphs/]);

  // Her actions are there, as she sees them, but switched off.
  await expect(page.getByRole('button', { name: "Choose what's next" })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Got it' }).first()).toBeDisabled();
  await page.locator('.home__activity .activity__row').first().click();
  await expect(page.getByRole('button', { name: 'Something looks wrong?' }).first()).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Sign out' })).toHaveCount(0);
  // Buy / Sell can't be reached by its address either.
  const here = page.url();
  await page.goto(here.replace(/\/?$/, '/trade'));
  await expect(page).toHaveURL(here.replace(/\/$/, ''));

  // Exit goes back to the dashboard; nothing changed.
  await page.getByRole('link', { name: 'Exit' }).click();
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
  expect(await footprint()).toBe(before);
});

test('her history, questions and notices as she sees them; viewing marks nothing read', async ({
  page,
}) => {
  const before = await footprint();
  const lines = await asRobin<string>(
    `select count(*)::text from public.my_activity(public.my_account_id(), 1000)`,
  );
  const questions = await asRobin<string>(
    `select count(*)::text from public.my_questions(public.my_account_id())`,
  );
  const notices = await asRobin<{ total: string; fresh: string }>(
    `select jsonb_build_object('total', count(*)::text, 'fresh', count(*) filter (where is_new)::text)
       from public.my_notices(public.my_account_id(), 30)`,
  );
  await viewRobin(page);

  await page.getByRole('link', { name: 'See all' }).click();
  await expect(page.getByRole('heading', { name: 'Your history' })).toBeVisible();
  await expect(page.locator('section[aria-labelledby="h-history"] .activity__item')).toHaveCount(
    Math.min(30, Number(lines)),
  );
  await expect(page.locator('#questions .question')).toHaveCount(Number(questions));

  await page.getByRole('link', { name: /^Notices/ }).click();
  await expect(page.locator('.notice').first()).toBeVisible();
  await expect(page.locator('.notice')).toHaveCount(Number(notices.total));
  await expect(page.locator('.notice--new')).toHaveCount(Number(notices.fresh));
  // Leave and come back: still new, and the bell still counts them.
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Home' }).click();
  await expect(page.getByRole('link', { name: /^Notices/ })).toHaveAccessibleName(
    Number(notices.fresh) > 0 ? `Notices, ${notices.fresh} new` : 'Notices',
  );
  expect(await footprint(), 'nothing changed and nothing was marked read').toBe(before);
});

test('her Graphs show what she sees', async ({ page }) => {
  const mix = await asRobin<{ name: string; mix_pct: number }[]>(
    `select jsonb_agg(jsonb_build_object('name', name, 'mix_pct', mix_pct)) from public.my_mix(public.my_account_id())`,
  );
  await viewRobin(page);
  await page.getByRole('link', { name: 'Graphs' }).click();
  await page.getByRole('tab', { name: /Mix/ }).click();
  const shown = page.locator('.mix');
  for (const m of mix)
    await expect(shown.locator('li', { hasText: m.name })).toContainText(`${m.mix_pct}%`);
  await page.getByRole('tab', { name: /Funds/ }).click();
  await page.getByRole('button', { name: 'Nasdaq-100' }).click();
  await expect(page.locator('.notes-list')).toBeVisible();
});

test("the database refuses every one of her actions from Dad's session, and she can't use parent_view", async ({
  page,
  browser,
}) => {
  const anon = readFileSync('.env.local', 'utf8')
    .match(/^VITE_SUPABASE_ANON_KEY=(.*)$/m)![1]
    .trim();
  const token = (p: Page) =>
    p.evaluate(() => JSON.parse(localStorage.getItem('bb.auth') ?? '{}').access_token as string);
  const ids = await withDb(async (db) => {
    const [r] = await db.q<{ gic: string; robin: string }>(
      `select (select id::text from public.gic_holdings where account_id = ${ROBIN} order by id limit 1) as gic,
              ${ROBIN}::text as robin`,
    );
    return r;
  });
  const before = await footprint();
  await viewRobin(page);
  const dad = await token(page);
  const call = (bearer: string, fn: string, body: Record<string, unknown>) =>
    fetch(`http://127.0.0.1:54321/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: `Bearer ${bearer}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });
  const kidOnly = "Only a kid's account can do this.";
  const actions: [string, Record<string, unknown>, string][] = [
    ['request_deposit', { p_amount_cents: 1000 }, kidOnly],
    ['request_withdrawal', { p_amount_cents: 1000 }, kidOnly],
    ['buy_gic', { p_amount_cents: 1000, p_term_months: 1 }, kidOnly],
    ['break_gic', { p_gic_id: Number(ids.gic) }, kidOnly],
    ['choose_maturity', { p_gic_id: Number(ids.gic), p_choice: 'to_savings' }, kidOnly],
    [
      'request_trade',
      { p_fund_id: 'dow', p_side: 'buy', p_amount_cents: 1000, p_sell_all: false },
      kidOnly,
    ],
    ['ask_question', { p_message: 'From Dad' }, kidOnly],
    ['move_preview', { p_kind: 'deposit', p_amount_cents: 1000 }, kidOnly],
    ['mark_notices_read', { p_ids: [1, 2, 3] }, 'Only a kid can mark her notices as read.'],
  ];
  for (const [fn, body, message] of actions) {
    const r = await call(dad, fn, body);
    expect([401, 403], fn).toContain(r.status);
    expect(((await r.json()) as { message: string }).message, fn).toBe(message);
  }

  // Her own app can't use parent_view.
  const robinPage = await (await browser.newContext()).newPage();
  const robin = kid('Robin');
  await kidSignIn(robinPage, robin.username, robin.pin);
  await expect(robinPage.getByText('Hi, Robin!')).toBeVisible();
  const r = await call(await token(robinPage), 'parent_view', {
    p_account: ids.robin,
    p_read: 'balances',
  });
  expect([401, 403]).toContain(r.status);
  expect(((await r.json()) as { message: string }).message).toContain('authenticator code');
  await robinPage.context().close();

  expect(await footprint()).toBe(before);
});
