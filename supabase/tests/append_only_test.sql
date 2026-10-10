-- History can't be edited: transactions, rates and interest_accruals reject
-- UPDATE, DELETE and TRUNCATE for every role. (settings is covered in clock_test.sql;
-- every append-only table's guards are checked precisely at the end.)
-- The database owner bypasses grants and RLS, so the owner tests prove the
-- triggers themselves; the app-role tests prove nobody else gets that far.
begin;
set local client_min_messages = warning;  -- hide "truncate cascades to ..." notices
select plan(20);

insert into public.accounts (id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Test Kid A');
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'savings', 'deposit', 5000, 'test:deposit:1');
insert into public.interest_accruals (account_id, accrual_date, balance_cents, rate, days_in_year, accrued)
  values ('aaaaaaaa-0000-0000-0000-000000000001', date '2026-10-01', 5000, 2.000, 365, 0.27397260);

-- As the database owner (a superuser): the triggers refuse
select throws_like($$update public.transactions set amount_cents = 999999$$, '%append-only%',
  'owner: transactions rejects UPDATE');
select throws_like($$delete from public.transactions$$, '%append-only%', 'owner: transactions rejects DELETE');
select throws_like($$truncate public.transactions cascade$$, '%append-only%', 'owner: transactions rejects TRUNCATE');
select throws_like($$update public.rates set rate = 99$$, '%append-only%', 'owner: rates rejects UPDATE');
select throws_like($$delete from public.rates$$, '%append-only%', 'owner: rates rejects DELETE');
select throws_like($$truncate public.rates cascade$$, '%append-only%', 'owner: rates rejects TRUNCATE');
select throws_like($$update public.interest_accruals set accrued = 999$$, '%append-only%',
  'owner: interest_accruals rejects UPDATE');
select throws_like($$delete from public.interest_accruals$$, '%append-only%', 'owner: interest_accruals rejects DELETE');
select throws_like($$truncate public.interest_accruals$$, '%append-only%', 'owner: interest_accruals rejects TRUNCATE');

-- Appending still works, and nothing above changed anything
insert into public.transactions (account_id, vehicle, type, amount_cents, note, reverses_id)
  select account_id, 'savings', 'correction', -5000, 'Test: reversing a deposit', id
    from public.transactions where posting_key = 'test:deposit:1';
select is((select sum(amount_cents) from public.transactions), 0::numeric,
  'a correction is appended and nets the original to zero');
select is((select count(*) from public.transactions), 2::bigint, 'both rows are still there');
select is((select count(*) from public.rates), 7::bigint, 'every rate row is still there');

-- The service role and a signed-in user never get as far as the trigger
set local role service_role;
select throws_ok($$update public.transactions set amount_cents = 1$$, '42501', null, 'service role: transactions UPDATE refused');
select throws_ok($$delete from public.rates$$, '42501', null, 'service role: rates DELETE refused');
select throws_ok($$update public.settings set value = 'x'$$, '42501', null, 'service role: settings UPDATE refused');
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000f","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$delete from public.transactions$$, '42501', null, 'signed-in user: transactions DELETE refused');
select throws_ok($$update public.rates set rate = 0$$, '42501', null, 'signed-in user: rates UPDATE refused');
reset role;

-- Every append-only table, precisely (mutation check, 2026-10-09). A table referenced
-- by another can't be truncated alone, and "truncate … cascade" also reaches other
-- append-only tables, whose own guard raises the same kind of error, so a broken
-- guard could hide behind its neighbour's. Here each table's guards must exist, be
-- switched on and fire on the right operations (that also covers tables that are
-- empty in this test), and each table's TRUNCATE is tried with every OTHER table's
-- TRUNCATE guard switched off for that moment, so the refusal has to be its own.
create temp table append_only_tables (t text);
insert into append_only_tables values
  ('transactions'), ('rates'), ('settings'), ('interest_accruals'), ('fund_prices'), ('fund_splits'),
  ('parent_actions'), ('cancellations'), ('agreement_versions'), ('agreement_signatures'),
  ('whats_new_features'), ('whats_new_seen'), ('fund_price_corrections');

select is(
  array(select a.t from append_only_tables a
         where not exists (
           select 1 from pg_trigger g
            where g.tgrelid = ('public.' || a.t)::regclass and g.tgenabled = 'O'
              and g.tgfoid in ('public.reject_append_only_change()'::regprocedure, 'public.fund_prices_guard()'::regprocedure)
              and g.tgtype & (1 | 2 | 8 | 16) = (1 | 2 | 8 | 16))
         order by 1),
  '{}'::text[], 'every append-only table has its UPDATE and DELETE guard, switched on');
select is(
  array(select a.t from append_only_tables a
         where not exists (
           select 1 from pg_trigger g
            where g.tgrelid = ('public.' || a.t)::regclass and g.tgenabled = 'O'
              and g.tgfoid = 'public.reject_append_only_change()'::regprocedure
              and g.tgtype & 1 = 0 and g.tgtype & (2 | 32) = (2 | 32))
         order by 1),
  '{}'::text[], 'every append-only table has its TRUNCATE guard, switched on');

create function pg_temp.truncate_alone(p_table text) returns text language plpgsql as $$
declare
  v_other text;
  v_err text;
  v_on text[];
begin
  -- Only the guards that are on now, and only those are switched back on after.
  select coalesce(array_agg(a.t), '{}') into v_on from append_only_tables a join pg_trigger g
      on g.tgrelid = ('public.' || a.t)::regclass and g.tgname = a.t || '_no_truncate'
   where a.t <> p_table and g.tgenabled = 'O';
  foreach v_other in array v_on loop
    execute format('alter table public.%I disable trigger %I', v_other, v_other || '_no_truncate');
  end loop;
  begin
    execute format('truncate public.%I cascade', p_table);
    v_err := 'not refused';
  exception when others then
    v_err := sqlerrm;
  end;
  foreach v_other in array v_on loop
    execute format('alter table public.%I enable trigger %I', v_other, v_other || '_no_truncate');
  end loop;
  return v_err;
end;
$$;
select is(
  array(select x.t || ': ' || x.e
          from (select a.t, pg_temp.truncate_alone(a.t) as e from append_only_tables a) x
         where x.e <> x.t || ' is append-only: truncate is not allowed. Add a new row instead.'
         order by 1),
  '{}'::text[], 'each append-only table refuses TRUNCATE by its own guard, even with cascade');

select * from finish();
rollback;
