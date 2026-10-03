-- History can't be edited: transactions, rates and interest_accruals reject
-- UPDATE, DELETE and TRUNCATE for every role. (settings is covered in clock_test.sql.)
-- The database owner bypasses grants and RLS, so the owner tests prove the
-- triggers themselves; the app-role tests prove nobody else gets that far.
begin;
set local client_min_messages = warning;  -- hide "truncate cascades to ..." notices
select plan(17);

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

select * from finish();
rollback;
