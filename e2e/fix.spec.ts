// Stage 8 B3 against the LOCAL Supabase (demo data): Fix a mistake.
// From a line in "View as Robin" (which stays read-only: its link leads to Dad's
// own screen) and from Robin's question on Approvals. Each correction is checked
// against the database: a new linked savings line (never an edit), rounded in her
// favour, her notice word for word what the preview showed, and the log row. A
// reduction and a big addition need the extra check with the amount in large type;
// Back changes nothing; more than her free savings is refused. Runs last, in its
// own project, because it changes Robin's savings.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { parentSignIn } from './helpers';

test.describe.configure({ mode: 'serial' });

const ROBIN = `(select account_id from public.profiles where username = 'demo_robin')`;

async function rows<T = Record<string, string>>(sql: string, params: unknown[] = []): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql, params)) as T[];
  } finally {
    await db.close();
  }
}

/** Everything a correction (or its preview, or Back) could touch. */
const footprint = async () =>
  (
    await rows<{ f: string }>(
      `select concat_ws('/', (select count(*) from public.transactions), (select sum(amount_cents) from public.transactions),
              (select count(*) from public.notifications), (select count(*) from public.parent_actions),
              (select count(*) from public.questions where status = 'open')) as f`,
    )
  )[0].f;

const robinSavings = async () =>
  (
    await rows<{ savings: string; free: string }>(
      `select savings_cents::text as savings, available_cents::text as free
         from public.account_balances where account_id = ${ROBIN}`,
    )
  )[0];

/** The latest correction, its log row and Robin's notice about it. */
const lastFix = async () =>
  (
    await rows<{
      cents: string;
      note: string;
      corrects: string | null;
      question: string | null;
      title: string;
      body: string;
      summary: string;
      who: string;
      when: string;
    }>(
      `select t.amount_cents::text as cents, t.note, c.posting_key as corrects, t.question_id::text as question,
              n.title, n.body, pa.summary, p.display_name as who, public.fmt_moment(pa.done_at) as when
         from public.transactions t
         left join public.transactions c on c.id = t.corrects_id
         join public.notifications n on n.dedupe_key = 'correction:' || t.id
         join public.parent_actions pa on pa.action = 'correct_savings' and pa.target_id = t.id
         join public.profiles p on p.user_id = pa.done_by
        where t.account_id = ${ROBIN} and t.type = 'correction'
        order by t.id desc limit 1`,
    )
  )[0];

/** From Dad's dashboard, View as Robin, her history, a savings interest line, "Fix a mistake". */
async function fromViewAs(page: Page, title = 'Savings interest', signIn = true) {
  if (signIn) await parentSignIn(page);
  else await page.goto('./parent');
  await page.getByRole('link', { name: 'View as Robin' }).click();
  await page.getByRole('link', { name: 'See all' }).click();
  const line = page
    .locator('.activity__item')
    .filter({ has: page.locator('.activity__title', { hasText: new RegExp(`^${title}$`) }) })
    .first();
  await line.locator('.activity__row').click();
  await line.getByRole('link', { name: 'Fix a mistake' }).click();
  await expect(
    page.getByRole('heading', { name: "Fix a mistake in Robin's savings" }),
  ).toBeVisible();
}

test("View as stays read-only: its link leads to Dad's own screen for that line", async ({
  page,
}) => {
  const before = await footprint();
  await parentSignIn(page);
  await page.getByRole('link', { name: 'View as Robin' }).click();
  await page.getByRole('link', { name: 'See all' }).click();
  const line = page.locator('.activity__item', { hasText: 'Savings interest' }).first();
  await line.locator('.activity__row').click();
  // Nothing to type or press inside View as: only a link out.
  await expect(line.getByRole('textbox')).toHaveCount(0);
  await expect(line.getByRole('button', { name: /fix|correct/i })).toHaveCount(0);
  await expect(line.getByText('Nothing changes here.')).toBeVisible();
  await line.getByRole('link', { name: 'Fix a mistake' }).click();

  await expect(page).toHaveURL(/\/parent\/fix\/[0-9a-f-]+\?line=interest/);
  await expect(page.getByRole('note')).toHaveCount(0); // the View as banner is gone
  await expect(page.locator('.fix__line-words')).toHaveText('Savings interest');
  const s = await robinSavings();
  await expect(page.locator('.fix__figures')).toContainText(
    `Savings $${(Number(s.savings) / 100).toFixed(2)}`,
  );
  expect(await footprint()).toBe(before);
});

