// Stage 8 B4 against the LOCAL Supabase (demo data): onboarding end to end with
// Wren, the demo kid who hasn't started, as Dad reviewed it (2026-10-07):
//   - Dad's "View as" shows her welcome read-only;
//   - until she's done, the app is locked to onboarding: greyed tabs and bell
//     that say why when tapped, and typed addresses that bring her back (all six
//     sizes, normal and large text);
//   - one button to start, a required tour, and she resumes where she left off
//     (after a reload, and after signing out and in);
//   - the agreement and her signature; her first deposit asked for inside her
//     first decision;
//   - Dad's prominent Dashboard card and the Approvals badge, then countersigning;
//   - a declined first deposit (with Dad's reason) asked again from the same step;
//   - the app unlocking once both have signed and her deposit is in, a GIC choice
//     opening Buy / Sell, her history, and What's new;
//   - the Approvals order (agreements, deposits and withdrawals, questions; oldest
//     first, girls mixed; test accounts after).
// Each step is checked against the database. Runs last, in its own project.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn, typePin } from './helpers';
import { check, SIZES, TEXT } from './layoutCheck';

test.describe.configure({ mode: 'serial' });

const WREN = `(select account_id from public.profiles where username = 'demo_wren')`;
const LOCKED = 'Finish setting up first, then all of Big Bucks is yours!';

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
  await expect(page).toHaveURL(/\/kid\/welcome/);
}

/** Every way out of onboarding is closed: tabs, the bell, and typed addresses. */
async function expectLocked(page: Page) {
  const tabs = page.getByRole('navigation', { name: 'Main' }).getByRole('button');
  await expect(tabs).toHaveText([/Home/, /Graphs/, /Buy \/ Sell/]);
  for (const name of ['Home', 'Graphs', 'Buy / Sell']) {
    const tab = page.getByRole('navigation', { name: 'Main' }).getByRole('button', { name });
    await expect(tab).toHaveAttribute('aria-disabled', 'true');
    await tab.click({ force: true }); // a real tap still reaches a greyed-out tab
    await expect(page.locator('#kid-locked')).toHaveText(LOCKED);
    await expect(page).toHaveURL(/\/kid\/welcome/);
  }
  const bell = page.getByRole('button', { name: 'Notices' });
  await expect(bell).toHaveAttribute('aria-disabled', 'true');
  await bell.click({ force: true });
  await expect(page.locator('#kid-locked')).toHaveText(LOCKED);
  await expect(page).toHaveURL(/\/kid\/welcome/);
  for (const address of [
    './kid',
    './kid/trade',
    './kid/graphs',
    './kid/history',
    './kid/notices',
    './kid/gic/1',
  ]) {
    await page.goto(address);
    await expect(page).toHaveURL(/\/kid\/welcome/);
    await expect(page.locator('.welcome__card')).toBeVisible();
  }
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

test('until she is done, the app is locked to onboarding (all six sizes)', async ({ page }) => {
  test.setTimeout(240_000);
  const before = await footprint();
  await wrenSignIn(page);
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await expectLocked(page);
    // The friendly line, showing, at each size with normal and large text.
    for (const text of TEXT) {
      await page.goto('./kid/welcome');
      await page
        .getByRole('navigation', { name: 'Main' })
        .getByRole('button', { name: 'Graphs' })
        .click({ force: true });
      await expect(page.locator('#kid-locked')).toHaveText(LOCKED);
      await check(page, `onboarding-locked-${size.name}-${text.name}`, text.scale);
    }
  }
  expect(await footprint()).toBe(before);
});

