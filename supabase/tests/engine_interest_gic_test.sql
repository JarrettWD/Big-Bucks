-- Known answers: savings interest and GICs (stage 2).
--
-- Every engine_*_test.sql file starts with the same helper block. Everything
-- runs in one transaction that is rolled back. Names are made up.
begin;
select plan(51);

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

-- Cast --------------------------------------------------------------------------

select tests.clock('2027-01-04 09:00');
select tests.new_kid('kid_s');  -- savings interest
select tests.new_kid('kid_g');  -- GICs
select tests.new_kid('kid_j');  -- month-end maturity dates

-- 1. Savings interest -------------------------------------------------------------

select tests.clock('2027-08-31 12:00');
select tests.fund('kid_s', 25000);

select tests.clock('2027-10-01 16:00');
select is(tests.run('accrue_savings_interest', '2027-09-01', '2027-09-30'), 'ok', 'the accrual job runs for every day of September');
select is(
  (select count(*) from public.interest_accruals
    where account_id = tests.acct('kid_s') and accrual_date between '2027-09-01' and '2027-09-30'),
  30::bigint, 'September 2027 has 30 daily accruals');
select is(
  (select round(accrued, 12) from public.interest_accruals
    where account_id = tests.acct('kid_s') and accrual_date = '2027-09-15'),
  round(25000 * 2.0 / 100 / 365, 12),
  'one day on $250.00 at 2% in a 365-day year accrues 1.3699 cents (kept as a fraction)');
select is(
  (select days_in_year from public.interest_accruals
    where account_id = tests.acct('kid_s') and accrual_date = '2027-09-15'),
  365::smallint, 'a day in 2027 divides by 365');

select is(tests.run('post_monthly_interest', '2027-10-01'), 'ok', 'the monthly posting runs on the 1st');
select is(
  (select amount_cents from public.transactions where posting_key = 'interest:2027-09:' || tests.acct('kid_s')),
  42::bigint,
  '$250 in savings at 2% for 30 days in a non-leap year posts $0.42 ($0.4110 rounded up)');
select is(
  (select effective_at from public.transactions where posting_key = 'interest:2027-09:' || tests.acct('kid_s')),
  '2027-10-01 00:00-06'::timestamptz, 'the interest counts from the start of the 1st');
select is(
  (select note from public.transactions where posting_key = 'interest:2027-09:' || tests.acct('kid_s')),
  'September: $250.00 × 2.0% ÷ 365 = $0.0137 a day, for 30 days = $0.4110, rounded up to $0.42',
  'the interest line carries its working ("How was this calculated?")');
select is(tests.run('post_monthly_interest', '2027-10-02'), 'ok', 'the monthly job on another day...');
select is(
  (select count(*) from public.transactions where account_id = tests.acct('kid_s') and type = 'interest'),
  1::bigint, '...posts nothing');

-- A savings rate change applies from its effective date onward.
select tests.clock('2027-10-01 17:00');
select tests.as_parent();
select public.add_rate('savings', null, 1.5, date '2027-10-10', 'Test: rates fell');
select tests.clock('2027-10-11 16:00');
select 'ran: ' || tests.run('accrue_savings_interest', '2027-10-09', '2027-10-10');
select results_eq(
  $$select accrual_date, rate, balance_cents from public.interest_accruals
     where account_id = tests.acct('kid_s') and accrual_date in ('2027-10-09', '2027-10-10') order by 1$$,
  $$values (date '2027-10-09', 2.000::numeric(6,3), 25042::bigint), (date '2027-10-10', 1.500::numeric(6,3), 25042::bigint)$$,
  'the day before a rate change earns the old rate; from its effective date, the new one');

-- Leap year
select tests.clock('2028-03-02 16:00');
select 'ran: ' || tests.run('accrue_savings_interest', '2028-03-01');
select results_eq(
  $$select days_in_year, round(accrued, 12) from public.interest_accruals
     where account_id = tests.acct('kid_s') and accrual_date = '2028-03-01'$$,
  $$values (366::smallint, round(25042 * 1.5 / 100 / 366, 12))$$,
  'a day in 2028 accrues ÷366');

-- 2. GICs -----------------------------------------------------------------------

select tests.clock('2027-01-04 09:00');
select tests.fund('kid_g', 30000);
select tests.as_kid('kid_g');
select throws_like($$select public.buy_gic(999, 1)$$, '%smallest GIC is $10.00%', 'a GIC under $10 is refused');
select throws_like($$select public.buy_gic(1000, 2)$$, '%1, 3, 6 or 9 months, or 1 or 2 years%', 'a 2-month GIC is refused');
select lives_ok($$select public.buy_gic(10000, 12)$$, 'she buys a $100 1-year GIC');
select lives_ok($$select public.buy_gic(10000, 1)$$, 'she buys a $100 1-month GIC');
select results_eq(
  $$select term_months, principal_cents, rate, start_date, maturity_date, status::text
      from public.gic_holdings where account_id = tests.acct('kid_g') order by id$$,
  $$values (12::smallint, 10000::bigint, 5.000::numeric(6,3), date '2027-01-04', date '2028-01-04', 'active'),
           (1::smallint,  10000::bigint, 2.500::numeric(6,3), date '2027-01-04', date '2027-02-04', 'active')$$,
  'each GIC locks the rate in force today and matures a calendar month or year later');
