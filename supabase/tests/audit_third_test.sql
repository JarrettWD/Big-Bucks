-- Targeted tests for the third round of pre-launch audit fixes (third audit,
-- 2026-10-09, with Dad's review): each should-fix item, the minor items, and the
-- "record an early close" refusals.
begin;
select plan(38);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
-- Signed-in claims as Supabase Auth gives them, with the token's session.
create function tests.as_user(p_user uuid, p_aal text default 'aal1', p_session uuid default null) returns void
language sql as $$
  select set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)
      || case when p_session is null then '{}'::jsonb else jsonb_build_object('session_id', p_session) end)::text,
    true);
$$;
create function tests.nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true);
$$;
create function tests.acct(p_username text) returns uuid language sql as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.user_of(p_username text) returns uuid language sql as $$
  select user_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text, p_session uuid default null) returns void language sql as $$
  select tests.as_user(tests.user_of(p_username), 'aal1', p_session);
$$;
create function tests.as_parent(p_aal text default 'aal2', p_session uuid default null) returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal, p_session);
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
create function tests.new_kid(p_username text, p_signed text default 'both') returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email, encrypted_password)
    values (v_user, p_username || '@test.invalid', extensions.crypt('x', extensions.gen_salt('bf', 4)));
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  if p_signed in ('kid', 'both') then
    insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
      values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
  end if;
  if p_signed = 'both' then
    insert into public.agreement_signatures (account_id, version, signer, signed_by)
      values (v_acct, 1, 'parent', v_user);
  end if;
  return v_acct;