test('one button to start, a required tour, and she resumes where she left off', async ({
  page,
}) => {
  await wrenSignIn(page);
  const card = page.locator('.welcome__card');
  await expect(card.getByRole('heading', { name: 'Welcome to Big Bucks, Wren!' })).toBeVisible();
  await expect(card.getByRole('button')).toHaveText(["Let's get started"]);
  await expect(card.getByRole('link')).toHaveCount(0);
  await expect(page.locator('.welcome__steps li')).toHaveText([
    'A quick look around',
    'Your Big Bucks agreement',
    'Your first decision',
  ]);
  await card.getByRole('button', { name: "Let's get started" }).click();

  // The tour: Next and Back only, with today's rates.
  await expect(page.getByRole('heading', { name: 'Home 🏠' })).toBeVisible();
  await expect(page.locator('.welcome__buttons').getByRole('button')).toHaveText(['Next', 'Back']);
  await page.getByRole('button', { name: 'Next' }).click();
  const r = await one<{ lo: string; hi: string; sav: string }>(
    `select public.house_rules() ->> 'gic_lowest' as lo, public.house_rules() ->> 'gic_highest' as hi,
            public.house_rules() ->> 'savings_rate' as sav`,
  );
  await expect(page.getByText(`right now from ${r.lo} to ${r.hi} a year`)).toBeVisible();
  await expect(page.getByText(`It earns ${r.sav} a year in interest`)).toBeVisible();
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.locator('.welcome__count')).toHaveText('3 / 5');

  // She leaves and comes back: same card, from the database.
  await expect
    .poll(
      async () =>
        (
          await one<{ s: string }>(
            `select onboarding_step || ' ' || onboarding_card as s from public.accounts where id = ${WREN}`,
          )
        ).s,
    )
    .toBe('tour 2');
  await page.reload();
  await expect(page.locator('.welcome__count')).toHaveText('3 / 5');
  await page.getByRole('button', { name: 'Sign out' }).click();
  // This device remembers her: just her PIN.
  await expect(page.getByRole('heading', { name: 'Hi, Wren!' })).toBeVisible();
  await typePin(page, kid('Wren').pin);
  await expect(page).toHaveURL(/\/kid\/welcome/);
  await expect(page.getByRole('heading', { name: 'Graphs 📊' })).toBeVisible();
  await expect(page.locator('.welcome__count')).toHaveText('3 / 5');
});

test("she signs the agreement: Dad's reviewed wording, today's numbers", async ({ page }) => {
  await wrenSignIn(page);
  // From the tour card she was on to the agreement.
  for (const b of ['Next', 'Next', 'Done']) await page.getByRole('button', { name: b }).click();
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
    `select count(*)::text as n, bool_and(s.copy = public.agreement_render(1, s.account_id)) as same
       from public.agreement_signatures s where s.account_id = ${WREN} and s.signer = 'kid'`,
  );
  expect(sig).toEqual({ n: '1', same: true });

  // Her first deposit, asked for inside her first decision (the rest is still locked).
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByText('Your first decision starts with your first deposit.')).toBeVisible();
  await page.getByLabel('How much would you like to put in?').fill('20');
  await expect(page.getByText("You're asking Dad to put in $20.00.")).toBeVisible();
  await page.getByRole('button', { name: 'Ask Dad' }).click();
  await expect(page.getByText('You asked to put in $20.00. Waiting for Dad.')).toBeVisible();
  const req = await one(
    `select type::text, amount_cents::text, status::text from public.requests where account_id = ${WREN}`,
  );
  expect(req).toEqual({ type: 'deposit', amount_cents: '2000', status: 'pending' });
  await expectLocked(page);
  await expect(page.getByText('You asked to put in $20.00. Waiting for Dad.')).toBeVisible();
});

/** Dad's part through the database: approve or decline Wren's waiting deposit. */
async function dadAnswers(how: 'approve' | 'decline', reason?: string) {
  const db = await LocalDb.connect();
  try {
    const [{ id, parent_user }] = await db.q<{ id: string; parent_user: string }>(
      `select (select id::text from public.requests where account_id = ${WREN} and status = 'pending') as id,
              (select user_id::text from public.profiles where role = 'parent' limit 1) as parent_user`,
    );
    const ok = await db.call(
      { role: 'authenticated', sub: parent_user, aal: 'aal2' },
      how === 'approve'
        ? 'select public.approve_request($1)'
        : 'select public.decline_request($1, $2)',
      how === 'approve' ? [Number(id)] : [Number(id), reason],
    );
    expect(ok.ok).toBe(true);
  } finally {
    await db.close();
  }
}

test('Dad says no to her first deposit: she sees why and asks again from the same step', async ({
  page,
}) => {
  await dadAnswers('decline', "Let's start with $10");
  await wrenSignIn(page);
  await expect(page.getByText('Your first decision starts with your first deposit.')).toBeVisible();
  const answer = page.locator('.welcome__answer');
  await expect(answer).toHaveText(
    /Dad said not this time\.\s*Dad says: “Let's start with \$10”\s*You can ask again\./,
  );
  await page.getByLabel('How much would you like to put in?').fill('10');
  await page.getByRole('button', { name: 'Ask Dad' }).click();
  await expect(page.getByText('You asked to put in $10.00. Waiting for Dad.')).toBeVisible();
  await expect(answer).toHaveCount(0);
  const reqs = await rows(
    `select amount_cents::text as amount, status::text from public.requests where account_id = ${WREN} order by id`,
  );
  expect(reqs).toEqual([
    { amount: '2000', status: 'declined' },
    { amount: '1000', status: 'pending' },
  ]);
  await expectLocked(page);
});

