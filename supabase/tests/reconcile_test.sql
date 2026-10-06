-- Nightly reconciliation, "Updating…", alerts and the health check (stage 3).
--
-- Two made-up kids run normally for a month (kid R regular, kid Q a test
-- account), then each kind of fault is injected inside a savepoint and rolled
-- back, so every check starts from a clean, reconciled ledger.
begin;
select plan(52);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create function tests.nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true);
$$;
create function tests.acct(p_username text) returns uuid language sql as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.new_kid(p_username text, p_is_test boolean default false) returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, p_is_test) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
  return v_acct;
end;
$$;
create function tests.fund(p_username text, p_cents bigint) returns void language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
end;
$$;
-- The kinds of problem the latest reconcile found for an account.
create function tests.codes(p_result jsonb, p_username text) returns text[] language sql as $$
  select coalesce(array_agg(distinct p ->> 'code' order by p ->> 'code'), '{}')
    from jsonb_array_elements(p_result -> 'problems') p
   where p ->> 'account_id' = tests.acct(p_username)::text;
$$;
create function tests.recon(p_date date default '2026-12-02') returns jsonb language sql as $$
  select public.reconcile(p_date);
$$;
create function tests.open_alerts(p_username text) returns bigint language sql as $$
  select count(*) from public.alerts where account_id = tests.acct(p_username) and resolved_at is null;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- A steady price of 100 on every trading day.
insert into public.fund_prices (fund_id, price_date, close)
select f.id, d::date, 100
  from public.funds f, generate_series(date '2026-10-30', date '2026-12-31', interval '1 day') d
 where extract(isodow from d) < 6
   and not exists (select 1 from public.market_holidays h
                    where h.market = f.market and h.holiday_date = d::date and h.kind = 'closed');

-- A normal month ----------------------------------------------------------------

select tests.clock('2026-11-02 08:00');
select tests.new_kid('kid_r');
select tests.new_kid('kid_q', true);
select tests.fund('kid_r', 20000);
select tests.fund('kid_q', 20000);
select tests.clock('2026-11-02 10:00');
select tests.as_kid('kid_r');
select public.request_trade('dow', 'buy', 5000);
select public.buy_gic(5000, 1);
select tests.as_kid('kid_q');
select public.buy_gic(3000, 3);
select tests.nobody();
select tests.clock('2026-12-02 16:30');
select public.run_daily('2026-12-02');

-- 1. A clean ledger passes --------------------------------------------------------

select is(tests.recon() ->> 'status', 'ok', 'a month of normal activity reconciles cleanly');
select is(tests.recon('2026-11-15') ->> 'status', 'ok', 'an earlier day, checked as of its own end, is clean too');
select is((select count(*) from public.alerts), 0::bigint, 'no alerts');
select is(public.figures_updating(tests.acct('kid_r')), false, 'kid R''s figures are shown normally');
select is((select status::text from public.job_runs where job = 'reconcile' order by id desc limit 1), 'ok',
  'the check is recorded in job_runs');
select throws_like($$select public.reconcile('2026-12-03')$$, '%hasn''t happened yet%', 'reconcile refuses a future date');
select is((public.health_check() ->> 'ok')::boolean, true, 'the health check is clear');
select is((select count(*) from public.interest_accruals where account_id = tests.acct('kid_r')), 30::bigint,
  'sanity: 30 days of accruals, Nov 2 to Dec 1');
select is((select count(*) from public.transactions where account_id = tests.acct('kid_r') and type = 'interest'), 2::bigint,
  'sanity: November''s savings interest and the 1-month GIC''s interest are posted');

-- 2. A wrong posting on a regular account --------------------------------------------

savepoint f;
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_r'), 'savings', 'interest', 137, 'interest:2026-11:extra', public.edmonton_start('2026-12-02'), 'fault');
select is(tests.codes(tests.recon(), 'kid_r'), array['posting'], 'an extra interest line is caught as a posting that breaks its rule');
select is(tests.codes(tests.recon(), 'kid_q'), '{}'::text[], 'kid Q is unaffected');
select is(tests.open_alerts('kid_r'), 1::bigint, 'one alert, even after checking twice');
select is((select is_quiet from public.alerts where account_id = tests.acct('kid_r')), false, 'a regular account''s alert is raised');
select is(public.figures_updating(tests.acct('kid_r')), true, 'kid R''s figures show "Updating…"');
select is(public.figures_updating(tests.acct('kid_q')), false, 'kid Q''s figures don''t');
select is((public.health_check() ->> 'ok')::boolean, false, 'the health check fails...');
select is((select count(*) from jsonb_array_elements(public.health_check() -> 'problems') p where p ->> 'kind' = 'alert'),
  1::bigint, '...listing the open alert');
