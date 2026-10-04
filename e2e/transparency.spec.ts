// Stage 7 part 2b against the LOCAL Supabase (demo data): the notices list,
// "How was this calculated?" and "Something looks wrong?". These use Sky, the
// demo's test account (the Home tests use Robin's unread notices), and run in order.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatDate } from '../src/lib/format.ts';
import { kid, kidSignIn } from './helpers';

test.describe.configure({ mode: 'serial' });

const SKY = `(select account_id from public.profiles where username = 'demo_sky')`;

async function rows<T = Record<string, string>>(sql: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql)) as T[];
  } finally {
    await db.close();
  }
}

async function signIn(page: Page) {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await expect(page.getByText('Hi, Sky!')).toBeVisible();
}

const year = async () =>
  Number(
    (await rows<{ y: string }>(`select extract(year from public.app_today())::text as y`))[0].y,
  );

test('the notices list: dates from the database, and opening it marks them read', async ({
  page,
}) => {
  const notices = await rows<{ title: string; on_day: string; is_new: boolean }>(
    `select title, on_day::text, is_new from public.my_notices(${SKY})`,
  );
  const fresh = notices.filter((n) => n.is_new).length;
  expect(fresh, 'Sky has new notices in the demo').toBeGreaterThan(0);

  await signIn(page);
  await page.getByRole('link', { name: `Notices, ${fresh} new` }).click();
  await expect(page.getByRole('heading', { name: 'Notices' })).toBeVisible();
  const items = page.locator('.notice');
  await expect(items).toHaveCount(notices.length);
  // Newest first, each with the date the database worked out.
  const y = await year();
  await expect(items.first().locator('.notice__title')).toHaveText(notices[0].title);
  await expect(items.first().locator('.notice__date')).toHaveText(formatDate(notices[0].on_day, y));
  await expect(page.locator('.notice__new')).toHaveCount(fresh);

  // Opening the list read them: the bell has no count now, and the database agrees.
  await expect(page.getByRole('link', { name: 'Notices', exact: true })).toBeVisible();
  const left = await rows(
    `select 1 from public.notifications where account_id = ${SKY} and read_at is null`,
  );
  expect(left).toHaveLength(0);
});

test('"How was this calculated?" shows the working the database wrote on the line', async ({
  page,
}) => {
  const [interest] = await rows<{ note: string }>(
    `select note from public.my_activity(${SKY}, 200) where kind = 'interest' order by at desc limit 1`,
  );
  expect(interest.note).toMatch(/rounded up to \$\d+\.\d\d$|= \$\d+\.\d\d$/);

  await signIn(page);
  await page.goto('./kid/history');
  const line = page.locator('.activity__row', { hasText: 'Savings interest' }).first();
  await expect(line).toHaveAttribute('aria-expanded', 'false');
  await line.click();
  await expect(line).toHaveAttribute('aria-expanded', 'true');
  const panel = page.locator(`[id="${await line.getAttribute('aria-controls')}"]`);
  await expect(panel.getByRole('heading', { name: 'How was this calculated?' })).toBeVisible();
  await expect(panel.locator('.working__text')).toHaveText(interest.note);

  // A deposit has no working, but can still be asked about.
  await line.click();
  await expect(line).toHaveAttribute('aria-expanded', 'false');
  const deposit = page.locator('.activity__row', { hasText: 'Money in' }).first();
  await deposit.click();
  const depositPanel = page.locator(`[id="${await deposit.getAttribute('aria-controls')}"]`);
  await expect(depositPanel.getByText('How was this calculated?')).toHaveCount(0);
  await expect(depositPanel.getByRole('button', { name: 'Something looks wrong?' })).toBeVisible();
});

test('"Something looks wrong?" sends Dad a question with the line attached, and his answer shows', async ({
  page,
}) => {
  const [txn] = await rows<{ id: string; note: string }>(
    `select transaction_ids[1]::text as id, note from public.my_activity(${SKY}, 200)
      where kind = 'interest' order by at desc limit 1`,
  );
  await signIn(page);
  await page.goto('./kid/history');
  const line = page.locator('.activity__row', { hasText: 'Savings interest' }).first();
  await line.click();
  await page.getByRole('button', { name: 'Something looks wrong?' }).click();

  // An empty question isn't sent.
  await page.getByRole('button', { name: 'Send to Dad' }).click();
  await expect(page.getByRole('alert')).toHaveText('Write your question first.');

  const box = page.getByLabel('What looks wrong? Dad will see this line with your question.');
  await box.fill('I thought this would be more.');
  await page.getByRole('button', { name: 'Send to Dad' }).click();
  await expect(
    page.getByText("Sent! Dad will answer here, and you'll get a notice when he does."),
  ).toBeVisible();

  const [q] = await rows<{ id: string; transaction_id: string; message: string; status: string }>(
    `select id::text, transaction_id::text, message, status::text from public.questions
      where account_id = ${SKY} order by id desc limit 1`,
  );
  expect(q).toMatchObject({
    transaction_id: txn.id,
    message: 'I thought this would be more.',
    status: 'open',
  });

  // The line now shows her question, waiting for Dad; so does "Your questions".
  await expect(page.locator('.activity__more .question')).toContainText(
    'I thought this would be more.',
  );
  await expect(page.locator('.activity__more .question__waiting')).toHaveText(
    "Waiting for Dad's answer.",
  );
  await expect(page.locator('#questions')).toContainText('I thought this would be more.');

  // Dad answers (as he will from his dashboard in stage 8).
  const db = await LocalDb.connect();
  try {
    const [dad] = await db.q<{ user_id: string }>(
      `select user_id::text from public.profiles where username = 'demo_parent'`,
    );
    const r = await db.call(
      { role: 'authenticated', sub: dad.user_id, aal: 'aal2' },
      'select public.answer_question($1, $2)',
      [q.id, 'It works out to $0.0137 a day. Ask me at dinner!'],
    );
    expect(r.ok, r.ok ? '' : r.error).toBe(true);
  } finally {
    await db.close();
  }

  // A notice says so, and leads to her questions, where the answer is.
  await page.goto('./kid/notices');
  const notice = page.locator('.notice', { hasText: 'Dad answered your question' }).first();
  await expect(notice).toContainText('It works out to $0.0137 a day. Ask me at dinner!');
  await notice.getByRole('link', { name: 'See your questions' }).click();
  await expect(page).toHaveURL(/\/kid\/history#questions$/);
  await expect(page.locator('#questions .question__reply').first()).toContainText('Dad answered');
  await expect(page.locator('#questions .question__reply').first()).toContainText(
    'It works out to $0.0137 a day. Ask me at dinner!',
  );
});

test('asking about a waiting request says which line it means', async ({ page }) => {
  await signIn(page);
  await page.goto('./kid/history');
  const line = page
    .locator('.activity__row', { hasText: 'Asked to take money out' })
    .filter({ hasText: '$15.00' })
    .first();
  const day = await line.locator('.activity__date').innerText();
  await line.click();
  await page.getByRole('button', { name: 'Something looks wrong?' }).click();
  await page.getByLabel(/What looks wrong\?/).fill('Can I still change this?');
  await page.getByRole('button', { name: 'Send to Dad' }).click();
  await expect(page.getByText('Sent!', { exact: false })).toBeVisible();

  const [q] = await rows<{ transaction_id: string | null; message: string }>(
    `select transaction_id::text, message from public.questions where account_id = ${SKY} order by id desc limit 1`,
  );
  expect(q.transaction_id).toBeNull();
  expect(q.message).toBe(
    `About "Asked to take money out, $15.00" on ${day}: Can I still change this?`,
  );
});