const cents = (c: string | number) =>
  '$' + (Number(c) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2 });

/** Robin's latest savings interest line: its key, amount and date. */
const interestLine = async () =>
  (
    await rows<{ key: string; amount: string; on: string }>(
      `select posting_key as key, amount_cents::text as amount,
              public.fmt_date(public.edmonton_local(effective_at)::date) as on
         from public.transactions where account_id = ${ROBIN} and type = 'interest' and vehicle = 'savings'
        order by effective_at desc limit 1`,
    )
  )[0];

test('a small addition, rounded up in her favour: the line, her notice, her history and the log', async ({
  page,
}) => {
  await fromViewAs(page);
  const before = await robinSavings();
  const line = await interestLine();
  await page.getByLabel('Add to her savings').check();
  await page.getByLabel('Amount in dollars').fill('1.234');
  await page.getByLabel('Note she will read (required)').fill('September interest was short');
  await expect(
    page.getByText("You typed $1.2340. It's rounded up to $1.24, in Robin's favour."),
  ).toBeVisible();
  await expect(page.getByText('Her graphs count it as money earned.')).toBeVisible();
  const notice = (await page.locator('.set__notice').innerText()).replace(/\s+/g, ' ').trim();
  await page.getByRole('button', { name: "Yes, add $1.24 to Robin's savings" }).click();
  await expect(page.locator('.set__done')).toContainText('Done. Corrected Robin');

  const fix = await lastFix();
  expect(fix.cents).toBe('124');
  expect(fix.note).toBe('September interest was short');
  expect(fix.corrects).toBe(line.key);
  expect(`${fix.title} ${fix.body}`).toBe(notice);
  expect(fix.title).toBe(`A correction · fixes Savings interest on ${line.on}`);
  expect(fix.body).toBe(
    'Dad added $1.24 to your savings. Dad said: "September interest was short"',
  );
  await expect(page.locator('.set__done')).toHaveText(
    `Done. ${fix.summary} Recorded: ${fix.who}, ${fix.when}.`,
  );
  expect(Number((await robinSavings()).savings)).toBe(Number(before.savings) + 124);
  await expect(page.locator('.fix__past li').first()).toContainText('+$1.24');

  // Her history names what it fixes (seen through View as, as she sees it).
  await page.getByRole('link', { name: "Back to Robin's history" }).click();
  await expect(
    page
      .locator('.activity__title', {
        hasText: `A correction · fixes Savings interest on ${line.on}`,
      })
      .first(),
  ).toBeVisible();
});

test('a bigger addition than its line: a warning, not a block', async ({ page }) => {
  await fromViewAs(page);
  const before = await footprint();
  const line = await interestLine();
  const more = ((Number(line.amount) + 100) / 100).toFixed(2);
  await page.getByLabel('Add to her savings').check();
  await page.getByLabel('Amount in dollars').fill(more);
  await page.getByLabel('Note she will read (required)').fill('Checking the warning');
  await expect(page.locator('.fix__warning')).toHaveText(
    `⚠️ This is more than the line it fixes (${cents(line.amount)}). Is that right?`,
  );
  await expect(page.getByRole('button', { name: /^Yes, add/ })).toBeEnabled();
  expect(await footprint()).toBe(before);
});

test('a reduction: never more than its line; a tap in large type to confirm; Back changes nothing', async ({
  page,
}) => {
  await fromViewAs(page);
  const line = await interestLine();
  await page.getByLabel('Take from her savings').check();
  await page.getByLabel('Amount in dollars').fill(((Number(line.amount) + 1) / 100).toFixed(2));
  await page.getByLabel('Note she will read (required)').fill('Counted twice');
  await expect(page.locator('.set__error')).toContainText(
    `A fix can't take more than the line it fixes: "Savings interest" on ${line.on} was ${cents(line.amount)}`,
  );

  // From a "Money in" line: $2.00.
  await fromViewAs(page, 'Money in', false);
  const before = await footprint();
  await page.getByLabel('Take from her savings').check();
  await page.getByLabel('Amount in dollars').fill('2');
  await page.getByLabel('Note she will read (required)').fill('That $2 was counted twice');
  await expect(page.locator('.set__notice')).toContainText('Dad took $2.00 out of your savings.');
  await expect(
    page.getByText('Her graphs count it as money in or out, not money earned.'),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Next: check the amount' }).click();
  const check = page.getByRole('group', {
    name: "Check the amount: you're taking this from Robin's savings",
  });
  await expect(check.locator('.fix__big')).toHaveText('−$2.00');
  const size = await check
    .locator('.fix__big')
    .evaluate((e) => parseFloat(getComputedStyle(e).fontSize));
  expect(size).toBeGreaterThanOrEqual(36);
  await expect(check.getByRole('textbox')).toHaveCount(0); // a tap, not retyping
  await check.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);

  const saved = await robinSavings();
  await page.getByRole('button', { name: 'Next: check the amount' }).click();
  await page.getByRole('button', { name: 'Yes, take $2.00' }).click();
  await expect(page.locator('.set__done')).toContainText('Corrected Robin');
  const fix = await lastFix();
  expect(fix.cents).toBe('-200');
  expect(fix.title).toMatch(/^A correction · fixes Money in on /);
  expect(Number((await robinSavings()).savings)).toBe(Number(saved.savings) - 200);
});