-- Fixed openly with a correction.
select max(id) as alert_id from public.alerts \gset
insert into public.transactions (account_id, vehicle, type, amount_cents, reverses_id, note)
select account_id, 'savings', 'correction', -137, id, 'Reverses an interest line posted by mistake.'
  from public.transactions where posting_key = 'interest:2026-11:extra';
select is(tests.recon() ->> 'status', 'ok', 'after the correction the check is clean');
select is(public.figures_updating(tests.acct('kid_r')), false, '"Updating…" clears by itself');
select is(tests.open_alerts('kid_r'), 1::bigint, 'the alert stays open until Dad acknowledges it');
select tests.as_kid('kid_r');
set local role authenticated;
select throws_ok(format('select public.acknowledge_alert(%s)', :alert_id), '42501', null,
  'a kid can''t acknowledge an alert');
reset role;
select tests.as_parent('aal1');
set local role authenticated;
select throws_like(format('select public.acknowledge_alert(%s)', :alert_id), '%second step%',
  'a parent without MFA can''t either');
reset role;
select tests.as_parent();
set local role authenticated;
select lives_ok(format('select public.acknowledge_alert(%s)', :alert_id),
  'Dad with MFA acknowledges it');
reset role;
select tests.nobody();
select is(tests.open_alerts('kid_r'), 0::bigint, 'no open alerts');
select is((public.health_check() ->> 'ok')::boolean, true, 'the health check is clear again');
rollback to savepoint f;

-- 3. The same fault on a test account is logged quietly -----------------------------------

savepoint f;
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_q'), 'savings', 'interest', 137, 'interest:2026-11:extra', public.edmonton_start('2026-12-02'), 'fault');
select is(tests.codes(tests.recon(), 'kid_q'), array['posting'], 'a test account is reconciled like any other');
select is((select is_quiet from public.alerts where account_id = tests.acct('kid_q')), true, 'its alert is quiet');
select is(public.figures_updating(tests.acct('kid_q')), true, 'its figures still show "Updating…"');
select is((public.health_check() ->> 'ok')::boolean, true, 'a quiet alert doesn''t fail the health check');
rollback to savepoint f;

-- 4. Each kind of problem ------------------------------------------------------------------

savepoint f;
insert into public.transactions (account_id, vehicle, type, amount_cents, note)
values (tests.acct('kid_r'), 'savings', 'correction', -1000000, 'fault');
select ok('negative' = any (tests.codes(tests.recon(), 'kid_r')), 'savings below zero is caught');
rollback to savepoint f;

savepoint f;
insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
values (tests.acct('kid_r'), 5000, 3.0, 3, date '2026-11-20', date '2027-02-20');
select is(tests.codes(tests.recon(), 'kid_r'), array['gic'], 'a GIC with no purchase line is caught');
rollback to savepoint f;

savepoint f;
insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, effective_at)
select g.account_id, 'gic', g.id, 'interest', 500, 'gic_interest:' || g.id, public.edmonton_start('2026-11-20')
  from public.gic_holdings g where g.account_id = tests.acct('kid_q');
select ok('posting' = any (tests.codes(tests.recon(), 'kid_q')), 'interest on a GIC that hasn''t matured is caught');
select ok('gic' = any (tests.codes(tests.recon(), 'kid_q')), '...and its balance no longer matches its status');
rollback to savepoint f;

savepoint f;
insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key)
select g.account_id, 'savings', g.id, 'transfer_in', 100, 'gic_buy:' || g.id || ':extra'
  from public.gic_holdings g where g.account_id = tests.acct('kid_r') and g.term_months = 1;
select ok('posting' = any (tests.codes(tests.recon(), 'kid_r')), 'a GIC move with a third line is caught');
select ok('worth' = any (tests.codes(tests.recon(), 'kid_r')), 'and total worth no longer equals money in − out + earnings');
rollback to savepoint f;

savepoint f;
insert into public.transactions (account_id, vehicle, type, amount_cents, note, effective_at)
values (tests.acct('kid_r'), 'savings', 'correction', 500, 'fault', public.edmonton_start('2026-11-10'));
select is(tests.codes(tests.recon(), 'kid_r'), array['accrual'],
  'a line backdated into the past makes those days'' interest wrong, and that is caught');