select is((tests.bal('kid_g')).savings_cents, 10000::bigint, 'the GIC money left savings');
select is((tests.bal('kid_g')).gic_cents, 20000::bigint, '...and is in the GICs');
select is((tests.bal('kid_g')).total_worth_cents, 30000::bigint, 'buying a GIC does not change her total worth');
select throws_like($$select public.buy_gic(10001, 3)$$, '%You have $100.00 available%',
  'a GIC bigger than the money available is refused');

-- A rate cut doesn't touch GICs she already has.
select tests.as_parent();
select public.add_rate('gic', 12, 4.0, date '2027-01-04', 'Test: rates fell');
select tests.as_kid('kid_g');
select public.buy_gic(1000, 12);
select is((select rate from public.gic_holdings where id = tests.gic('kid_g', 12, '2027-01-04')), 5.000::numeric(6,3),
  'a GIC keeps its locked rate after a rate cut');
select is((select rate from public.gic_holdings where account_id = tests.acct('kid_g') order by id desc limit 1),
  4.000::numeric(6,3), 'a GIC bought after the cut gets the new rate');

-- The 1-month GIC matures.
select tests.clock('2027-02-04 16:00');
select 'ran: ' || tests.run('mature_gics', '2027-02-04');
select is(tests.gic_balance(tests.gic('kid_g', 1, '2027-01-04')), 10021::bigint,
  '$100 at 2.5% for 1 month matures at $100.21');
select is(
  (select note from public.transactions where gic_id = tests.gic('kid_g', 1, '2027-01-04') and type = 'interest'),
  '$100.00 × 2.5% × 1/12 = $0.2083, rounded up to $0.21', 'the GIC interest line shows its working');
select is((select status::text from public.gic_holdings where id = tests.gic('kid_g', 1, '2027-01-04')), 'matured',
  'the GIC is marked matured');
select is(
  (select count(*) from public.notifications
    where related_gic_id = tests.gic('kid_g', 1, '2027-01-04') and type = 'gic_maturity'),
  1::bigint, 'she gets a notice to choose what happens next');

-- Waiting for her choice earns the savings rate (decision 1B); then she renews.
select tests.clock('2027-02-06 10:00');
select tests.as_kid('kid_g');
select public.choose_maturity(tests.gic('kid_g', 1, '2027-01-04'), 'renew');
select results_eq(
  $$select principal_cents, rate, start_date, maturity_date, renewed_from_id
      from public.gic_holdings where account_id = tests.acct('kid_g') and start_date = '2027-02-06'$$,
  $$values (10021::bigint, 2.500::numeric(6,3), date '2027-02-06', date '2027-03-06', tests.gic('kid_g', 1, '2027-01-04'))$$,
  'a renewed GIC carries principal + interest ($100.21), for the same term, starting the day she chooses');
select is(tests.gic_balance(tests.gic('kid_g', 1, '2027-01-04')), 0::bigint, 'the old GIC is empty after renewing');
select is((select maturity_choice::text from public.gic_holdings where id = tests.gic('kid_g', 1, '2027-01-04')), 'renew',
  'her choice is recorded');

select tests.clock('2027-02-07 16:00');
select 'ran: ' || tests.run('accrue_savings_interest', '2027-02-04', '2027-02-06');
select results_eq(
  $$select accrual_date, balance_cents, gic_waiting_cents from public.interest_accruals
     where account_id = tests.acct('kid_g') and accrual_date between '2027-02-04' and '2027-02-06' order by 1$$,
  $$values (date '2027-02-04', 9000::bigint, 10021::bigint),
           (date '2027-02-05', 9000::bigint, 10021::bigint),
           (date '2027-02-06', 9000::bigint, 0::bigint)$$,
  'matured money waiting for her choice counts for savings interest (Feb 4-5), and stops once renewed (Feb 6)');
select is(
  (select round(accrued, 12) from public.interest_accruals where account_id = tests.acct('kid_g') and accrual_date = '2027-02-04'),
  round((9000 + 10021) * 2.0 / 100 / 365, 12),
  'a waiting day accrues ($90.00 savings + $100.21 waiting) × 2% ÷ 365');

-- The renewed GIC matures; she doesn't choose; it moves to savings on day 7.
select tests.clock('2027-03-06 16:00');
select 'ran: ' || tests.run('mature_gics', '2027-03-06');
select is(tests.gic_balance(tests.gic('kid_g', 1, '2027-02-06')), 10042::bigint,
  'the renewal earned $0.21 on $100.21 ($0.2088 rounded up), so interest earned interest');
select tests.clock('2027-03-13 00:01');
select tests.as_kid('kid_g');
select throws_like($$select public.choose_maturity(tests.gic('kid_g', 1, '2027-02-06'), 'to_savings')$$,
  '%7 days%', 'after 7 days she can no longer choose');