test('Dad: a highlighted card at the top of the Dashboard, the Approvals badge, then he signs', async ({
  page,
}) => {
  test.setTimeout(180_000);
  await parentSignIn(page);
  const badge = async () => {
    const n = await one<{ n: string }>(
      `select ((select count(*) from public.requests where status = 'pending' and type in ('deposit', 'withdraw'))
             + (select count(*) from public.questions where status = 'open'))::text as n`,
    );
    return Number(n.n);
  };
  const before = await badge();
  const tab = page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: /^Approvals/ });
  await expect(tab).toHaveAttribute('aria-label', `Approvals, ${before + 1} waiting`);

  const card = page.locator('.dash__sign-card', { hasText: 'Wren' });
  await expect(card).toHaveText(
    /✍️ Wren signed her agreement — she's waiting for you\s*Sign it now/,
  );
  const top = (await card.boundingBox())!.y;
  const needs = (await page.getByRole('heading', { name: 'Needs you' }).boundingBox())!.y;
  expect(top).toBeLessThan(needs);
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    for (const text of TEXT)
      await check(page, `dash-sign-card-${size.name}-${text.name}`, text.scale);
  }
  await page.setViewportSize({ width: 412, height: 915 });

  await card.getByRole('link', { name: 'Sign it now' }).click();
  await expect(page).toHaveURL(/\/parent\/approvals#agreements$/);
  const item = page.locator('.appr__card', { hasText: 'Wren signed her Big Bucks agreement' });
  const fp = await footprint();
  await item.getByRole('button', { name: 'Read and sign' }).click();
  await expect(item.locator('.agree__rule')).toHaveCount(15);
  await expect(item.locator('.appr__notice')).toHaveText(
    /Your agreement is signed!\s*Dad signed it too\. You can read it any time in your history\./,
  );
  await item.getByRole('button', { name: 'Back' }).click();
  expect(await footprint()).toBe(fp);

  await item.getByRole('button', { name: 'Read and sign' }).click();
  await item.getByRole('button', { name: "Yes, sign Wren's agreement" }).click();
  const log = await one<{ summary: string; when: string; who: string }>(
    `select pa.summary, public.fmt_moment(pa.done_at) as when, p.display_name as who
       from public.parent_actions pa join public.profiles p on p.user_id = pa.done_by
      where pa.action = 'countersign_agreement' and pa.account_id = ${WREN}`,
  );
  expect(log.summary).toBe("Signed Wren's Big Bucks agreement.");
  await expect(page.locator('#agreements .appr__done')).toHaveText(
    `Done. ${log.summary} Recorded: ${log.who}, ${log.when}.`,
  );
  await expect(tab).toHaveAttribute('aria-label', `Approvals, ${before} waiting`);
  const n = await one(
    `select title, body from public.notifications where account_id = ${WREN} and type = 'agreement'`,
  );
  expect(n).toEqual({
    title: 'Your agreement is signed!',
    body: 'Dad signed it too. You can read it any time in your history.',
  });
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: 'Dashboard' })
    .click();
  await expect(page.getByRole('heading', { name: 'Needs you' })).toBeVisible();
  await expect(page.locator('.dash__sign-card')).toHaveCount(0);
});

