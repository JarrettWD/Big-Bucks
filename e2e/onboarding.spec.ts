// Stage 8 B4 against the LOCAL Supabase (demo data): onboarding end to end with
// Wren, the demo kid who hasn't started. Dad's "View as" shows her welcome
// read-only; her first visit opens the welcome; the tour; a deposit refused until
// she signs; the agreement (Dad's reviewed wording, today's numbers) and her
// signature; Dad countersigning on his own screen; her first decision once her
// first deposit is in; her history; and What's new. Each step is checked against
// the database. Runs last, in its own project, because it changes Wren's account
// and switches a feature on.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';

test.describe.configure({ mode: 'serial' });

const WREN = `(select account_id from public.profiles where username = 'demo_wren')`;

async function rows<T = Record<string, string>>(sql: string, params: unknown[] = []): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql, params)) as T[];
  } finally {
    await db.close();
  }
}
const one = async <T = Record<string, string>>(sql: string) => (await rows<T>(sql))[0];
const footprint = async () =>
  (
    await one<{ f: string }>(
      `select concat_ws('/', (select count(*) from public.agreement_signatures),
              (select count(*) from public.requests where account_id = ${WREN}),
              (select count(*) from public.parent_actions)) as f`,
    )
  ).f;

async function wrenSignIn(page: Page) {
  const w = kid('Wren');
  await kidSignIn(page, w.username, w.pin);
}

test("Dad's View as Wren shows her welcome read-only", async ({ page }) => {
  const before = await footprint();
  await parentSignIn(page);
  const { id } = await one<{ id: string }>(`select ${WREN}::text as id`);
  await page.goto(`./parent/view/${id}`);
  await expect(page.getByText("Let's set up your Big Bucks with Dad.")).toBeVisible();
  await page.goto(`./parent/view/${id}/welcome?step=agreement`);
  await expect(page.getByRole('heading', { name: 'Your Big Bucks agreement' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Sign my agreement' })).toBeDisabled();
  expect(await footprint()).toBe(before);
});

test('her first visit opens the welcome; the tour; no deposit before she signs', async ({
  page,
}) => {
  await wrenSignIn(page);
  await expect(page).toHaveURL(/\/kid\/welcome$/);
  await expect(page.getByRole('heading', { name: 'Welcome to Big Bucks, Wren!' })).toBeVisible();
  await expect(page.locator('.welcome__steps li')).toHaveText([
    'A quick look around',
    'Your Big Bucks agreement',
    'Your first decision',
  ]);

  // "Look around first" goes Home, where the banner brings her back.
  await page.getByRole('link', { name: 'Look around first' }).click();
  await expect(page.getByText("👋 Let's set up your Big Bucks with Dad.")).toBeVisible();

  // A deposit before she signs: Buy / Sell says why, and nothing is asked for.
  const before = await footprint();
  await page.getByRole('navigation').getByRole('link', { name: 'Buy / Sell' }).click();
  await page.getByLabel('How much?').fill('20');
  await expect(
    page.getByText('Before you can put money in, sign your Big Bucks agreement with Dad.'),
  ).toBeVisible();
  expect(await footprint()).toBe(before);

  // The tour, with today's rates.
  await page.goto('./kid');
  await page.getByRole('link', { name: 'Start' }).click();
  await page.getByRole('button', { name: "Let's go!" }).click();
  await expect(page.getByRole('heading', { name: 'Home 🏠' })).toBeVisible();
  await page.getByRole('button', { name: 'Next' }).click();
  const r = await one<{ lo: string; hi: string; sav: string }>(
    `select public.house_rules() ->> 'gic_lowest' as lo, public.house_rules() ->> 'gic_highest' as hi,
            public.house_rules() ->> 'savings_rate' as sav`,
  );
  await expect(page.getByText(`right now from ${r.lo} to ${r.hi} a year`)).toBeVisible();
  await expect(page.getByText(`It earns ${r.sav} a year in interest`)).toBeVisible();
  await page.getByRole('button', { name: 'Skip the tour' }).click();
  await expect(page.getByRole('heading', { name: 'Your Big Bucks agreement' })).toBeVisible();
});

test("she signs the agreement: Dad's reviewed wording, today's numbers", async ({ page }) => {
  await wrenSignIn(page);
  await page.goto('./kid/welcome?step=agreement');
  const rules = page.locator('.agree__rule');
  await expect(rules).toHaveCount(15);
  const h = await one<{ cap: string; days: string; notice: string }>(
    `select public.house_rules() ->> 'cap' as cap, public.house_rules() ->> 'expiry_days' as days,
            public.house_rules() ->> 'cut_notice_days' as notice`,
  );
  await expect(rules.nth(1)).toContainText(`You can put in up to ${h.cap} altogether.`);
  await expect(rules.nth(3)).toContainText(`Dad has up to ${h.days} days to answer.`);
  await expect(rules.nth(10)).toContainText(
    `Big Bucks tells you at least ${h.notice} days before. Good news, like a higher rate, can start right away.`,
  );
  await expect(rules.nth(13)).toHaveText(
    "🔑Your PIN is yours. Don't share it, not even with your sister. If you think someone knows it, tell Dad.",
  );
  await expect(rules.nth(14)).toContainText('They can look at your Big Bucks screens any time.');
  await expect(page.locator('.agree__promises')).toContainText(
    'Dad keeps your cash safe, answers your requests, and fixes any mistake openly, with a note, rounding in your favour.',
  );
  await expect(page.getByText("I've read these rules with Dad, and I agree. — Wren")).toBeVisible();

  await page.getByRole('button', { name: 'Sign my agreement' }).click();
  await expect(page.getByText("✍️ You signed it! Now it's Dad's turn.")).toBeVisible();
  const sig = await one<{ n: string; same: boolean }>(
    `select count(*)::text as n,
            bool_and(s.copy = public.agreement_render(1, s.account_id)) as same
       from public.agreement_signatures s where s.account_id = ${WREN} and s.signer = 'kid'`,
  );
  expect(sig).toEqual({ n: '1', same: true });

  // Now a deposit can be asked for.
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByText('Your first decision starts with your first deposit.')).toBeVisible();
});

test('Dad reads what she signed and countersigns; she is told', async ({ page }) => {
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: 'Dashboard' })
    .click();
  await expect(page.getByText('Wren signed her agreement and is waiting for you.')).toBeVisible();
  await page.getByRole('link', { name: 'Sign it' }).click();
  const card = page.locator('.appr__card', { hasText: 'Wren signed her Big Bucks agreement' });
  const before = await footprint();
  await card.getByRole('button', { name: 'Read and sign' }).click();
  await expect(card.locator('.agree__rule')).toHaveCount(15);
  await expect(card.locator('.appr__notice')).toHaveText(
    /Your agreement is signed!\s*Dad signed it too\. You can read it any time in your history\./,
  );
  await card.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);

  await card.getByRole('button', { name: 'Read and sign' }).click();
  await card.getByRole('button', { name: "Yes, sign Wren's agreement" }).click();
  const log = await one<{ summary: string; when: string; who: string }>(
    `select pa.summary, public.fmt_moment(pa.done_at) as when, p.display_name as who
       from public.parent_actions pa join public.profiles p on p.user_id = pa.done_by
      where pa.action = 'countersign_agreement' and pa.account_id = ${WREN}`,
  );
  expect(log.summary).toBe("Signed Wren's Big Bucks agreement.");
  await expect(page.locator('#agreements .appr__done')).toHaveText(
    `Done. ${log.summary} Recorded: ${log.who}, ${log.when}.`,
  );
  const n = await one(
    `select title, body from public.notifications where account_id = ${WREN} and type = 'agreement'`,
  );
  expect(n).toEqual({
    title: 'Your agreement is signed!',
    body: 'Dad signed it too. You can read it any time in your history.',
  });
});

