-- Security tests: row-level security, grants and the "nobody writes directly" rule.
--
-- Cast: kid A, kid B (a test account, which must behave like any other kid) and a
-- parent. All names and ids are made up. Everything runs in one transaction that
-- is rolled back, so nothing persists.
begin;
select plan(45);

-- Test helpers --------------------------------------------------------------

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Pretend to be a signed-in user. Call it, then `set local role authenticated`.
create function tests.act_as(p_user uuid, p_aal text default 'aal1') returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;

-- Every table in public, for the loops below.
create function tests.all_tables() returns setof text
language sql stable as $$
  select c.relname::text
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
   order by 1;
$$;

-- Tables in which the caller can see any row belonging to p_account.
create function tests.tables_showing_account(p_account uuid) returns text[]
language plpgsql as $$
declare
  t text;
  n bigint;
  found text[] := '{}';
begin
  for t in
    select table_name from information_schema.columns
     where table_schema = 'public' and column_name = 'account_id'
     order by 1
  loop
    execute format('select count(*) from public.%I where account_id = $1', t) into n using p_account;
    if n > 0 then found := found || t; end if;
  end loop;
  return found;
end;
$$;

-- Tries INSERT, UPDATE, DELETE and TRUNCATE on every table as the current role.
-- Returns every attempt that was NOT refused for lack of privilege.
create function tests.write_attempts_not_refused() returns text[]
language plpgsql as $$
declare
  t text;
  first_col text;
  op text;
  stmt text;
  problems text[] := '{}';
begin
  for t in select * from tests.all_tables() loop
    select a.attname into first_col
      from pg_attribute a
     where a.attrelid = ('public.' || quote_ident(t))::regclass and a.attnum > 0
       and not a.attisdropped and a.attidentity = '' and a.attgenerated = ''
     order by a.attnum
     limit 1;
    foreach op in array array['insert', 'update', 'delete', 'truncate'] loop
      stmt := case op
        when 'insert'   then format('insert into public.%I default values', t)
        when 'update'   then format('update public.%I set %I = %I', t, first_col, first_col)
        when 'delete'   then format('delete from public.%I', t)
        when 'truncate' then format('truncate public.%I cascade', t)
      end;
      begin
        execute stmt;
        problems := problems || (t || ' ' || op || ': allowed');
      exception
        when insufficient_privilege then null;  -- refused, as it should be
        when others then problems := problems || (t || ' ' || op || ': ' || sqlstate);
      end;
    end loop;
  end loop;
  return problems;
end;
$$;

-- Tables where the caller sees fewer rows than really exist.
create table tests.true_counts (table_name text primary key, n bigint not null);
grant select on tests.true_counts to authenticated;

create function tests.tables_not_fully_visible() returns text[]
language plpgsql as $$
declare
  r record;
  n bigint;
  found text[] := '{}';
begin
  for r in select * from tests.true_counts order by 1 loop
    execute format('select count(*) from public.%I', r.table_name) into n;
    if n <> r.n then found := found || (r.table_name || ' ' || n || '/' || r.n); end if;
  end loop;
  return found;
end;
$$;

-- Fixture: two kids and a parent, with rows in every table -------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'kid-a@test.invalid'),
  ('00000000-0000-0000-0000-00000000000b', 'kid-b@test.invalid'),
  ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');

insert into public.accounts (id, name, is_test) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Test Kid A', false),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Test Kid B', true);

insert into public.profiles (user_id, role, account_id, username, display_name) values
  ('00000000-0000-0000-0000-00000000000a', 'investor', 'aaaaaaaa-0000-0000-0000-000000000001', 'test_kid_a', 'Kid A'),
  ('00000000-0000-0000-0000-00000000000b', 'investor', 'bbbbbbbb-0000-0000-0000-000000000002', 'test_kid_b', 'Kid B'),
  ('00000000-0000-0000-0000-00000000000f', 'parent',   null,                                   'test_parent', 'Parent');

-- One of each kid-owned row, for both kids.
do $$
declare
  acct uuid;
  v_gic bigint;
  v_req bigint;
  v_tx bigint;
  v_item uuid;
