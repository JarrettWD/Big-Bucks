-- Daily jobs: run_daily, catch-up after missed days, never posting twice, and
-- waiting for a missing price (stage 2).
begin;
select plan(26);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

-- Freeze the app clock at an Edmonton date and time (works only in local dev).
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
-- A new kid with a login, created at the current app time.
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
-- Money in the normal way: the kid asks, the parent approves.
create function tests.fund(p_username text, p_cents bigint) returns bigint language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
  return v_req;
end;
$$;
-- Run a daily job for each date in a range; returns the last status.
create function tests.run(p_job text, p_from date, p_to date default null) returns text
language plpgsql as $$
declare
  d date;
  r jsonb;
begin
  perform tests.nobody();
  for d in select generate_series(p_from, coalesce(p_to, p_from), interval '1 day')::date loop
    execute format('select public.%I($1)', p_job) into r using d;
  end loop;
  return r ->> 'status';
end;
$$;
create function tests.bal(p_username text) returns public.account_balances language sql as $$
  select * from public.account_balances where account_id = tests.acct(p_username);
$$;
create function tests.gic(p_username text, p_term int, p_start date) returns bigint language sql as $$
  select id from public.gic_holdings
   where account_id = tests.acct(p_username) and term_months = p_term and start_date = p_start
   order by id limit 1;
$$;
create function tests.gic_balance(p_gic bigint) returns bigint language sql as $$
  select coalesce(sum(amount_cents), 0)::bigint from public.transactions where gic_id = p_gic and vehicle = 'gic';
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');


-- Everything the jobs write, as one comparable row.
create function tests.footprint() returns text language sql as $$
  select concat_ws(' / ',
    (select count(*) from public.transactions), (select coalesce(sum(amount_cents), 0) from public.transactions),
    (select count(*) from public.interest_accruals), (select count(*) from public.notifications),
    (select count(*) from public.notes), (select count(*) from public.gic_holdings),
    (select string_agg(id || status::text, ',' order by id) from public.requests),
    (select string_agg(id || status::text || coalesce(maturity_choice::text, '-'), ',' order by id) from public.gic_holdings));
$$;
create function tests.ok_jobs(p_date date) returns bigint language sql as $$
  select count(distinct job) from public.job_runs where run_for_date = p_date and status = 'ok';
$$;
create temp table snap (k text primary key, v text);

-- A steady price of 100 on every trading day, for all three funds.
insert into public.fund_prices (fund_id, price_date, close)
select f.id, d::date, 100
  from public.funds f, generate_series(date '2026-10-30', date '2026-12-02', interval '1 day') d
 where extract(isodow from d) < 6
   and not exists (select 1 from public.market_holidays h
                    where h.market = f.market and h.holiday_date = d::date and h.kind = 'closed');

select tests.clock('2026-11-02 08:00');
select tests.new_kid('kid_j');
select tests.fund('kid_j', 20000);
select tests.clock('2026-11-02 10:00');
select tests.as_kid('kid_j');
select public.request_trade('dow', 'buy', 5000);
select public.buy_gic(5000, 1);
select public.request_withdrawal(1000);
select tests.nobody();

-- 1. The first nightly run ----------------------------------------------------------

select tests.clock('2026-11-02 16:30');
select throws_like($$select public.run_daily('2026-11-03')$$, '%future%', 'run_daily refuses a date that hasn''t happened yet');
select is(public.run_daily('2026-11-02') ->> 'status', 'ok', 'the first run on Nov 2 succeeds');
select is(tests.ok_jobs('2026-11-02'), 9::bigint, 'nine jobs finished for Nov 2...');
select is(
  (select status::text from public.job_runs where job = 'interest' and run_for_date = '2026-11-02' order by id desc limit 1),
  'retrying', '...and the interest accrual waits until Nov 2 is over');
select is((select status::text from public.requests where account_id = tests.acct('kid_j') and fund_id = 'dow'), 'settled',
  'the morning''s trade settled at the 2:00 pm close');

-- 2. A missed week, caught up in one run -----------------------------------------------

select tests.clock('2026-11-10 16:30');
select is(public.run_daily('2026-11-10') ->> 'status', 'ok', 'after a missed week, one run catches up');
select is(
  (select count(*) from public.interest_accruals where account_id = tests.acct('kid_j')),
  8::bigint, 'interest accrued for every missed day, Nov 2 to Nov 9');
select is(
  (select count(*) from generate_series(date '2026-11-03', date '2026-11-09', interval '1 day') d
    where tests.ok_jobs(d::date) = 10),
  7::bigint, 'every job finished for each missed day, Nov 3 to Nov 9');