end;
$$;
create function tests.session_for(p_username text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.sessions (id, user_id) values (v_id, tests.user_of(p_username));
  return v_id;
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 09:00');
select tests.new_kid('kid_a');                -- sessions and the PIN reset
select tests.new_kid('kid_b');                -- the setup script's set_kid_pin
select tests.new_kid('kid_n', 'none');        -- never signed
select tests.new_kid('kid_f', 'kid');         -- signed; Dad hasn't yet
create temp table s (k text primary key, id uuid);
insert into s values ('a', tests.session_for('kid_a')), ('b', tests.session_for('kid_b')),
                     ('dad', gen_random_uuid());
insert into auth.sessions (id, user_id) values ((select id from s where k = 'dad'), '00000000-0000-0000-0000-00000000000f');

-- 1. A session that was ended stops working at once ---------------------------------------------

select tests.as_kid('kid_a', (select id from s where k = 'a'));
select lives_ok('select public.request_deposit(1000)', 'with a live session she can act');
select is((select count(*)::int from public.my_activity(tests.acct('kid_a'), 20)), 1, '...and read her history');
select tests.as_parent('aal2', (select id from s where k = 'dad'));
create temp table code_a as select public.reset_kid_pin(tests.acct('kid_a')) as code;
select tests.as_kid('kid_a', (select id from s where k = 'a'));
select is(tests.err('select public.request_deposit(1000)'), 'You were signed out. Please sign in again.',
  'after Dad resets her PIN, a token from her ended session can''t act, even before it runs out');
select is(tests.err($$select count(*) from public.my_activity(tests.acct('kid_a'), 20)$$),
  'You can only see your own account.', '...or read her history');
set local role authenticated;
select is((select count(*)::int from public.accounts), 0, '...and row-level security shows it nothing');
reset role;
select tests.as_parent('aal2', gen_random_uuid());
select is(public.is_parent(), false, 'a parent token from an ended session isn''t a parent any more either');
select tests.as_parent('aal2', (select id from s where k = 'dad'));
select is(public.is_parent(), true, 'his live session still is');

-- 2. A PIN reset clears her lockouts ---------------------------------------------------------------

select tests.nobody();
select public.record_login_attempt('kid_b', false, '192.0.2.1') from generate_series(1, 5);
select ok((public.login_precheck('kid_b', '192.0.2.1') ->> 'locked_until') is not null, 'kid_b locked herself out');
select tests.as_parent('aal2', (select id from s where k = 'dad'));
create temp table code_b as select public.reset_kid_pin(tests.acct('kid_b')) as code;
select tests.nobody();
select is(public.login_precheck('kid_b', '192.0.2.1') -> 'locked_until', 'null'::jsonb,
  'Dad''s reset lifts the lock, so she can type his code straight away');
select is((select count(*)::int from public.alerts where kind = 'lockout' and resolved_at is null
            and details ->> 'username' = 'kid_b'), 0, '...and resolves the lockout alert');
select isnt((select code_hash from private.kid_pin_resets where account_id = tests.acct('kid_b')),
            public.kid_auth_password(tests.user_of('kid_b'), (select code from code_b)),
  'the code is stored with its own prefix, never as a password would be');

-- 4. The setup script: signed out everywhere, lockouts cleared, any reset ended -----------------

select public.record_login_attempt('kid_b', false, '192.0.2.2') from generate_series(1, 5);
select lives_ok($$select public.set_kid_pin('kid_b', '777111')$$, 'the setup script sets her PIN');
select is((select count(*)::int from auth.sessions where user_id = tests.user_of('kid_b')), 0, 'she is signed out everywhere');
select is(public.login_precheck('kid_b', '192.0.2.2') -> 'locked_until', 'null'::jsonb, 'her lockout is cleared');
select is((public.login_precheck('kid_b') ->> 'reset_pending')::boolean, false, 'and Dad''s pending reset is ended');

-- Lockouts escalate over a week, and the open alert shows the latest -----------------------------

select tests.clock('2026-10-06 09:00');
select tests.nobody();
create function tests.lock_kid_c() returns timestamptz language sql as $$
  select max((public.record_login_attempt('kid_c', false, '198.51.100.7') ->> 'locked_until')::timestamptz)
    from generate_series(1, 5);
$$;
select tests.new_kid('kid_c');
select tests.lock_kid_c();                 -- 15 minutes
select tests.clock('2026-10-06 09:20');
select tests.lock_kid_c();                 -- 1 hour
select tests.clock('2026-10-06 10:30');
select is(tests.lock_kid_c(), '2026-10-07 10:30-06'::timestamptz, 'the third lock in a week lasts 24 hours');
select tests.clock('2026-10-08 12:00');
select is(tests.lock_kid_c(), '2026-10-09 12:00-06'::timestamptz,
  'the next one, two days later, is 24 hours again (before: it started over at 15 minutes)');
select is((select message from public.alerts where kind = 'lockout' and resolved_at is null and details ->> 'username' = 'kid_c'),
  'kid_c''s login is locked for 24 hours on one device after 5 wrong PINs in a row.',
  'the one open alert always says how long the latest lock lasts');

-- Settings → Logins: a code that ran out --------------------------------------------------------

select tests.clock('2026-10-13 09:00');
select tests.as_parent();
select is((select (r ->> 'reset_expired')::boolean from jsonb_array_elements(public.parent_logins()) r
            where r ->> 'account_id' = tests.acct('kid_a')::text), true,
  'Dad sees kid_a''s code ran out (she needs another reset)');
select tests.nobody();
select is((public.login_precheck('kid_a') ->> 'reset_pending')::boolean, false, 'kid-login no longer offers the expired code');
select tests.as_kid('kid_a');
select is(tests.err('select public.parent_logins()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t see the logins list');
select tests.as_parent('aal1');
select is(tests.err('select public.parent_logins()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...nor Dad without his code');
select ok((select relrowsecurity from pg_class where oid = 'private.kid_pin_resets'::regclass),
  'the reset codes table has row-level security on');

-- Approving needs her signature; one first deposit at a time ----------------------------------------

select tests.nobody();
insert into public.requests (account_id, type, to_vehicle, amount_cents)
values (tests.acct('kid_n'), 'deposit', 'savings', 1000);
select tests.as_parent();
select is(tests.err($$select public.approve_request((select max(id) from public.requests where account_id = tests.acct('kid_n')))$$),
  'Test kid_n hasn''t signed her Big Bucks agreement yet, so nothing can be approved.',
  'nothing is approved for a girl who never signed');
select tests.as_kid('kid_f');
select lives_ok('select public.request_deposit(1000)', 'she asks for her first deposit before Dad signs');
select is(tests.err('select public.request_deposit(1000)'), 'Your first deposit is already waiting for Dad.',
  'one first deposit at a time');
select tests.as_parent();
select public.decline_request((select max(id) from public.requests where account_id = tests.acct('kid_f')), 'Let''s talk first');
select tests.as_kid('kid_f');
select lives_ok('select public.request_deposit(500)', 'after a no, she can ask again');

-- record_early_close: who may, and when it's refused ------------------------------------------------

select tests.clock('2026-11-05 18:00');
select tests.as_kid('kid_a');
select is(tests.err($$select public.record_early_close('nyse', '2026-11-05', '13:00', 'x')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t record an early close');
select tests.as_parent('aal1');
select is(tests.err($$select public.record_early_close('nyse', '2026-11-05', '13:00', 'x')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...nor Dad without his code');
select tests.nobody();
select tests.new_kid('kid_t');
insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, status, created_at,
                             settled_at, decided_at)
values (tests.acct('kid_t'), 'move', 'savings', 'stock', 'dow', 1000, 'settled', public.edmonton_at('2026-11-05 09:00'),
        public.close_time('nyse', '2026-11-05'), public.edmonton_at('2026-11-05 09:00'));
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                 posting_key, effective_at, note)
values (tests.acct('kid_t'), 'stock', 'dow', 'transfer_in', 1000, 0.02, 500,
        (select max(id) from public.requests where account_id = tests.acct('kid_t')),
        'trade:' || (select max(id) from public.requests where account_id = tests.acct('kid_t')) || ':fund',
        public.close_time('nyse', '2026-11-05'), 'Test.');
select tests.as_parent();
select is(tests.err($$select public.record_early_close('nyse', '2026-11-05', '13:00', 'Too late')$$),
  'A trade already settled at that day''s usual close, so its close time can''t change.',
  'refused once a trade settled at that day''s usual close');
select is(tests.err($$select public.record_early_close('nyse', '2026-11-07', '13:00', 'Weekend')$$),
  'The New York Stock Exchange doesn''t trade on Nov 7.', 'refused on a day the market doesn''t trade');
select is(
  array(select r from unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.record_early_close(public.market, date, time, text)', 'execute')),
  array['authenticated'], 'only signed-in users can call it (and then only Dad gets past its check)');

-- A closure keeps an official holiday row's source; closures and early closes take the price lock --

select is(
  (select count(*)::int from pg_proc p
    where p.proname in ('record_market_closure', 'record_early_close', 'settle_trades', 'pay_quarterly_dividends',
                        'correct_fund_price')
      and p.pronamespace = 'public'::regnamespace and p.prosrc like '%pg_advisory_xact_lock(hashtext(''close:''%'),
  5, 'closures, early closes, settlement, dividends and price fixes all take the same per-fund, per-day lock');
select tests.clock('2026-11-20 09:00');
select tests.as_parent();
select lives_ok($$select public.record_market_closure('nyse', '2026-11-27', 'Closed after all')$$,
  'Dad records a closure on a day the exchange had listed as an early close');
select results_eq(
  $$select kind::text, closes_at, confirmed, source_url <> 'Recorded by Dad in Big Bucks' from public.market_holidays
     where market = 'nyse' and holiday_date = '2026-11-27'$$,
  $$values ('closed', null::time, true, true)$$,
  'the day is closed, and the row keeps its official source, so the holiday warning still counts it');

-- Who may call the new helpers --------------------------------------------------------------------

select is(
  array(select f || ' ' || r from unnest(array['session_alive()', 'pin_reset_code_hash(uuid,text)',
                                              'clear_kid_lockouts(uuid)']) f,
                                unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.' || f, 'execute')),
  '{}'::text[], 'nobody calls the new helpers directly');
select ok((select prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%')
             from pg_proc where proname = 'session_alive'), 'session_alive is SECURITY DEFINER with a fixed search_path');

-- mark_production dates its rows by the app clock (last: it changes things for good) --------------

select tests.nobody();
select tests.clock('2027-03-01 09:00');
select public.mark_production();
select is((select effective_date from public.settings where key = 'is_production'), date '2027-03-01',
  'mark_production() dates its row by the app clock, not the server''s own date (on production they agree)');

select * from finish();
rollback;
