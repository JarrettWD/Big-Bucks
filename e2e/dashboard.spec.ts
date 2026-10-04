// Stage 8 B1 against the LOCAL Supabase (demo data): Dad's dashboard. It only reads,
// so it runs with the layout checks, before other tests change the demo. Each check
// is against the database.
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money.ts';
import { parentSignIn } from './helpers';

async function rows<T = Record<string, string>>(sql: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql)) as T[];
  } finally {
    await db.close();
  }
}

test('the girls, what you owe them and what is waiting, as the database has them', async ({
  page,
}) => {
  const kids = await rows<{ name: string; worth: string; is_test: boolean }>(
    `select a.name, b.total_worth_cents::text as worth, a.is_test from public.account_balances b
       join public.accounts a on a.id = b.account_id`,
  );
  const [counts] = await rows<{ owe: string; waiting: string }>(
    `select (select coalesce(sum(total_worth_cents), 0) from public.account_balances where not is_test)::text as owe,
            ((select count(*) from public.requests where status = 'pending' and type in ('deposit', 'withdraw'))
             + (select count(*) from public.questions where status = 'open'))::text as waiting`,
  );
  await parentSignIn(page);
  const girls = page.getByRole('region', { name: 'The girls' });
  for (const k of kids)
    await expect(girls.locator('li', { hasText: k.name }).first()).toContainText(
      formatCents(k.worth),
    );
  await expect(girls.locator('.dash__owe')).toContainText(formatCents(counts.owe));
  await expect(girls.locator('li', { hasText: 'Sky' }).first()).toContainText('Test');
  await expect(page.getByRole('region', { name: 'Needs you' })).toContainText(
    `${counts.waiting} things waiting for you`,
  );
});

test("requests running out of time: Robin's in the database's words, Sky's folded away", async ({
  page,
}) => {
  const [robin] = await rows<{ rel: string }>(
    `select public.fmt_relative(r.expires_at) as rel from public.requests r
       join public.profiles p on p.account_id = r.account_id
      where p.username = 'demo_robin' and r.status = 'pending' and r.amount_cents = 2500`,
  );
  await parentSignIn(page);
  const needs = page.getByRole('region', { name: 'Needs you' });
  const warning = needs.getByRole('link', { name: /Robin's \$25\.00 deposit/ });
  await expect(warning).toHaveText(
    new RegExp(`^Robin's \\$25\\.00 deposit expires ${robin.rel} \\(in \\d+ hours?\\)\\.$`),
  );
  // Sky is a test account: her warning is folded away until opened.
  const sky = needs.getByText(/Sky's \$8\.00 deposit expires/);
  await expect(sky).toBeHidden();
  await needs.getByText('Test accounts (1)').click();
  await expect(sky).toBeVisible();
  // A warning goes straight to Approvals.
  await warning.click();
  await expect(page.getByRole('heading', { name: 'Approvals', level: 1 })).toBeVisible();
});

test('GICs coming due, and whether each girl has read each notice', async ({ page }) => {
  const notices = await rows<{ title: string; read: boolean }>(
    `select n.title, n.read_at is not null as read from public.notifications n
       join public.profiles p on p.account_id = n.account_id
      where p.username = 'demo_robin' and n.type in ('rate_change', 'rate_live', 'cap_change', 'rule_change')
        and n.created_at >= public.app_now() - interval '30 days'`,
  );
  expect(notices.length, 'the demo has rate notices in the last 30 days').toBeGreaterThan(0);
  await parentSignIn(page);
  await expect(page.getByRole('region', { name: 'GICs coming due' })).toContainText(
    'Waiting for her choice',
  );
  const read = page.getByRole('region', { name: 'Have they read it? (last 30 days)' });
  for (const n of notices) {
    const item = read.locator('li', { hasText: n.title }).first();
    await expect(item).toContainText(n.read ? /Robin: Read / : /Robin: Not read yet/);
  }
});
