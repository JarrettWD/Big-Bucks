// Stage 8 part A against the LOCAL Supabase (demo data): Dad's Approvals screen.
// Approving, declining and answering, each checked against the database: the
// ledger, the request, her notice (word for word what the preview showed) and the
// parent action log (who and when). Runs in its own project after the kid tests,
// because it changes Robin's requests.
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';

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

async function open(page: Page) {
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: /^Approvals/ })
    .click();
  await expect(page.getByRole('heading', { name: 'Approvals', level: 1 })).toBeVisible();
}

// Robin's card with this text (Sky, the test account, gets requests from the other tests too).
const card = (page: Page, text: string) =>
  page.locator('.appr__card', { hasText: text }).filter({ hasText: 'Robin' });

/** Everything a cancelled confirmation must leave alone. */
const footprint = async () =>
  (
    await rows<{ f: string }>(
      `select concat_ws('/', (select count(*) from public.requests where status = 'pending'),
              (select count(*) from public.transactions), (select count(*) from public.notifications),
              (select count(*) from public.parent_actions)) as f`,
    )
  )[0].f;

test('no app sign-in can call the originals directly, so nothing skips the log', async ({
  page,
  browser,
}) => {
  const anon = readFileSync('.env.local', 'utf8')
    .match(/^VITE_SUPABASE_ANON_KEY=(.*)$/m)![1]
    .trim();
  const token = (p: Page) =>
    p.evaluate(() => JSON.parse(localStorage.getItem('bb.auth') ?? '{}').access_token as string);

  // Dad with the authenticator code, and Robin, each signed in through the app.
  await parentSignIn(page);
  const robinPage = await (await browser.newContext()).newPage();
  const robin = kid('Robin');
  await kidSignIn(robinPage, robin.username, robin.pin);
  await expect(robinPage.getByText('Hi, Robin!')).toBeVisible();
  const callers = { parent: await token(page), kid: await token(robinPage), 'signed out': anon };

  const [target] = await rows<{ req: string; q: string }>(
    `select (select id::text from public.requests where account_id = ${ROBIN} and status = 'pending'
               and type = 'withdraw' and amount_cents = 1000) as req,
            (select id::text from public.questions where account_id = ${ROBIN} and status = 'open') as q`,
  );
  const before = await footprint();
  const calls: [string, Record<string, unknown>][] = [
    ['approve_request_unlogged', { p_request_id: Number(target.req), p_note: null }],
    ['decline_request_unlogged', { p_request_id: Number(target.req), p_reason: 'skip the log' }],
    ['answer_question_unlogged', { p_question_id: Number(target.q), p_reply: 'skip the log' }],
    ['acknowledge_alert_unlogged', { p_alert_id: 1 }],
    ['add_rate_unlogged', { p_vehicle: 'savings', p_gic_term: null, p_rate: 1 }],
    ['set_setting_unlogged', { p_key: 'inflation_rate', p_value: '3.0' }],
  ];
  for (const [who, bearer] of Object.entries(callers))
    for (const [fn, body] of calls) {
      const r = await fetch(`http://127.0.0.1:54321/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          apikey: anon,
          Authorization: `Bearer ${bearer}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      });
      expect([401, 403], `${who} calling ${fn}`).toContain(r.status);
      expect(((await r.json()) as { message: string }).message, `${who} calling ${fn}`).toBe(
        `permission denied for function ${fn}`,
      );
    }
  // Nothing happened: the withdrawal still waits, the question is still open.
  expect(await footprint()).toBe(before);
  const [still] = await rows<{ r: string; q: string }>(
    `select (select status::text from public.requests where id = $1) as r,
            (select status::text from public.questions where id = $2) as q`,
    [target.req, target.q],
  );
  expect(still).toEqual({ r: 'pending', q: 'open' });
  await robinPage.context().close();
});

test('the screen matches the database: what is waiting, the counts and the 24-hour lock', async ({
  page,
}) => {
  // Real kids first; test accounts in their own section after them (B4 review).
  const [counts] = await rows<Record<string, string>>(
    `select count(*) filter (where not a.is_test)::text as money_real, count(*) filter (where a.is_test)::text as money_test,
            (select count(*) from public.questions q join public.accounts x on x.id = q.account_id
              where q.status = 'open' and not x.is_test)::text as q_real,
            (select count(*) from public.questions where status = 'open')::text as q_all
       from public.requests r join public.accounts a on a.id = r.account_id
      where r.status = 'pending' and r.type in ('deposit', 'withdraw')`,
  );
  await open(page);
  await expect(page.locator('#appr-money-false')).toContainText(counts.money_real);
  await expect(page.locator('#appr-money-true')).toContainText(counts.money_test);
  await expect(page.locator('#appr-questions-false')).toContainText(counts.q_real);
  const all = Number(counts.money_real) + Number(counts.money_test) + Number(counts.q_all);
  await expect(
    page.getByRole('navigation', { name: 'Parent' }).getByRole('link', { name: /^Approvals/ }),
  ).toHaveAccessibleName(`Approvals, ${all} waiting`);
  await expect(
    page.locator('section[aria-labelledby="appr-money-false"] .appr__list > li'),
  ).toHaveCount(Number(counts.money_real));

  // The withdrawal the demo asked for just now: locked, with the database's own time.
  const [locked] = await rows<{ amount: string; from: string }>(
    `select amount_cents::text as amount, public.fmt_moment(created_at + interval '24 hours') as from
       from public.requests where account_id = ${ROBIN} and type = 'withdraw' and status = 'pending'
      order by created_at desc limit 1`,
  );
  const lockedCard = card(page, `Withdrawal ${formatCents(locked.amount)}`);
  await expect(lockedCard).toContainText(`you can approve from ${locked.from}`);
  await expect(lockedCard.getByRole('button', { name: 'Approve' })).toBeDisabled();

  // Sky is the test account: tagged.
  await expect(page.locator('.appr__card', { hasText: 'Sky' }).first()).toContainText('Test');
});

