// Stage 8 B2 against the LOCAL Supabase (demo data): Dad's Settings screen.
// A rate change and a special, the cap, a feature switch, and rewording a note and
// a ? explanation, each checked against the database: the rate or setting, the
// girls' notices (word for word what the preview showed, and in Sky's own app)
// and the parent action log (who and when). Runs last, in its own project,
// because it changes rates and the cap that the other tests read.
import { readFileSync } from 'node:fs';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, logins, parentSignIn, typePin } from './helpers';

test.describe.configure({ mode: 'serial' });

const SKY = `(select account_id from public.profiles where username = 'demo_sky')`;
const ROBIN = `(select account_id from public.profiles where username = 'demo_robin')`;

async function rows<T = Record<string, string>>(sql: string, params: unknown[] = []): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql, params)) as T[];
  } finally {
    await db.close();
  }
}

/** Everything a cancelled change must leave alone. */
const footprint = async () =>
  (
    await rows<{ f: string }>(
      `select concat_ws('/', (select count(*) from public.rates), (select count(*) from public.settings),
              (select count(*) from public.notifications), (select count(*) from public.parent_actions),
              (select md5(string_agg(body, '|' order by id)) from public.notes),
              (select md5(string_agg(kid_text, '|' order by term)) from public.glossary)) as f`,
    )
  )[0].f;

const lastLog = async () =>
  (
    await rows<{ summary: string; when: string; who: string }>(
      `select pa.summary, public.fmt_moment(pa.done_at) as when, p.display_name as who
         from public.parent_actions pa join public.profiles p on p.user_id = pa.done_by
        order by pa.id desc limit 1`,
    )
  )[0];

async function open(page: Page) {
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: 'Settings' })
    .click();
  await expect(page.getByRole('heading', { name: 'Settings', level: 1 })).toBeVisible();
}

/** The notices previewed in this change, as "title body" lines, with when each arrives. */
async function previewed(change: Locator) {
  const out: { label: string; text: string }[] = [];
  for (const n of await change.locator('.set__notice').all()) {
    const label = await n.locator('xpath=preceding-sibling::p[1]').innerText();
    out.push({ label, text: (await n.innerText()).replace(/\s+/g, ' ').trim() });
  }
  return out;
}

test('a rate change: preview, Back, then save; the notice reaches Sky word for word', async ({
  page,
  browser,
}) => {
  const [day] = await rows<{ from: string; from_text: string }>(
    `select (public.app_today() + 7)::text as from, public.fmt_date(public.app_today() + 7) as from_text`,
  );
  await open(page);
  const rates = page.getByRole('region', { name: 'Rates' });
  const row = rates.locator('.set__row', { hasText: '3-month GIC' });
  await expect(row.locator('.set__row-value')).toHaveText('3.0%');

  // Going back changes nothing.
  const before = await footprint();
  await row.getByRole('button', { name: 'Change the 3-month GIC rate' }).click();
  const change = row.getByRole('group', { name: 'New 3-month GIC rate' });
  await expect(change.getByLabel('Starts on')).toHaveValue(day.from);
  await change.getByLabel('New rate (% per year)').fill('2.1234');
  await expect(change).toContainText('Use at most 3 numbers after the dot');
  await expect(change.getByRole('button', { name: /^Yes, save/ })).toBeDisabled();
  await change.getByLabel('New rate (% per year)').fill('2.75');
  await change.getByLabel(/Note to the girls/).fill('Rates are falling');
  await expect(change.locator('.set__facts')).toHaveText(
    `3-month GIC: 3.0% → 2.75% from ${day.from_text}.`,
  );
  await expect(change).toContainText('GICs already bought keep their locked-in rate.');
  await expect(change.locator('.set__notice')).toHaveCount(2);
  await change.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);

  // Save it.
  await row.getByRole('button', { name: 'Change the 3-month GIC rate' }).click();
  await change.getByLabel('New rate (% per year)').fill('2.75');
  await change.getByLabel(/Note to the girls/).fill('Rates are falling');
  await expect(change.locator('.set__notice')).toHaveCount(2);
  const shown = await previewed(change);
  // Every account gets it (other tests may have added one).
  const [{ n }] = await rows<{ n: string }>('select count(*)::text as n from public.accounts');
  expect(shown[0].label).toBe(`Every kid (${n} accounts) will see this right away:`);
  expect(shown[1].label).toBe(`On ${day.from_text}, every kid (${n} accounts) will see:`);
  await change.getByRole('button', { name: `Yes, save 2.75% from ${day.from_text}` }).click();

  const log = await lastLog();
  expect(log.summary).toBe(`3-month GIC rate set to 2.75% from ${day.from_text}.`);
  await expect(page.getByRole('status')).toHaveText(
    `Done. ${log.summary} Recorded: ${log.who}, ${log.when}.`,
  );
  await expect(row.locator('.set__scheduled span')).toHaveText(
    `📅 3-month GIC: 2.75% from ${day.from_text}`,
  );
  await expect(
    row.getByRole('button', { name: `Cancel the change planned for ${day.from_text}` }),
  ).toBeVisible();
  await expect(row.locator('.set__row-value')).toHaveText('3.0%');

  const [saved] = await rows<Record<string, string>>(
    `select r.rate::text, r.effective_date::text, r.note,
            (select n.title || ' ' || n.body from public.notifications n
              where n.account_id = ${SKY} and n.related_rate_id = r.id) as sky
       from public.rates r order by r.id desc limit 1`,
  );
  expect(saved).toEqual({
    rate: '2.750',
    effective_date: day.from,
    note: 'Rates are falling',
    sky: shown[0].text,
  });

  // Sky (the test account) sees it in her own app.
  const skyPage = await (await browser.newContext()).newPage();
  const sky = kid('Sky');
  await kidSignIn(skyPage, sky.username, sky.pin);
  await skyPage.goto('./kid/notices');
  await expect(
    skyPage.locator('.notice', { hasText: `3-month GIC rate drops from 3.0% to 2.75%` }).first(),
  ).toContainText('Rates are falling.');
  await skyPage.context().close();
});