select is(tests.run('auto_move_unclaimed_maturities', '2027-03-12'), 'ok', 'on day 6 the auto-move job...');
select is(tests.gic_balance(tests.gic('kid_g', 1, '2027-02-06')), 10042::bigint, '...leaves the money in the GIC');
select 'ran: ' || tests.run('auto_move_unclaimed_maturities', '2027-03-13');
select is(tests.gic_balance(tests.gic('kid_g', 1, '2027-02-06')), 0::bigint, 'on day 7 the money leaves the GIC...');
select is(
  (select effective_at from public.transactions
    where gic_id = tests.gic('kid_g', 1, '2027-02-06') and vehicle = 'savings' and type = 'transfer_in'),
  '2027-03-13 00:00-06'::timestamptz, '...and lands in savings at the start of day 7');
select is((tests.bal('kid_g')).savings_cents, 19042::bigint, 'savings now holds the $100.42');
select is((select maturity_choice::text from public.gic_holdings where id = tests.gic('kid_g', 1, '2027-02-06')), 'to_savings',
  'the GIC records the automatic move to savings');

select tests.clock('2027-04-01 16:00');
select 'ran: ' || tests.run('accrue_savings_interest', '2027-03-06', '2027-03-31');
select results_eq(
  $$select accrual_date, balance_cents, gic_waiting_cents from public.interest_accruals
     where account_id = tests.acct('kid_g') and accrual_date in ('2027-03-06', '2027-03-12', '2027-03-13') order by 1$$,
  $$values (date '2027-03-06', 9000::bigint, 10042::bigint),
           (date '2027-03-12', 9000::bigint, 10042::bigint),
           (date '2027-03-13', 19042::bigint, 0::bigint)$$,
  'waiting from maturity day to day 6, in savings from day 7');
select is(
  (select round(sum(accrued), 10) from public.interest_accruals
    where account_id = tests.acct('kid_g') and accrual_date between '2027-03-06' and '2027-03-31'),
  round((9000 + 10042) * 2.0 * 26 / 36500, 10),
  'the $100.42 earns the savings rate every day from maturity on: no gap, nothing counted twice');

-- Breaking a GIC early: principal back, interest forfeited.
select tests.clock('2027-07-05 10:00');
select is(
  (select interest_so_far_cents from public.gic_positions
    where account_id = tests.acct('kid_g') and principal_cents = 1000),
  20::bigint, 'the break warning: $0.40 for the year × 182/365 days held = $0.20 (rounded up)');
select tests.as_kid('kid_g');
select lives_ok(
  $$select public.break_gic((select id from public.gic_holdings where account_id = tests.acct('kid_g') and principal_cents = 1000))$$,
  'she breaks the $10 GIC early');
select results_eq(
  $$select g.status::text, (select coalesce(sum(t.amount_cents), 0)::bigint from public.transactions t where t.gic_id = g.id and t.vehicle = 'gic'),
           (select count(*) from public.transactions t where t.gic_id = g.id and t.type = 'interest')
      from public.gic_holdings g where g.account_id = tests.acct('kid_g') and g.principal_cents = 1000$$,
  $$values ('broken', 0::bigint, 0::bigint)$$,
  'a broken GIC is emptied and pays $0 interest');
select is((tests.bal('kid_g')).savings_cents, 20042::bigint, 'the $10.00 principal is back in savings');

-- The 1-year GIC
select tests.clock('2028-01-04 16:00');
select 'ran: ' || tests.run('mature_gics', '2028-01-04');
select is(tests.gic_balance(tests.gic('kid_g', 12, '2027-01-04')), 10500::bigint, '$100 at 5% for 1 year = exactly $105.00');
select is(
  (select note from public.transactions where gic_id = tests.gic('kid_g', 12, '2027-01-04') and type = 'interest'),
  '$100.00 × 5.0% × 12/12 = $5.00', 'the working shows no rounding when none was needed');
select tests.as_kid('kid_g');
select throws_like($$select public.break_gic(tests.gic('kid_g', 12, '2027-01-04'))$$, '%already%',
  'a matured GIC cannot be broken');

-- 3. Maturity dates at the end of a month ------------------------------------------

select tests.clock('2027-01-31 10:00');
select tests.fund('kid_j', 5000);
select tests.as_kid('kid_j');
select public.buy_gic(1000, 1);
select is((select maturity_date from public.gic_holdings where account_id = tests.acct('kid_j') and start_date = '2027-01-31'),
  date '2027-02-28', 'Jan 31 + 1 month matures Feb 28 in 2027');
select tests.clock('2028-01-31 10:00');
select tests.as_kid('kid_j');
select public.buy_gic(1000, 1);
select is((select maturity_date from public.gic_holdings where account_id = tests.acct('kid_j') and start_date = '2028-01-31'),
  date '2028-02-29', 'Jan 31 + 1 month matures Feb 29 in 2028');

select * from finish();
rollback;
