-- Known answers: Alberta's pinned time rule (UTC−6 all year from Nov 1, 2026),
-- market closes set in Toronto time, and Alberta dates across both Nov 1, 2026
-- and the US/Canada clock changes.
begin;
select plan(45);

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
-- An Alberta clock time as a moment, written with an explicit UTC−6 offset so the
-- answers below don't depend on the rule being tested.
create function tests.utc6(p text) returns timestamptz language sql as $$
  select (p || '-06')::timestamptz;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- 1. The production check passes here (run before any clock override) ----------------

select tests.clock('');
select is((select count(*) from public.check_time_rules() where ok is false), 0::bigint,
  'check_time_rules(): no check fails');
select is((select count(*) from public.check_time_rules() where ok), 20::bigint,
  'check_time_rules(): 20 checks pass');
select is((select count(*) from public.check_time_rules() where ok is null), 1::bigint,
  'check_time_rules(): one information-only row (the server''s own time-zone data)');
select ok(not has_function_privilege('authenticated', 'public.check_time_rules()', 'execute'),
  'the app''s users can''t run check_time_rules()');
select ok(not has_function_privilege('anon', 'public.check_time_rules()', 'execute'),
  '...nor can anonymous callers');

-- 2. The pinned rule ---------------------------------------------------------------

select is(public.edmonton_local('2026-10-31 18:00+00'), timestamp '2026-10-31 12:00',
  'Oct 31, 2026: 18:00 UTC is noon in Alberta');
select is(public.edmonton_local('2026-11-01 07:30+00'), timestamp '2026-11-01 01:30',
  'Nov 1, 2026: the clocks don''t go back (07:30 UTC is 1:30 am, once)');
select is(public.edmonton_local('2026-11-02 18:00+00'), timestamp '2026-11-02 12:00',
  'Nov 2, 2026: 18:00 UTC is still noon');
select is(public.edmonton_local('2027-01-15 18:00+00'), timestamp '2027-01-15 12:00',
  'mid-winter: 18:00 UTC is noon');
select is(public.edmonton_local('2027-03-15 18:00+00'), timestamp '2027-03-15 12:00',
  'after the US/Canada spring change: still noon');
select is(public.edmonton_local('2027-07-01 18:00+00'), timestamp '2027-07-01 12:00',
  'summer: noon');
select is(public.edmonton_local('2026-01-15 18:00+00'), timestamp '2026-01-15 11:00',
  'before Mar 8, 2026 the old rule still applies: January was UTC−7');
select is(public.edmonton_at('2026-12-31 23:30'), timestamptz '2027-01-01 05:30+00',
  '11:30 pm Dec 31 in Alberta is 05:30 UTC on Jan 1');
select is(public.edmonton_at('2026-11-01 01:30'), timestamptz '2026-11-01 07:30+00',
  '1:30 am on Nov 1, 2026 happens once, at 07:30 UTC');
select is(public.edmonton_at('2026-01-15 12:00'), timestamptz '2026-01-15 19:00+00',
  'before the rule: noon in January 2026 was 19:00 UTC');
select is(public.edmonton_start('2026-11-01'), timestamptz '2026-11-01 06:00+00',
  'Nov 1, 2026 starts at 06:00 UTC');
select is(public.edmonton_start('2026-11-02') - public.edmonton_start('2026-11-01'), interval '24 hours',
  '...and is 24 hours long (it would have been 25 under the old rule)');
select is(public.edmonton_start('2027-03-15') - public.edmonton_start('2027-03-14'), interval '24 hours',
  'Mar 14, 2027 (the US/Canada spring change) is 24 hours long in Alberta');

-- 3. The app clock across Nov 1, 2026 ------------------------------------------------

select tests.clock('2026-10-31 23:30');
select is(public.app_today(), date '2026-10-31', '11:30 pm Oct 31: still Oct 31');
select is(public.app_now(), timestamptz '2026-11-01 05:30+00', '...which is 05:30 UTC');
select tests.clock('2026-11-01 00:30');
select is(public.app_today(), date '2026-11-01', '12:30 am Nov 1: Nov 1');
select is(public.app_now(), timestamptz '2026-11-01 06:30+00', '...which is 06:30 UTC');
select tests.clock('2026-11-15 09:30');
select is(public.app_now(), timestamptz '2026-11-15 15:30+00', 'Nov 15, 9:30 am is 15:30 UTC (UTC−6)');

-- 4. Closes: 4:00 pm Toronto, shown in Alberta time ----------------------------------

select is(public.fmt_moment(public.close_time('nyse', '2026-10-30')), 'Oct 30 at 2:00 pm',
  'Fri Oct 30, 2026 (Toronto summer time): the close is 2:00 pm in Alberta');
select is(public.fmt_moment(public.close_time('nyse', '2026-11-02')), 'Nov 2 at 3:00 pm',
  'Mon Nov 2, 2026 (Toronto standard time): 3:00 pm in Alberta');
select is(public.fmt_moment(public.close_time('nyse', '2026-11-27')), 'Nov 27 at 12:00 pm',
  'NYSE early close (1:00 pm Toronto) in winter: 12:00 pm in Alberta');