test('a one-week special: three notices, and it ends on its last day', async ({ page }) => {
  const [day] = await rows<Record<string, string>>(
    `select public.app_today()::text as start, (public.app_today() + 6)::text as last,
            public.fmt_date(public.app_today()) as start_text, public.fmt_date(public.app_today() + 6) as last_text,
            public.fmt_date(public.app_today() + 7) as after_text`,
  );
  await open(page);
  const row = page.getByRole('region', { name: 'Rates' }).locator('.set__row', {
    hasText: '1-year GIC',
  });
  await row.getByRole('button', { name: 'Change the 1-year GIC rate' }).click();
  const change = row.getByRole('group', { name: 'New 1-year GIC rate' });
  await change.getByLabel('New rate (% per year)').fill('6.5');
  await change.getByLabel('Limited-time special').check();
  await change.getByLabel('First day').fill(day.start);
  await change.getByLabel('Last day').fill(day.last);
  await expect(change.locator('.set__facts')).toHaveText(
    `1-year GIC special: 6.5% from ${day.start_text} to ${day.last_text}, then back to 5.0%.`,
  );
  // Starting today: told now, and again the day after it ends.
  await expect(change.locator('.set__notice')).toHaveCount(2);
  const shown = await previewed(change);
  const [{ n }] = await rows<{ n: string }>('select count(*)::text as n from public.accounts');
  expect(shown[1].label).toBe(`On ${day.after_text}, every kid (${n} accounts) will see:`);
  expect(shown[1].text).toBe(
    'The 1-year GIC special has ended 1-year GICs are back to 5.0%. GICs bought during the special keep 6.5%.',
  );
  await change
    .getByRole('button', { name: `Yes, save 6.5% special from ${day.start_text}` })
    .click();
  await expect(page.getByRole('status')).toContainText(
    `Special: 1-year GIC at 6.5% from ${day.start_text} to ${day.last_text}.`,
  );
  await expect(row.locator('.set__row-value')).toHaveText('6.5%');
  await expect(row.locator('.set__special')).toHaveText(
    `⭐ Special until ${day.last_text}, then 5.0%`,
  );

  const [check] = await rows<Record<string, string>>(
    `select (public.rate_on('gic', 12, $1::date)).rate::text as last_day,
            (public.rate_on('gic', 12, $1::date + 1)).rate::text as day_after,
            (select n.title || ' ' || n.body from public.notifications n where n.account_id = ${ROBIN}
               and n.type = 'rate_change' order by n.id desc limit 1) as robin`,
    [day.last],
  );
  expect(check).toEqual({ last_day: '6.500', day_after: '5.000', robin: shown[0].text });
});