rollback to savepoint f;

savepoint f;
insert into public.requests (account_id, type, from_vehicle, amount_cents, held_cents)
values (tests.acct('kid_r'), 'withdraw', 'savings', 10000000, 10000000);
select ok('held' = any (tests.codes(tests.recon(), 'kid_r')), 'more money held than savings has is caught');
rollback to savepoint f;

savepoint f;
with r as (
  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, status, created_at)
  values (tests.acct('kid_r'), 'move', 'savings', 'stock', 'tsx', 1000, 'settled', public.edmonton_start('2026-11-24') + interval '9 hours')
  returning id, created_at)
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id, posting_key, effective_at)
select tests.acct('kid_r'), v.vehicle::public.vehicle, 'tsx', v.type::public.transaction_type, v.amount, v.units, v.price, r.id,
       'trade:' || r.id || ':' || v.part, public.next_close('tsx', r.created_at)
  from r, (values ('savings', 'transfer_out', -1000, null::numeric, null::numeric, 'savings'),
                  ('stock', 'transfer_in', 1000, 1::numeric, 100::numeric, 'fund')) v(vehicle, type, amount, units, price, part);
select ok('posting' = any (tests.codes(tests.recon(), 'kid_r')), 'a fund buy with the wrong number of units is caught');
rollback to savepoint f;

savepoint f;
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key)
values (tests.acct('kid_r'), 'savings', 'penalty', -100, 'penalty:fault');
select ok('posting' = any (tests.codes(tests.recon(), 'kid_r')), 'a penalty (the engine never charges one) is caught');
rollback to savepoint f;

savepoint f;
-- The monthly job marked done for Dec 1 although November's interest was never posted.
select tests.clock('2026-12-02 16:30');
insert into public.accounts (name, is_test) values ('Test kid_m', true);
insert into public.interest_accruals (account_id, accrual_date, balance_cents, rate, days_in_year, accrued)
select a.id, date '2026-11-15', 0, 2.0, 365, 0.5 from public.accounts a where a.name = 'Test kid_m';
select ok((select bool_or(p ->> 'code' = 'missed')
             from jsonb_array_elements(tests.recon() -> 'problems') p
            where p ->> 'account_id' = (select id::text from public.accounts where name = 'Test kid_m')),
  'a month''s interest that was never paid is caught');
rollback to savepoint f;

-- 5. The health check notices jobs falling behind ---------------------------------------------

savepoint f;
select tests.clock('2026-12-06 09:00');
select ok((select count(*) from jsonb_array_elements(public.health_check() -> 'problems') p where p ->> 'kind' = 'behind') >= 1,
  'four days without a run: the health check reports the jobs are behind');
select public.run_daily('2026-12-05');
select tests.recon('2026-12-05');
select is((public.health_check() ->> 'ok')::boolean, true, 'after catching up and checking, it''s clear');
rollback to savepoint f;

-- 6. Who may call what ------------------------------------------------------------------------
select tests.acct('kid_q') as kid_q_id, tests.acct('kid_r') as kid_r_id \gset
select throws_ok('select public.figures_updating(null)', '42501', null, 'no account at all is refused too');

select tests.as_kid('kid_r');
set local role authenticated;
select throws_ok($$select public.reconcile('2026-12-02')$$, '42501', null, 'a kid can''t run reconcile');
select throws_ok($$select public.health_check()$$, '42501', null, 'a kid can''t run the health check');
select is(public.figures_updating(tests.acct('kid_r')), false, 'a kid can ask about her own figures');
select throws_ok(format('select public.figures_updating(%L)', :'kid_q_id'), '42501', null,
  'but not about the other kid''s');
reset role;
select tests.as_parent();
set local role authenticated;
select throws_ok($$select public.reconcile('2026-12-02')$$, '42501', null, 'the parent app doesn''t run reconcile either (the server does)');
select is(public.figures_updating(tests.acct('kid_q')), false, 'the parent can ask about any kid');
reset role;
select tests.nobody();
set local role anon;
select throws_ok(format('select public.figures_updating(%L)', :'kid_r_id'), '42501', null,
  'anonymous callers can''t ask at all');
reset role;
set local role service_role;
select is(public.reconcile('2026-12-02') ->> 'status', 'ok', 'the server runs reconcile');
select is((public.health_check() ->> 'ok')::boolean, true, 'the server runs the health check');
reset role;

select * from finish();
rollback;