test('once both have signed and her first deposit is in, the app is hers: a GIC opens Buy / Sell', async ({
  page,
}) => {
  await dadAnswers('approve');
  // Unlocked: she lands on Home, which offers to finish her first decision.
  const w = kid('Wren');
  await kidSignIn(page, w.username, w.pin);
  await expect(page).toHaveURL(/\/kid$/);
  await expect(page.getByText("👋 Let's finish setting up your Big Bucks.")).toBeVisible();
  await page.getByRole('link', { name: 'Keep going' }).click();
  await expect(
    page.getByRole('heading', { name: '🎉 Your first $10.00 is in your savings!' }),
  ).toBeVisible();
  // Unlocked before she has even chosen: real tabs and bell, no friendly line.
  const nav = page.getByRole('navigation', { name: 'Main' });
  await expect(nav.getByRole('link', { name: 'Buy / Sell' })).toBeVisible();
  await expect(nav.getByRole('button')).toHaveCount(0);
  await expect(page.locator('#kid-locked')).toHaveCount(0);
  const unlocked = await one<{ u: string; done: boolean }>(
    `select public.onboarding_state(${WREN}) ->> 'unlocked' as u,
            (select onboarding_done_at is not null from public.accounts where id = ${WREN}) as done`,
  );
  expect(unlocked).toEqual({ u: 'true', done: false });

  // $10 is enough for a GIC or a fund: all three choices. A GIC opens Buy / Sell.
  await expect(page.locator('.welcome__choice')).toHaveCount(3);
  await page.getByRole('button', { name: /Put some in a GIC/ }).click();
  await expect(page).toHaveURL(/\/kid\/trade$/);
  await expect(page.getByLabel('From')).toBeVisible();
  await expect(page.getByLabel('To')).toBeVisible();
  const done = await one<{ done: boolean }>(
    `select onboarding_done_at is not null as done from public.accounts where id = ${WREN}`,
  );
  expect(done.done).toBe(true);

  // Everything else works too, and her agreement is in her history.
  await page.goto('./kid/history');
  await expect(page).toHaveURL(/\/kid\/history$/);
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
  const w = kid('Wren');
  await kidSignIn(page, w.username, w.pin);
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

test('Approvals: agreements, then deposits and withdrawals, then questions; oldest first, girls mixed; test accounts after', async ({
  page,
}) => {
  // Requests at known times, the girls interleaved: Robin 5 h ago, Wren 4 h ago,
  // Robin 3 h ago; Sky (a test account) 6 h ago, first of all but in her own section.
  await rows(
    `insert into public.requests (account_id, type, to_vehicle, amount_cents, created_at)
     select a.id, 'deposit', 'savings', x.cents, public.app_now() - x.ago
       from (values ('demo_robin', 1100, interval '5 hours'), ('demo_wren', 1200, interval '4 hours'),
                    ('demo_robin', 1300, interval '3 hours'), ('demo_sky', 1400, interval '6 hours')) x(who, cents, ago)
       join public.profiles p on p.username = x.who join public.accounts a on a.id = p.account_id`,
  );
  await parentSignIn(page);
  await page
    .getByRole('navigation', { name: 'Parent' })
    .getByRole('link', { name: /^Approvals/ })
    .click();
  await expect(page.locator('.appr__sections > section > h2')).toHaveText([
    /^Agreements to sign/,
    /^Deposits and withdrawals/,
    /^Questions/,
  ]);
  // The test-account section comes after all of the real kids' sections.
  const realBottom = (await page.locator('.appr__sections').boundingBox())!;
  const testTop = (await page.locator('.appr__test-accounts').boundingBox())!;
  expect(testTop.y).toBeGreaterThanOrEqual(realBottom.y + realBottom.height);

  // Each section strictly by when she asked, oldest first: the "Asked …" on each
  // card, top to bottom, is the database's order.
  for (const test of [false, true]) {
    const expected = await rows<{ asked: string }>(
      `select 'Asked ' || public.fmt_moment(r.created_at) as asked
         from public.requests r join public.accounts a on a.id = r.account_id
        where r.status = 'pending' and r.type in ('deposit', 'withdraw') and a.is_test = $1
        order by r.created_at, r.id`,
      [test],
    );
    await expect(
      page.locator(`section[aria-labelledby="appr-money-${test}"] .appr__card .appr__line`, {
        hasText: /^Asked /,
      }),
    ).toHaveText(expected.map((e) => e.asked));
  }
  // The planted ones in their places: Robin, Wren, Robin (real); Sky in her own section.
  const real = await page
    .locator('section[aria-labelledby="appr-money-false"] .appr__card')
    .allInnerTexts();
  const iR1 = real.findIndex((t) => t.includes('$11.00'));
  const iW = real.findIndex((t) => t.includes('$12.00'));
  const iR2 = real.findIndex((t) => t.includes('$13.00'));
  expect(iR1).toBeGreaterThanOrEqual(0);
  expect(iR1 < iW && iW < iR2).toBe(true);
  await expect(
    page.locator('section[aria-labelledby="appr-money-true"] .appr__card', { hasText: '$14.00' }),
  ).toHaveCount(1);
  // Every card says when she asked.
  for (const c of await page.locator('.appr__card').all()) await expect(c).toContainText('Asked ');
});