test('her first decision once her first deposit is in; then her history', async ({ page }) => {
  // Her first deposit, asked for and approved (Dad's part through the database).
  const db = await LocalDb.connect();
  try {
    const [{ kid_user, parent_user }] = await db.q<{ kid_user: string; parent_user: string }>(
      `select (select user_id::text from public.profiles where username = 'demo_wren') as kid_user,
              (select user_id::text from public.profiles where role = 'parent' limit 1) as parent_user`,
    );
    const asked = await db.call(
      { role: 'authenticated', sub: kid_user, aal: 'aal1' },
      'select public.request_deposit(2000)',
    );
    expect(asked.ok).toBe(true);
    const ok = await db.call(
      { role: 'authenticated', sub: parent_user, aal: 'aal2' },
      'select public.approve_request($1)',
      [Number((asked as { value: unknown }).value)],
    );
    expect(ok.ok).toBe(true);
  } finally {
    await db.close();
  }

  await wrenSignIn(page);
  await expect(page.getByText("👋 Let's finish setting up your Big Bucks.")).toBeVisible();
  await page.getByRole('link', { name: 'Keep going' }).click();
  await expect(
    page.getByRole('heading', { name: '🎉 Your first $20.00 is in your savings!' }),
  ).toBeVisible();
  await expect(page.locator('.welcome__choice')).toHaveCount(3);
  await page.getByRole('button', { name: /Keep it in savings/ }).click();
  await expect(
    page.getByRole('heading', { name: 'You made your first money decision. Nice thinking!' }),
  ).toBeVisible();
  const done = await one<{ done: boolean }>(
    `select onboarding_done_at is not null as done from public.accounts where id = ${WREN}`,
  );
  expect(done.done).toBe(true);

  await page.getByRole('link', { name: 'Go to Home' }).click();
  await expect(page.getByText("Let's set up your Big Bucks")).toHaveCount(0);
  await page.goto('./kid/history');
  const on = await one<{ d: string }>(`select public.fmt_date(public.app_today()) as d`);
  const line = page.locator('#agreement .activity__row');
  await expect(line).toHaveText(
    new RegExp(`Your Big Bucks agreement · signed ${on.d}, Dad signed ${on.d}`),
  );
  await line.click();
  await expect(page.locator('#agreement .agree__rule')).toHaveCount(15);
});

test("What's new: once, for a feature switched on after she onboarded", async ({ page }) => {
  await rows(
    `insert into public.settings (key, value, effective_date) values ('feature:badges', 'everyone', public.app_today())`,
  );
  await wrenSignIn(page);
  const card = page.locator('.whatsnew');
  await expect(card.getByRole('heading', { name: 'New: badges 🏅' })).toBeVisible();
  await expect(card).toContainText('Each badge unlocks something fun for your animal to wear.');
  await card.getByRole('button', { name: 'Got it' }).click();
  await expect(card).toHaveCount(0);
  const seen = await one<{ n: string }>(
    `select count(*)::text as n from public.whats_new_seen where account_id = ${WREN} and feature = 'badges'`,
  );
  expect(seen.n).toBe('1');
  await page.reload();
  await expect(page.locator('.hero')).toBeVisible();
  await expect(page.locator('.whatsnew')).toHaveCount(0);
});
