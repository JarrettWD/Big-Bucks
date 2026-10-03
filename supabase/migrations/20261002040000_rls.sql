-- Stage 1: row-level security and grants.
--
-- Reads:
--   * A kid sees only her own account's rows.
--   * A parent (signed in with MFA, see is_parent()) sees everything.
--   * Shared reference tables (funds, rates, prices, holidays, glossary) are
--     readable by every signed-in user. Kids see notes meant for kids, and every
--     setting except the environment keys is_local_dev and clock_override.
--   * Parent-only tables (wishlist_parent_marks, alerts, login_attempts,
--     job_runs) are invisible to kids.
--   * Anonymous callers see nothing.
-- Writes: nobody writes directly, not even the service role. Every change goes
-- through a SECURITY DEFINER function, added in later stages.

-- 1. Grants: SELECT only, for signed-in users and the service role.
revoke all on all tables in schema public from public, anon, authenticated, service_role;
revoke all on all sequences in schema public from public, anon, authenticated, service_role;
grant select on all tables in schema public to authenticated, service_role;

-- Tables and functions created by later migrations start with no grants at all,
-- so each one must be opened up on purpose (the RLS safety-net test checks this).
alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated, service_role;

-- 2. RLS on every table.
alter table public.accounts              enable row level security;
alter table public.profiles              enable row level security;
alter table public.funds                 enable row level security;
alter table public.rates                 enable row level security;
alter table public.fund_prices           enable row level security;
alter table public.market_holidays       enable row level security;
alter table public.glossary              enable row level security;
alter table public.gic_holdings          enable row level security;
alter table public.requests              enable row level security;
alter table public.transactions          enable row level security;
alter table public.interest_accruals     enable row level security;
alter table public.job_runs              enable row level security;
alter table public.notes                 enable row level security;
alter table public.alerts                enable row level security;
alter table public.login_attempts        enable row level security;
alter table public.questions             enable row level security;
alter table public.wishlist_items        enable row level security;
alter table public.wishlist_parent_marks enable row level security;
alter table public.goals                 enable row level security;
alter table public.badges                enable row level security;
alter table public.notifications         enable row level security;
-- settings already has RLS on (stage 0).

-- 3. Read policies. (select f()) lets Postgres evaluate the helper once per query.

-- Her own account and profile
create policy accounts_read on public.accounts for select to authenticated
  using (id = (select public.my_account_id()) or (select public.is_parent()));

create policy profiles_read on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_parent()));

-- Rows that belong to one account
create policy gic_holdings_read on public.gic_holdings for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy requests_read on public.requests for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy transactions_read on public.transactions for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy interest_accruals_read on public.interest_accruals for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy questions_read on public.questions for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy wishlist_items_read on public.wishlist_items for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy goals_read on public.goals for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy badges_read on public.badges for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
create policy notifications_read on public.notifications for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));

-- Shared reference data
create policy funds_read on public.funds for select to authenticated using (true);
create policy rates_read on public.rates for select to authenticated using (true);
create policy fund_prices_read on public.fund_prices for select to authenticated using (true);
create policy market_holidays_read on public.market_holidays for select to authenticated using (true);
create policy glossary_read on public.glossary for select to authenticated using (true);

create policy notes_read on public.notes for select to authenticated
  using (audience = 'kids' or (select public.is_parent()));

create policy settings_read on public.settings for select to authenticated
  using (key not in ('is_local_dev', 'clock_override') or (select public.is_parent()));

-- Parent only
create policy job_runs_read on public.job_runs for select to authenticated
  using ((select public.is_parent()));
create policy alerts_read on public.alerts for select to authenticated
  using ((select public.is_parent()));
create policy login_attempts_read on public.login_attempts for select to authenticated
  using ((select public.is_parent()));
create policy wishlist_parent_marks_read on public.wishlist_parent_marks for select to authenticated
  using ((select public.is_parent()));
