-- Known answers: rate changes, specials, settings and their notices (stage 2).
begin;
select plan(41);

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


create function tests.rate(p_vehicle text, p_term int, p_date date) returns numeric language sql as $$
  select (public.rate_on(p_vehicle::public.vehicle, p_term, p_date)).rate;
$$;

select tests.clock('2026-10-20 10:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);  -- a test account: notices reach it like any other

-- 1. A regular savings rate change -------------------------------------------------

select is(tests.rate('savings', null, '2026-06-01'), 2.000::numeric, 'the starting savings rate is 2.0%');
select tests.as_parent();
select throws_like($$select public.add_rate('savings', null, 1.5, date '2026-10-19')$$, '%past%',
  'a rate change can''t start in the past (it would rewrite interest already earned)');
select throws_like($$select public.add_rate('savings', 12, 1.5)$$, '%savings rate has no term%', 'savings has no term');
select throws_like($$select public.add_rate('gic', 2, 1.5)$$, '%1, 3, 6, 9, 12 or 24%', 'GIC terms are 1, 3, 6, 9, 12 or 24 months');
select throws_like($$select public.add_rate('gic', 12, 100)$$, '%between 0% and 99.999%', 'a rate of 100% is refused');
select throws_like($$select public.add_rate('gic', 12, 2.0005)$$, '%3 decimal places%', 'more than 3 decimal places is refused (it would be rounded silently)');
select lives_ok($$select public.add_rate('savings', null, 1.5, null, 'The Bank of Canada cut rates')$$, 'Dad cuts the savings rate');
select results_eq(
  $$select rate, effective_date, is_special, note, created_by from public.rates order by id desc limit 1$$,
  $$values (1.500::numeric(6,3), date '2026-10-27', false, 'The Bank of Canada cut rates', '00000000-0000-0000-0000-00000000000f'::uuid)$$,
  'the effective date defaults to 7 days from today');
select is(tests.rate('savings', null, '2026-10-26'), 2.000::numeric, 'the old rate still applies the day before');
select is(tests.rate('savings', null, '2026-10-27'), 1.500::numeric, 'the new rate applies from its effective date');
select results_eq(
  $$select title, body from public.notifications where type = 'rate_change' and account_id = tests.acct('kid_a')$$,
  $$values ('Savings rate drops from 2.0% to 1.5% on Oct 27',
            'The Bank of Canada cut rates. Tip: GICs bought before then keep today''s rates.')$$,
  'each kid is told right away: old and new rate, when, and Dad''s note');
select is((select count(*) from public.notifications where type = 'rate_change'), 2::bigint,
  'both kids get it, the test account too');

select tests.clock('2026-10-27 16:00');
select is(tests.run('send_rate_notices', '2026-10-27'), 'ok', 'on the effective date...');
select is(
  (select title from public.notifications where type = 'rate_live' and account_id = tests.acct('kid_a')),
  'The new savings rate is now 1.5%', '...a second notice says the new rate is live');
select 'ran: ' || tests.run('send_rate_notices', '2026-10-27');
select is((select count(*) from public.notifications where type = 'rate_live'), 2::bigint, 'running it again sends nothing new');

-- 2. A special ------------------------------------------------------------------

select tests.as_parent();
select throws_like($$select public.add_rate('gic', 12, 6.0, date '2026-11-01', null, date '2026-10-31')$$, '%end%',
  'a special can''t end before it starts');
select lives_ok($$select public.add_rate('gic', 12, 6.0, date '2026-11-01', 'One-week special', date '2026-11-07')$$,
  'Dad offers a 1-year GIC at 6% for one week');
select is((select is_special from public.rates order by id desc limit 1), true, 'it is stored as a special');
select is(
  (select title from public.notifications where type = 'rate_change' and account_id = tests.acct('kid_a') order by id desc limit 1),
  'Special: 1-year GICs at 6.0% from Nov 1 to Nov 7', 'the notice announces the special and its dates');
select is(tests.rate('gic', 12, '2026-10-31'), 5.000::numeric, 'a special applies only between its dates: not the day before');
select is(tests.rate('gic', 12, '2026-11-01'), 6.000::numeric, '...from its first day');
select is(tests.rate('gic', 12, '2026-11-07'), 6.000::numeric, '...to its last day');
select is(tests.rate('gic', 12, '2026-11-08'), 5.000::numeric, '...and back to the regular rate after');
select is(tests.rate('gic', 6, '2026-11-03'), 4.000::numeric, 'other terms are untouched');

select tests.fund('kid_a', 5000);
select tests.clock('2026-11-03 10:00');
select tests.as_kid('kid_a');
select public.buy_gic(1000, 12);
select tests.clock('2026-11-08 10:00');
select tests.as_kid('kid_a');
select public.buy_gic(1000, 12);
select results_eq(
  $$select start_date, rate, (select is_special from public.rates r where r.id = g.rate_id)
      from public.gic_holdings g where account_id = tests.acct('kid_a') order by id$$,
  $$values (date '2026-11-03', 6.000::numeric(6,3), true), (date '2026-11-08', 5.000::numeric(6,3), false)$$,
  'a GIC bought during the special locks 6.0%; one bought after gets 5.0%');

select 'ran: ' || tests.run('send_rate_notices', '2026-11-01', '2026-11-08');
select is(
  (select title from public.notifications where type = 'rate_live' and account_id = tests.acct('kid_a') and created_at::date >= '2026-11-01' order by id limit 1),
  'The 1-year GIC special at 6.0% starts today', 'a notice when the special starts');
select is(
  (select title || ' / ' || body from public.notifications where type = 'rate_live' and account_id = tests.acct('kid_a') order by id desc limit 1),
  'The 1-year GIC special has ended / 1-year GICs are back to 5.0%. GICs bought during the special keep 6.0%.',
  'and one when it ends');

-- 3. Settings ------------------------------------------------------------------

select tests.as_parent();
select throws_ok($$select public.set_setting('is_local_dev', 'true')$$, '42501', null,
  'the parent can never switch on local-dev mode');
select throws_ok($$select public.set_setting('clock_override', '2030-01-01')$$, '42501', null,
  'the parent can never move the clock');
select throws_like($$select public.set_setting('favourite_colour', 'blue')$$, '%isn''t a setting%', 'unknown keys are refused');
select throws_like($$select public.set_setting('deposit_cap_cents', '12.50')$$, '%whole number of cents%', 'the cap must be whole cents');
select throws_like($$select public.set_setting('feature:wishlist', 'maybe')$$, '%off, test or everyone%', 'feature switches are off, test or everyone');
select throws_like($$select public.set_setting('dividend_yield:nope', '1.0')$$, '%no fund%', 'a yield needs a real fund');
select throws_like($$select public.set_setting('inflation_rate', '2.0', date '2026-11-01')$$, '%past%', 'settings can''t start in the past');
select lives_ok($$select public.set_setting('feature:wishlist', 'test')$$, 'Dad switches a feature on for test accounts');
select is(public.feature_enabled('wishlist', tests.acct('kid_b')), true, '...the test account has it');
select lives_ok($$select public.set_setting('dividend_yield:dow', '2.0', null, 'Test: higher yield')$$, 'Dad changes a fund''s yield');
select is((select value from public.settings where key = 'dividend_yield:dow' order by id desc limit 1), '2.0',
  'the yield change is a new dated row, so its history is kept');

select lives_ok($$select public.set_setting('deposit_cap_cents', '150000', null, 'Birthday season')$$, 'Dad raises the cap');
select is((tests.bal('kid_a')).cap_cents, 150000::bigint, 'the new cap applies');
select results_eq(
  $$select title from public.notifications where type = 'cap_change' order by account_id$$,
  $$select 'The deposit limit goes up from $1,000.00 to $1,500.00 today' from public.accounts order by id$$,
  'both kids get a notice when the cap changes');

select * from finish();
rollback;