test('approving a withdrawal: summary first, then the ledger, her notice and the log', async ({
  page,
}) => {
  const [req] = await rows<{ id: string; savings: string }>(
    `select r.id::text, b.savings_cents::text as savings from public.requests r
       join public.account_balances b on b.account_id = r.account_id
      where r.account_id = ${ROBIN} and r.type = 'withdraw' and r.status = 'pending' and r.amount_cents = 1000`,
  );
  await open(page);
  const c = card(page, 'Withdrawal $10.00');

  // Opening the confirmation and going back changes nothing.
  const before = await footprint();
  await c.getByRole('button', { name: 'Approve' }).click();
  await expect(
    c.getByRole('heading', { name: "Approve Robin's $10.00 withdrawal?" }),
  ).toBeFocused();
  await expect(c.locator('.appr__notice')).toContainText('Your $10.00 withdrawal is approved');
  await c.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);

  await c.getByRole('button', { name: 'Approve' }).click();
  await expect(c).toContainText(
    `Only approve when you hand Robin $10.00 in cash. It comes out of her savings right away: ${formatCents(
      req.savings,
    )} → ${formatCents(BigInt(req.savings) - 1000n)}.`,
  );
  await c.getByLabel('Note to Robin (optional)').fill('Have fun at the fair');
  await expect(c.locator('.appr__notice')).toContainText(
    'Dad approved taking it out of your savings. Have fun at the fair.',
  );
  const shown = (await c.locator('.appr__notice').innerText()).replace(/\s+/g, ' ').trim();
  await c.getByRole('button', { name: 'Yes, approve $10.00' }).click();

  const [log] = await rows<{ summary: string; when: string }>(
    `select summary, public.fmt_moment(done_at) as when from public.parent_actions order by id desc limit 1`,
  );
  await expect(page.getByRole('status')).toHaveText(
    `Done. Approved Robin's $10.00 withdrawal. Recorded: Dad, ${log.when}.`,
  );
  await expect(card(page, 'Withdrawal $10.00')).toHaveCount(0);

  const [check] = await rows<Record<string, string>>(
    `select r.status::text, r.parent_note,
            (select t.amount_cents::text from public.transactions t where t.request_id = r.id) as ledger,
            (select n.title || ' ' || n.body from public.notifications n where n.dedupe_key = 'approved:' || r.id) as notice,
            (select pa.action || '|' || p.display_name || '|' || pa.target_id from public.parent_actions pa
               join public.profiles p on p.user_id = pa.done_by
              where pa.target_id = r.id and pa.action = 'approve_request') as logged
       from public.requests r where r.id = $1`,
    [req.id],
  );
  expect(check).toEqual({
    status: 'approved',
    parent_note: 'Have fun at the fair',
    ledger: '-1000',
    notice: shown,
    logged: `approve_request|Dad|${req.id}`,
  });
  expect(log.summary).toBe("Approved Robin's $10.00 withdrawal.");
});

test('declining a deposit needs a reason, which she sees', async ({ page }) => {
  const [req] = await rows<{ id: string }>(
    `select id::text from public.requests
      where account_id = ${ROBIN} and type = 'deposit' and status = 'pending' and amount_cents = 5000`,
  );
  await open(page);
  const c = card(page, 'Deposit $50.00');
  await c.getByRole('button', { name: 'Decline' }).click();
  await expect(c).toContainText('Nothing changes in her account. She sees your reason.');
  await expect(c.getByRole('button', { name: 'Yes, decline' })).toBeDisabled();
  await expect(c).toContainText('Type your words to see what she gets.');

  await c.getByLabel('Reason (Robin sees this)').fill("Let's put this toward the GIC instead");
  await expect(c.locator('.appr__notice')).toContainText(
    `Dad said: "Let's put this toward the GIC instead"`,
  );
  const shown = (await c.locator('.appr__notice').innerText()).replace(/\s+/g, ' ').trim();
  await c.getByRole('button', { name: 'Yes, decline' }).click();
  await expect(page.getByRole('status')).toContainText("Done. Declined Robin's $50.00 deposit.");

  const [check] = await rows<Record<string, string>>(
    `select r.status::text, r.parent_note,
            (select count(*)::text from public.transactions t where t.request_id = r.id) as ledger,
            (select n.title || ' ' || n.body from public.notifications n where n.dedupe_key = 'declined:' || r.id) as notice,
            (select pa.details ->> 'reason' from public.parent_actions pa
              where pa.target_id = r.id and pa.action = 'decline_request') as logged
       from public.requests r where r.id = $1`,
    [req.id],
  );
  expect(check).toEqual({
    status: 'declined',
    parent_note: "Let's put this toward the GIC instead",
    ledger: '0',
    notice: shown,
    logged: "Let's put this toward the GIC instead",
  });
});