begin
  foreach acct in array array['aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002']::uuid[] loop
    insert into public.requests (account_id, type, to_vehicle, amount_cents)
      values (acct, 'deposit', 'savings', 5000) returning id into v_req;
    insert into public.transactions (account_id, vehicle, type, amount_cents, request_id, posting_key)
      values (acct, 'savings', 'deposit', 5000, v_req, 'test:deposit:' || acct) returning id into v_tx;
    insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
      values (acct, 1000, 5.000, 12, date '2026-10-01', date '2027-10-01') returning id into v_gic;
    insert into public.interest_accruals (account_id, accrual_date, balance_cents, rate, days_in_year, accrued)
      values (acct, date '2026-10-01', 5000, 2.000, 365, 0.27397260);
    insert into public.questions (account_id, transaction_id, message) values (acct, v_tx, 'Is this right?');
    insert into public.wishlist_items (account_id, name, price_cents, stars) values (acct, 'Kite', 2500, 4)
      returning id into v_item;
    insert into public.wishlist_parent_marks (wishlist_item_id, note) values (v_item, 'Bought it');
    insert into public.goals (account_id, name, target_cents) values (acct, 'Kite', 2500);
    insert into public.badges (account_id, badge) values (acct, 'first_gic');
    insert into public.notifications (account_id, type, title, body, related_gic_id)
      values (acct, 'gic_maturity', 'Your GIC is ready', 'Choose what happens next.', v_gic);
    insert into public.alerts (kind, account_id, message) values ('test', acct, 'Test alert');
  end loop;
end;
$$;

insert into public.login_attempts (username, succeeded) values ('test_kid_a', false);
insert into public.job_runs (job, run_for_date, status) values ('interest', date '2026-10-01', 'ok');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', date '2026-10-01', 420.12000000);
insert into public.notes (note_date, body, audience) values
  (date '2026-10-01', 'Big drop today.', 'kids'),
  (date '2026-10-01', 'Parent-only note.', 'parent');

insert into tests.true_counts
  select t, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', t), false, true, '')))[1]::text::bigint
    from tests.all_tables() t;

-- 1. The safety net: every table, now and in future stages ------------------

select is(
  array(select c.relname::text from pg_class c
         where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity
         order by 1),
  '{}'::text[],
  'every table has row-level security on');

select is(
  array(select t from tests.all_tables() t
         where not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = t)),
  '{}'::text[],
  'every table has a read policy');

select is(
  array(select r || ' ' || p || ' ' || t
          from tests.all_tables() t,
               unnest(array['anon', 'authenticated', 'service_role']) r,
               unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
         where has_table_privilege(r, 'public.' || quote_ident(t), p)
         order by 1),
  '{}'::text[],
  'no app role holds any write privilege on any table');

select is(
  array(select r || ' ' || p || ' ' || t
          from tests.all_tables() t,
               unnest(array['anon', 'authenticated', 'service_role']) r,
               unnest(array['INSERT', 'UPDATE']) p
         where has_any_column_privilege(r, 'public.' || quote_ident(t), p)
         order by 1),
  '{}'::text[],
  'no app role holds a column-level INSERT or UPDATE grant');

select is(
  array(select t from tests.all_tables() t where has_table_privilege('anon', 'public.' || quote_ident(t), 'SELECT')),
  '{}'::text[],
  'anonymous callers cannot read any table');

select is(
  array(select c.relname::text from pg_class c
         where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
           and not coalesce('security_invoker=true' = any (c.reloptions), false)),
  '{}'::text[],
  'every view (none yet) runs with the caller''s permissions, so RLS applies');

select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.prosecdef
           and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
  '{}'::text[],
  'every SECURITY DEFINER function has a fixed search_path');

select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')
         order by 1),
  '{}'::text[],
  'anonymous callers cannot run any function');

select set_eq(
  $$select c.table_name::text from information_schema.columns c
      join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'public' and c.column_name = 'account_id' and t.table_type = 'BASE TABLE'$$,
  array['alerts', 'badges', 'gic_holdings', 'goals', 'interest_accruals', 'notifications',
        'profiles', 'questions', 'requests', 'transactions', 'wishlist_items'],
  'the account-scoped tables are the ones this test seeds (update both when adding a table)');

-- 2. Kid A ------------------------------------------------------------------

select tests.act_as('00000000-0000-0000-0000-00000000000a');
set local role authenticated;

select is(tests.tables_showing_account('bbbbbbbb-0000-0000-0000-000000000002'), '{}'::text[],
  'kid A sees none of kid B''s rows in any account-scoped table');
select is(
  array(select t from unnest(array['badges', 'gic_holdings', 'goals', 'interest_accruals', 'notifications',
                                   'profiles', 'questions', 'requests', 'transactions', 'wishlist_items']) t
         where t <> all (tests.tables_showing_account('aaaaaaaa-0000-0000-0000-000000000001'))),
  '{}'::text[],
  'kid A sees her own rows in every kid table');