test('the deposit cap: preview and the notice both girls get', async ({ page }) => {
  await open(page);
  const card = page.getByRole('region', { name: 'Deposit cap' });
  await expect(card.locator('.set__row-value')).toHaveText('$1,000.00');
  await card.getByRole('button', { name: 'Change' }).click();
  await card.getByLabel(/New cap, in dollars/).fill('1,250');
  await card.getByLabel(/Note to the girls/).fill('Happy birthday');
  await expect(card.locator('.set__facts')).toHaveText(/^\$1,000\.00 → \$1,250\.00, from /);
  await expect(card.locator('.set__notice')).toHaveCount(1);
  const shown = await previewed(card);
  await card.getByRole('button', { name: 'Yes, change to $1,250.00' }).click();
  await expect(page.getByRole('status')).toContainText('Deposit cap set to $1,250.00 from');
  await expect(card.locator('.set__row-value')).toHaveText('$1,250.00');

  const [check] = await rows<Record<string, string>>(
    `select public.setting_on('deposit_cap_cents', public.app_today()) as cap,
            (select n.title || ' ' || n.body from public.notifications n where n.account_id = ${ROBIN}
               and n.type = 'cap_change' order by n.id desc limit 1) as robin,
            (select n.title || ' ' || n.body from public.notifications n where n.account_id = ${SKY}
               and n.type = 'cap_change' order by n.id desc limit 1) as sky`,
  );
  expect(check).toEqual({ cap: '125000', robin: shown[0].text, sky: shown[0].text });
});

test('a feature switch, a note and a ? explanation', async ({ page }) => {
  await open(page);

  // Badges on for test accounts only. No notice: "What's new" comes with onboarding.
  const features = page.getByRole('region', { name: 'Feature switches' });
  await features.getByRole('button', { name: 'Change the Badges switch' }).click();
  await features.getByLabel('Test accounts only').check();
  await expect(features.locator('.set__facts')).toHaveText(/^Off → Test accounts only, from /);
  await features.getByRole('button', { name: 'Yes, switch to test accounts only' }).click();
  await expect(page.getByRole('status')).toContainText(
    'Feature "badges" switched to test accounts only',
  );
  const [badges] = await rows<{ v: string }>(
    `select public.setting_on('feature:badges', public.app_today()) as v`,
  );
  expect(badges.v).toBe('test');

  // Reword the note already written (the demo's big Nasdaq-100 day).
  const notes = page.getByRole('region', { name: 'Market-move notes' });
  const [note] = await rows<{ id: string; body: string }>(
    `select id::text, body from public.notes order by note_date desc, id desc limit 1`,
  );
  const item = notes.locator('.set__list .set__row').first();
  await expect(item.locator('.set__words')).toHaveText(note.body);
  const before = await footprint();
  await item.getByRole('button', { name: /^Edit the/ }).click();
  await item.getByRole('textbox').fill('Tech companies had a great day.');
  await expect(item).toContainText('No notice: the girls simply see the new wording.');
  await item.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(before);
  await item.getByRole('button', { name: /^Edit the/ }).click();
  await item.getByRole('textbox').fill('Tech companies had a great day.');
  await expect(item.locator('.set__record')).toContainText('Reworded the Nasdaq-100 note for');
  await item.getByRole('button', { name: 'Yes, save this wording' }).click();
  await expect(page.getByRole('status')).toContainText('Reworded the Nasdaq-100 note for');
  const [edited] = await rows<Record<string, string>>(
    `select (select body from public.notes where id = $1) as body,
            (select details ->> 'before' from public.parent_actions where action = 'edit_note'
              order by id desc limit 1) as was`,
    [note.id],
  );
  expect(edited).toEqual({ body: 'Tech companies had a great day.', was: note.body });

  // Reword a ? explanation.
  const glossary = page.getByRole('region', { name: 'The ? explanations' });
  await glossary.getByText(/^Show all \d+ explanations$/).click();
  await glossary.getByLabel('Find a word').fill('Dividend');
  const entry = glossary.locator('.set__row', { has: page.getByText('Dividend', { exact: true }) });
  await entry.getByRole('button', { name: 'Edit the explanation of Dividend' }).click();
  await entry.getByRole('textbox').fill('Money a fund pays you just for owning it.');
  await expect(entry.locator('.set__record')).toContainText(
    'Reworded the explanation of "Dividend".',
  );
  await entry.getByRole('button', { name: 'Yes, save this wording' }).click();
  await expect(page.getByRole('status')).toContainText('Reworded the explanation of "Dividend".');
  const [g] = await rows<{ t: string }>(
    `select kid_text as t from public.glossary where term = 'Dividend'`,
  );
  expect(g.t).toBe('Money a fund pays you just for owning it.');
});