test("answering a question shows her line and its working, and she's told", async ({ page }) => {
  const [q] = await rows<{ id: string; message: string; note: string }>(
    `select q.id::text, q.message, t.note from public.questions q
       join public.transactions t on t.id = q.transaction_id
      where q.account_id = ${ROBIN} and q.status = 'open'`,
  );
  await open(page);
  const c = card(page, q.message);
  await expect(c).toContainText('Savings interest');
  await expect(c).toContainText(`How it was calculated: ${q.note}`);

  await c.getByRole('button', { name: 'Answer' }).click();
  await expect(c.getByRole('button', { name: 'Send answer' })).toBeDisabled();
  const reply = 'The savings rate went down on Sep 1, so each day earned a little less.';
  await c.getByLabel('Your answer (Robin sees this)').fill(reply);
  await expect(c.locator('.appr__notice')).toContainText('Dad answered your question');
  await c.getByRole('button', { name: 'Send answer' }).click();
  await expect(page.getByRole('status')).toContainText("Done. Answered Robin's question.");
  await expect(card(page, q.message)).toHaveCount(0);

  const [check] = await rows<Record<string, string>>(
    `select q.status::text, q.parent_reply,
            (select n.body from public.notifications n where n.dedupe_key = 'question:' || q.id) as notice,
            (select pa.action from public.parent_actions pa where pa.target_id = q.id
                and pa.action = 'answer_question') as logged
       from public.questions q where q.id = $1`,
    [q.id],
  );
  expect(check).toEqual({
    status: 'answered',
    parent_reply: reply,
    notice: reply,
    logged: 'answer_question',
  });
});

test('changing how long you have to answer: preview, confirmation, the log and her notice', async ({
  page,
}) => {
  const [day] = await rows<{ later: string; later_text: string; today_text: string }>(
    `select (public.app_today() + 3)::text as later, public.fmt_date(public.app_today() + 3) as later_text,
            public.fmt_date(public.app_today()) as today_text`,
  );
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: 'Settings' })
    .click();
  const card = page.getByRole('region', { name: 'Time to answer a request' });
  await expect(card).toContainText('7 days');

  // A change for a later day: she'd be told on that day. Going back changes nothing.
  const before = await footprint();
  await card.getByRole('button', { name: 'Change' }).click();
  await card.getByLabel('Days to answer (3 to 30)').fill('12');
  await card.getByLabel('Starts on').fill(day.later);
  await expect(card).toContainText(`On ${day.later_text}, every kid`);
  await expect(card.locator('.set__notice')).toContainText(
    'Dad now has up to 12 days to answer your requests',
  );
  await card.getByLabel('Days to answer (3 to 30)').fill('31');
  await expect(card).toContainText('Use whole days, from 3 to 30.');
  await expect(card.getByRole('button', { name: /Yes, change/ })).toBeDisabled();
  await card.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);

  // From today: she's told right away.
  await card.getByRole('button', { name: 'Change' }).click();
  await card.getByLabel('Days to answer (3 to 30)').fill('10');
  await expect(card).toContainText('will see this right away');
  const shown = (await card.locator('.set__notice').innerText()).replace(/\s+/g, ' ').trim();
  await card.getByRole('button', { name: 'Yes, change to 10 days' }).click();

  const [log] = await rows<{ summary: string; when: string }>(
    `select summary, public.fmt_moment(done_at) as when from public.parent_actions
      where action = 'set_setting' order by id desc limit 1`,
  );
  expect(log.summary).toBe(`Request expiry set to 10 days from ${day.today_text}.`);
  await expect(page.getByRole('status')).toHaveText(
    `Done. ${log.summary} Recorded: Dad, ${log.when}.`,
  );
  await expect(card.locator('.set__value')).toHaveText('10 days');

  const [check] = await rows<Record<string, string>>(
    `select (select value from public.settings where key = 'request_expiry_days' order by id desc limit 1) as value,
            (select n.title || ' ' || n.body from public.notifications n where n.account_id = ${ROBIN}
               and n.type = 'rule_change' order by n.id desc limit 1) as notice`,
  );
  expect(check).toEqual({ value: '10', notice: shown });
});