select is((select count(*) from public.accounts), 1::bigint, 'kid A sees exactly one account');
select is((select id from public.accounts), 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, '...and it is her own');
select is((select count(*) from public.profiles), 1::bigint, 'kid A sees only her own profile');
select is((select count(*) from public.wishlist_parent_marks), 0::bigint, 'kid A cannot see "Got it" markers, even on her own items');
select is((select count(*) from public.alerts), 0::bigint, 'kid A cannot see alerts, even about her own account');
select is((select count(*) from public.login_attempts), 0::bigint, 'kid A cannot see login attempts');
select is((select count(*) from public.job_runs), 0::bigint, 'kid A cannot see job runs');
select is((select count(*) from public.notes), 1::bigint, 'kid A sees only notes meant for kids');
select is((select count(*) from public.funds), 3::bigint, 'kid A can read the funds');
select is((select count(*) from public.rates), 7::bigint, 'kid A can read the rates');
select is((select count(*) from public.fund_prices), 1::bigint, 'kid A can read fund prices');
select ok((select count(*) from public.market_holidays) > 0, 'kid A can read market holidays');
select ok((select count(*) from public.glossary) > 0, 'kid A can read the glossary');
select is((select value from public.settings where key = 'deposit_cap_cents'), '100000', 'kid A can read the deposit cap');
select is((select count(*) from public.settings where key in ('is_local_dev', 'clock_override')), 0::bigint,
  'kid A cannot see the environment settings');
select is(tests.write_attempts_not_refused(), '{}'::text[],
  'kid A is refused INSERT, UPDATE, DELETE and TRUNCATE on every table');
select throws_ok(
  $$insert into public.requests (account_id, type, to_vehicle, amount_cents)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'deposit', 'savings', 500)$$,
  '42501', null, 'kid A cannot even insert her own request directly');

reset role;

-- 3. Kid B, a test account, is just as isolated ------------------------------

select tests.act_as('00000000-0000-0000-0000-00000000000b');
set local role authenticated;

select is(tests.tables_showing_account('aaaaaaaa-0000-0000-0000-000000000001'), '{}'::text[],
  'kid B (a test account) sees none of kid A''s rows');
select is((select count(*) from public.accounts), 1::bigint, 'kid B sees only her own account');
select is((select count(*) from public.alerts), 0::bigint, 'kid B cannot see alerts');

reset role;

-- 4. The parent -------------------------------------------------------------

select tests.act_as('00000000-0000-0000-0000-00000000000f', 'aal2');
set local role authenticated;

select is(tests.tables_not_fully_visible(), '{}'::text[], 'the parent (with MFA) reads every row of every table');
select is((select count(*) from public.settings where key = 'is_local_dev') > 0, true,
  'the parent can see the environment settings');
select is(tests.write_attempts_not_refused(), '{}'::text[],
  'the parent is refused direct writes too (writes go through functions)');

reset role;

-- Parent without the second factor
select tests.act_as('00000000-0000-0000-0000-00000000000f', 'aal1');
set local role authenticated;

select is((select count(*) from public.profiles), 1::bigint, 'a parent without MFA sees only their own profile');
select is((select count(*) from public.accounts), 0::bigint, 'a parent without MFA sees no accounts');
select is((select count(*) from public.transactions), 0::bigint, 'a parent without MFA sees no ledger rows');
select is((select count(*) from public.alerts), 0::bigint, 'a parent without MFA sees no alerts');

reset role;

-- 5. Anonymous and the service role -----------------------------------------

select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok('select count(*) from public.transactions', '42501', null, 'anonymous callers cannot read the ledger');
select throws_ok('select count(*) from public.funds', '42501', null, 'anonymous callers cannot read even the funds');
select is(tests.write_attempts_not_refused(), '{}'::text[], 'anonymous callers are refused every write');
reset role;

set local role service_role;
select is(tests.write_attempts_not_refused(), '{}'::text[],
  'the service role is refused every direct write');
select is((select count(*) from public.transactions), 2::bigint, 'the service role can read (for server-side jobs)');
reset role;

-- 6. Signed in as someone with no profile ------------------------------------

select tests.act_as('00000000-0000-0000-0000-0000000000ee');
set local role authenticated;
select is((select count(*) from public.accounts), 0::bigint, 'a login with no profile sees no accounts');
select is((select count(*) from public.transactions), 0::bigint, 'a login with no profile sees no ledger rows');
reset role;

select * from finish();
rollback;