test('Download backup is placed, and off until stage 5', async ({ page }) => {
  await open(page);
  const backup = page.getByRole('region', { name: 'Backup' });
  await expect(backup.getByRole('button', { name: /Download backup/ })).toBeDisabled();
  await expect(backup).toContainText('Arrives in stage 5');
});

test("7 days' notice for a cut, a dividend notice, and cancelling a planned cut", async ({
  page,
}) => {
  const [day] = await rows<Record<string, string>>(
    `select (public.app_today() + 1)::text as soon, public.fmt_date(public.app_today() + 1) as soon_text,
            public.fmt_date(public.app_today() + 7) as cut_text`,
  );
  await open(page);
  const row = page.getByRole('region', { name: 'Rates' }).locator('.set__row', {
    hasText: 'Savings',
  });

  // Dad's case: a savings cut starting tomorrow is refused, and the rule is explained.
  await row.getByRole('button', { name: 'Change the savings rate' }).click();
  const change = row.getByRole('group', { name: 'New savings rate' });
  await expect(change.locator('.set__rule')).toHaveText(
    `A lower rate needs 7 days' notice so the girls can react: it can start on ${day.cut_text} at the earliest. A higher rate can start today.`,
  );
  await change.getByLabel('New rate (% per year)').fill('1.0');
  await change.getByLabel('Starts on').fill(day.soon);
  await expect(change.getByRole('alert')).toHaveText(
    `This would lower the savings rate on ${day.soon_text}, sooner than 7 days from today. A cut needs 7 days' notice so the girls have time to react: start it on ${day.cut_text} or later. A raise can start right away.`,
  );
  await expect(change.getByRole('button', { name: /^Yes, save/ })).toBeDisabled();

  // With 7 days' notice it's saved.
  await change.getByLabel('Starts on').fill('');
  await expect(
    change.getByRole('button', { name: `Yes, save 1.0% from ${day.cut_text}` }),
  ).toBeEnabled();
  await change.getByRole('button', { name: `Yes, save 1.0% from ${day.cut_text}` }).click();
  await expect(page.getByRole('status')).toContainText(
    `Savings rate set to 1.0% from ${day.cut_text}.`,
  );

  // Cancel it before it starts: one notice to each kid, and the history keeps it.
  const planned = row.locator('.set__planned', { hasText: '1.0%' });
  await planned
    .getByRole('button', { name: `Cancel the change planned for ${day.cut_text}` })
    .click();
  const cancel = planned.getByRole('group', { name: 'Cancel this planned change?' });
  await cancel.getByLabel('Note to the girls (optional)').fill('Changed my mind');
  await expect(cancel.locator('.set__notice')).toHaveCount(1);
  const shown = await previewed(cancel);
  expect(
    shown[0].text.startsWith(
      `The savings rate change on ${day.cut_text} is cancelled Changed my mind. `,
    ),
  ).toBe(true);
  await cancel.getByRole('button', { name: 'Yes, cancel this change' }).click();
  await expect(page.getByRole('status')).toContainText(
    `Cancelled: Savings rate set to 1.0% from ${day.cut_text}.`,
  );
  await expect(row.locator('.set__planned', { hasText: '1.0%' })).toHaveCount(0);

  const [check] = await rows<Record<string, string>>(
    `select (select count(*)::text from public.cancellations c join public.rates r on r.id = c.rate_id
              where r.vehicle = 'savings' and r.rate = 1.0) as cancelled,
            (select n.title || ' ' || n.body from public.notifications n where n.account_id = ${SKY}
               and n.dedupe_key like 'cancel:rate:%' order by n.id desc limit 1) as sky,
            (select count(*)::text from public.rates where vehicle = 'savings' and rate = 1.0) as kept`,
  );
  expect(check).toEqual({ cancelled: '1', sky: shown[0].text, kept: '1' });

  // A dividend raise from today: the girls are told, word for word as previewed.
  const yields = page.getByRole('region', { name: 'Dividend yields' });
  await yields.getByRole('button', { name: 'Change the TSX yield' }).click();
  await yields.getByLabel('New yield (% per year)').fill('3.5');
  await expect(yields.locator('.set__notice')).toHaveCount(1);
  const told = await previewed(yields);
  expect(told[0].text).toContain("The TSX fund's dividend rate goes up from 2.8% to 3.5% today");
  await yields.getByRole('button', { name: 'Yes, change to 3.5%' }).click();
  await expect(page.getByRole('status')).toContainText('TSX dividend yield set to 3.5% from');
  const [robin] = await rows<{ t: string }>(
    `select n.title || ' ' || n.body as t from public.notifications n where n.account_id = ${ROBIN}
      and n.dedupe_key like 'yield_change:%' order by n.id desc limit 1`,
  );
  expect(robin.t).toBe(told[0].text);
});