select is(tests.ok_jobs('2026-11-10'), 9::bigint, 'today''s jobs ran too (all but tonight''s accrual)');
select is((select status::text from public.requests where type = 'withdraw'), 'expired',
  'the unanswered withdrawal expired during the catch-up');
select is(
  (select balance_cents from public.interest_accruals where account_id = tests.acct('kid_j') and accrual_date = '2026-11-02'),
  10000::bigint, 'Nov 2''s accrual used Nov 2''s end-of-day balance ($200 − $50 fund − $50 GIC), even though it ran on Nov 10');

insert into snap values ('after_catch_up', tests.footprint());
select is(public.run_daily('2026-11-10') ->> 'status', 'ok', 'running again for the same date...');
select is(tests.footprint(), (select v from snap where k = 'after_catch_up'), '...posts nothing new');

-- 3. Month end and a maturity ---------------------------------------------------------

select tests.clock('2026-12-02 16:00');
select is(public.run_daily('2026-12-02') ->> 'status', 'ok', 'run through Dec 2');
select is(
  (select amount_cents from public.transactions where posting_key = 'interest:2026-11:' || tests.acct('kid_j')),
  (select ceil(sum(accrued))::bigint from public.interest_accruals
    where account_id = tests.acct('kid_j') and accrual_date between '2026-11-01' and '2026-11-30'),
  'November''s interest posted on Dec 1: the month''s accruals summed and rounded up');
select is(
  (select sum(amount_cents)::bigint from public.transactions t join public.gic_holdings g on g.id = t.gic_id
    where g.account_id = tests.acct('kid_j') and t.vehicle = 'gic'),
  5011::bigint, 'the 1-month GIC matured on Dec 2 with $0.11 interest ($0.1042 rounded up)');

-- Every job, run again by hand for every date: nothing new.
insert into snap values ('dec2', tests.footprint());
select 'ran: ' || tests.run(j, '2026-11-02', '2026-12-02')
  from unnest(array['expire_requests', 'apply_split', 'settle_trades', 'mature_gics', 'auto_move_unclaimed_maturities',
                    'pay_quarterly_dividends', 'post_monthly_interest', 'write_market_move_notes', 'send_rate_notices',
                    'accrue_savings_interest']) j;
select is(tests.footprint(), (select v from snap where k = 'dec2'),
  'running any job twice for the same dates posts nothing new');

-- 4. A missing close holds the run at that day ------------------------------------------

select tests.clock('2026-12-03 10:00');
select tests.as_kid('kid_j');
select public.request_trade('dow', 'buy', 1000);
insert into public.fund_prices (fund_id, price_date, close) values ('nasdaq100', '2026-12-03', 100), ('tsx', '2026-12-03', 100);
select tests.clock('2026-12-03 16:30');
select is(public.run_daily('2026-12-03') ->> 'status', 'waiting', 'with the Dow close missing, the run waits');
select is(
  (select status::text from public.job_runs where job = 'settle' and run_for_date = '2026-12-03' order by id desc limit 1),
  'retrying', 'settlement is recorded as retrying');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2026-12-04', 103), ('nasdaq100', '2026-12-04', 100), ('tsx', '2026-12-04', 100);
select tests.clock('2026-12-04 16:30');
select is(public.run_daily('2026-12-04') ->> 'status', 'waiting', 'the next day it still waits for Dec 3...');
select is(tests.ok_jobs('2026-12-04'), 0::bigint, '...and does not skip ahead to Dec 4');
select is((select status::text from public.requests where fund_id = 'dow' and status = 'pending'), 'pending',
  'the trade is not settled on Dec 4''s price');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2026-12-03', 102);
select is(public.run_daily('2026-12-04') ->> 'status', 'ok', 'once the close arrives, the run carries on');
select results_eq(
  $$select r.status::text, t.unit_price from public.requests r join public.transactions t on t.request_id = r.id and t.vehicle = 'stock'
     where r.account_id = tests.acct('kid_j') and public.edmonton_local(r.created_at)::date = '2026-12-03'$$,
  $$values ('settled', 102::numeric(20,8))$$, 'the trade settled at Dec 3''s real close');
select is(tests.ok_jobs('2026-12-03'), 10::bigint, 'every job finished for Dec 3');
select is(tests.ok_jobs('2026-12-04'), 9::bigint, 'and for Dec 4 (all but tonight''s accrual)');

select * from finish();
rollback;