test('over $100: type the amount again; over the cap: refused; never more than she has free', async ({
  page,
}) => {
  await fromViewAs(page, 'Money in');
  const before = await footprint();
  const [{ cap }] = await rows<{ cap: string }>(
    `select public.setting_on('deposit_cap_cents', public.app_today()) as cap`,
  );
  await page.getByLabel('Add to her savings').check();
  await page.getByLabel('Note she will read (required)').fill('Birthday money');

  // Over the cap: refused, pointing to a normal deposit.
  await page.getByLabel('Amount in dollars').fill(((Number(cap) + 1) / 100).toFixed(2));
  await expect(page.locator('.set__error')).toHaveText(
    `A single correction can't be more than the deposit limit (${cents(cap)}). If this is new money, use a normal deposit instead.`,
  );

  // $150: a tap isn't enough; it must be typed again, exactly.
  await page.getByLabel('Amount in dollars').fill('150');
  await page.getByRole('button', { name: 'Next: check the amount' }).click();
  const check = page.getByRole('group', {
    name: "Check the amount: you're adding to Robin's savings",
  });
  await expect(check.locator('.fix__big')).toHaveText('+$150.00');
  await expect(check).toContainText("It's more than $100.00, so type the amount again");
  const yes = check.getByRole('button', { name: 'Yes, add $150.00' });
  await expect(yes).toBeDisabled();
  await check.getByLabel('Type the amount again to confirm').fill('15');
  await yes.click();
  await expect(check.locator('.set__error')).toHaveText(
    "The amount typed again ($15.00) doesn't match $150.00. Please type it again.",
  );
  expect(await footprint()).toBe(before);
  await check.getByLabel('Type the amount again to confirm').fill('150.00');
  const saved = await robinSavings();
  await yes.click();
  await expect(page.locator('.set__done')).toContainText('Corrected Robin');
  expect((await lastFix()).cents).toBe('15000');
  expect(Number((await robinSavings()).savings)).toBe(Number(saved.savings) + 15000);

  // More than she has free (within the line and the cap): refused.
  const { free } = await robinSavings();
  await page.getByLabel('Take from her savings').check();
  await page.getByLabel('Note she will read (required)').fill('Too much');
  await page.getByLabel('Amount in dollars').fill(((Number(free) + 1) / 100).toFixed(2));
  await expect(page.locator('.set__error')).toContainText(
    `That's more than Robin has free to use (${cents(free)}`,
  );
  await expect(page.getByRole('button', { name: 'Next: check the amount' })).toBeDisabled();
});

test("from Robin's question on Approvals: the question and the line it's about", async ({
  page,
}) => {
  await rows(
    `insert into public.questions (account_id, transaction_id, message)
     select ${ROBIN}, t.id, 'Is this interest right?' from public.transactions t
      where t.account_id = ${ROBIN} and t.type = 'interest' and t.vehicle = 'savings'
      order by t.effective_at desc limit 1`,
  );
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: /Approvals/ })
    .click();
  const card = page.locator('.appr__card', { hasText: 'Is this interest right?' });
  await card.getByRole('link', { name: 'Fix a mistake' }).click();
  await expect(page).toHaveURL(/\/parent\/fix\/[0-9a-f-]+\?question=\d+/);
  await expect(page.locator('.fix__quote')).toContainText('Is this interest right?');
  await expect(page.locator('.fix__line-words')).toHaveText('Savings interest');
  await expect(
    page.getByRole('link', { name: 'Back to Approvals to answer her question' }),
  ).toBeVisible();
});