test("resetting a girl's PIN: a one-time code, then she chooses a new PIN at sign-in", async ({
  page,
  browser,
}) => {
  // Second audit, Dad's decision (2026-10-08): Settings → Logins, with the
  // authenticator code, logged, with a notice to her. A throwaway test kid.
  const { resetKid } = logins();
  // She's signed in on a device before the reset (third audit: that session must end at once).
  const before = await (await browser.newContext()).newPage();
  await kidSignIn(before, resetKid.username, resetKid.pin);
  await expect(before).toHaveURL(/\/kid/);
  const token = await before.evaluate(
    () => JSON.parse(localStorage.getItem('bb.auth') ?? '{}').access_token as string,
  );
  const [{ id: account }] = await rows<{ id: string }>(
    `select account_id as id from public.profiles where username = $1`,
    [resetKid.username],
  );
  const anon = readFileSync('.env.local', 'utf8')
    .match(/^VITE_SUPABASE_ANON_KEY=(.*)$/m)![1]
    .trim();
  const readHistory = () =>
    fetch('http://127.0.0.1:54321/rest/v1/rpc/my_activity', {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_account_id: account, p_limit: 5 }),
    });
  expect((await readHistory()).status).toBe(200);
  await open(page);
  const card = page.getByRole('region', { name: 'Logins' });
  await card.getByRole('button', { name: "Reset Reset Test's PIN" }).click();
  await expect(card).toContainText("Reset Test's PIN stops working now");
  await card.getByRole('button', { name: "Reset Reset Test's PIN" }).click();
  await expect(card.getByRole('status')).toContainText('Give Reset Test this code:');
  const code = (await card.locator('.set__code-digits').innerText()).replace(/\s/g, '');
  expect(code).toMatch(/^\d{6}$/);
  expect(await lastLog()).toMatchObject({
    summary: "Reset Reset Test's PIN. She chooses a new one at her next sign-in.",
  });
  await expect(card).toContainText('Waiting for her to choose a new PIN');
  // The device she was signed in on stops working straight away, not when its token runs out.
  expect((await readHistory()).status).not.toBe(200);
  await before.context().close();

  // Her old PIN no longer works.
  const kidPage = await (await browser.newContext()).newPage();
  await kidSignIn(kidPage, resetKid.username, resetKid.pin);
  await expect(kidPage.getByRole('alert')).toContainText("That PIN didn't match");

  // Dad's code, then a new PIN twice (a mismatch first).
  const fresh = code === '135790' ? '246802' : '135790';
  await typePin(kidPage, code);
  await expect(kidPage.getByText('Dad reset your PIN. Choose a new 6-digit PIN.')).toBeVisible();
  await typePin(kidPage, fresh);
  await expect(kidPage.getByText('Type your new PIN again')).toBeVisible();
  await typePin(kidPage, '000111');
  await expect(kidPage.getByRole('alert')).toHaveText(
    "Those didn't match. Choose your new PIN again.",
  );
  await typePin(kidPage, fresh);
  await typePin(kidPage, fresh);
  await expect(kidPage).toHaveURL(/\/kid/);
  await kidPage.context().close();

  // Next time, the new PIN is her PIN.
  const again = await (await browser.newContext()).newPage();
  await kidSignIn(again, resetKid.username, fresh);
  await expect(again).toHaveURL(/\/kid/);
  await again.context().close();
  const [n] = await rows<{ title: string }>(
    `select title from public.notifications
      where account_id = (select account_id from public.profiles where username = $1)
        and title = 'Dad reset your PIN'`,
    [resetKid.username],
  );
  expect(n?.title).toBe('Dad reset your PIN');
});