select is(public.fmt_moment(public.close_time('tsx', '2026-12-24')), 'Dec 24 at 12:00 pm',
  'TSX early close on Christmas Eve: 12:00 pm in Alberta');
select is(public.fmt_moment(public.close_time('tsx', '2027-03-12')), 'Mar 12 at 3:00 pm',
  'Fri Mar 12, 2027 (last day of Toronto standard time): 3:00 pm');
select is(public.fmt_moment(public.close_time('tsx', '2027-03-15')), 'Mar 15 at 2:00 pm',
  'Mon Mar 15, 2027 (Toronto summer time): 2:00 pm');
select is(public.fmt_moment(public.close_time('nyse', '2027-11-05')), 'Nov 5 at 2:00 pm',
  'Fri Nov 5, 2027: 2:00 pm');
select is(public.fmt_moment(public.close_time('nyse', '2027-11-08')), 'Nov 8 at 3:00 pm',
  'Mon Nov 8, 2027 (after Toronto falls back): 3:00 pm');
select is(public.fmt_moment(public.close_time('nyse', '2028-07-03')), 'Jul 3 at 11:00 am',
  'NYSE early close in summer (Jul 3, 2028): 11:00 am in Alberta');

-- 5. When a trade settles -----------------------------------------------------------

select is(public.next_settlement('dow', tests.utc6('2026-10-30 14:30')), tests.utc6('2026-11-02 15:00'),
  '2:30 pm Fri Oct 30 is after the 2:00 pm close: settles Mon Nov 2 at 3:00 pm');
select is(public.next_settlement('dow', tests.utc6('2026-11-02 14:30')), tests.utc6('2026-11-02 15:00'),
  '2:30 pm Mon Nov 2 is before the 3:00 pm close: settles that day');
select is(public.next_settlement('dow', tests.utc6('2026-11-02 15:00')), tests.utc6('2026-11-03 15:00'),
  'exactly at the 3:00 pm close: waits for the next one');
select is(public.next_settlement('tsx', tests.utc6('2027-03-12 14:30')), tests.utc6('2027-03-12 15:00'),
  '2:30 pm Fri Mar 12, 2027: settles that day at 3:00 pm');
select is(public.next_settlement('tsx', tests.utc6('2027-03-15 14:30')), tests.utc6('2027-03-16 14:00'),
  '2:30 pm Mon Mar 15, 2027 is after the 2:00 pm close: settles Tue at 2:00 pm');

-- 6. One trade per fund per Alberta day, at midnight in winter -------------------------

select tests.clock('2026-12-01 09:00');
select tests.new_kid('kid_tz');
select tests.fund('kid_tz', 50000);
select tests.clock('2026-12-01 23:30');
select tests.as_kid('kid_tz');
select lives_ok($$select public.request_trade('dow', 'buy', 1000)$$, '11:30 pm Dec 1: she asks to buy');
select tests.clock('2026-12-01 23:45');
select tests.as_kid('kid_tz');
select throws_like($$select public.request_trade('dow', 'buy', 1000)$$, '%already traded the Dow Jones fund today%',
  '11:45 pm Dec 1: a second trade that day is refused');
select tests.clock('2026-12-02 00:30');
select tests.as_kid('kid_tz');
select lives_ok($$select public.request_trade('dow', 'buy', 1000)$$,
  '12:30 am Dec 2 is a new Alberta day: allowed (under the old rule it was still Dec 1)');

-- 7. Dates on her activity ------------------------------------------------------------

select tests.new_kid('kid_tz2');
select tests.clock('2026-12-31 23:30');
select tests.fund('kid_tz2', 1000);
select tests.clock('2027-01-01 00:30');
select tests.fund('kid_tz2', 2000);
select tests.as_kid('kid_tz2');
select results_eq(
  $$select amount_cents, on_day from public.my_activity(tests.acct('kid_tz2'), 10) where kind = 'deposit' order by at$$,
  $$values (1000::bigint, date '2026-12-31'), (2000::bigint, date '2027-01-01')$$,
  'a deposit at 11:30 pm Dec 31 shows on Dec 31, one at 12:30 am on Jan 1');
select tests.nobody();

-- 8. Nothing else asks the server about Alberta ---------------------------------------

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc ilike '%America/Edmonton%'),
  array['check_time_rules', 'edmonton_at', 'edmonton_local'],
  'only the pinned-rule functions (and the check''s information row) name America/Edmonton');
select is(
  (select count(*) from pg_views where schemaname = 'public' and definition ilike '%America/Edmonton%'),
  0::bigint, 'no view names America/Edmonton');
select ok(
  (select p.provolatile = 'i' from pg_proc p where p.oid = 'public.edmonton_local(timestamptz)'::regprocedure)
  and (select p.provolatile = 'i' from pg_proc p where p.oid = 'public.edmonton_at(timestamp)'::regprocedure),
  'the pinned-rule functions are immutable: same answer on every server');
select ok(has_function_privilege('authenticated', 'public.edmonton_local(timestamptz)', 'execute'),
  'signed-in users can run edmonton_local (views and app_today use it)');

select * from finish();
rollback;
