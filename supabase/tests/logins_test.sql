-- Logins (stage 6): creating accounts, the kid-login lookup, and the PIN lockout.
begin;
select plan(45);

-- Test helpers ----------------------------------------------------------------

create schema tests;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.new_user(p_email text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_user, p_email);
  return v_user;
end;
$$;
create function tests.fail(p_username text) returns jsonb language sql as $$
  select public.record_login_attempt(p_username, false);
$$;
create function tests.attempts(p_username text) returns bigint language sql as $$
  select count(*) from public.login_attempts where username = p_username;
$$;
create function tests.lockout_alerts(p_account uuid) returns bigint language sql as $$
  select count(*) from public.alerts where kind = 'lockout' and account_id is not distinct from p_account;
$$;

select tests.clock('2026-10-05 09:00');

-- 1. Who may call what ------------------------------------------------------------

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('create_kid_account', 'create_parent_profile', 'login_precheck', 'record_login_attempt')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  '{}'::text[], 'signed-in users (kids and Dad) cannot create accounts or touch the login records');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('create_kid_account', 'create_parent_profile', 'login_precheck', 'record_login_attempt')
           and has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'anonymous callers cannot either');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('create_kid_account', 'create_parent_profile', 'login_precheck', 'record_login_attempt')
           and has_function_privilege('service_role', p.oid, 'EXECUTE') order by 1),
  array['create_kid_account', 'create_parent_profile', 'login_precheck', 'record_login_attempt'],
  'the server (setup script and kid-login function) can call all four');
select ok(
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('create_kid_account', 'create_parent_profile', 'login_precheck', 'record_login_attempt')),
  'all four are SECURITY DEFINER with a fixed search_path');

-- 2. Creating accounts --------------------------------------------------------------

create temp table ids (name text primary key, id uuid);
insert into ids values
  ('kid_a_user', tests.new_user('kid_a@kids.local')),
  ('kid_b_user', tests.new_user('kid_b@kids.local')),
  ('parent_user', tests.new_user('parent@test.invalid')),
  ('spare_user', tests.new_user('spare@kids.local'));

insert into ids values ('kid_a', public.create_kid_account(
  (select id from ids where name = 'kid_a_user'), 'kid_a', 'Kid A', false));
insert into ids values ('kid_b', public.create_kid_account(
  (select id from ids where name = 'kid_b_user'), 'kid_b', 'Kid B', true));
select public.create_parent_profile((select id from ids where name = 'parent_user'), 'the_parent', 'Parent');

select is((select name from public.accounts where id = (select id from ids where name = 'kid_a')), 'Kid A',
  'a kid account is named with her display name');
select is((select is_test from public.accounts where id = (select id from ids where name = 'kid_a')), false,
  'kid A is a regular account');
select is((select is_test from public.accounts where id = (select id from ids where name = 'kid_b')), true,
  'kid B is a test account');
select is((select created_at from public.accounts where id = (select id from ids where name = 'kid_a')),
  '2026-10-05 09:00 America/Edmonton'::timestamptz, 'the account opens at the app clock''s time');
select is(
  (select row(role::text, account_id, username, display_name)::text from public.profiles
    where user_id = (select id from ids where name = 'kid_a_user')),
  row('investor', (select id from ids where name = 'kid_a'), 'kid_a', 'Kid A')::text,
  'her profile links her login to her account');
select is(
  (select row(role::text, account_id, username)::text from public.profiles
    where user_id = (select id from ids where name = 'parent_user')),
  row('parent', null::uuid, 'the_parent')::text,
  'the parent''s profile has no account');

select throws_ok(
  format($$select public.create_kid_account(%L, 'kid_a', 'Again', false)$$, (select id from ids where name = 'spare_user')),
  null, 'The username "kid_a" is already taken.', 'a username can be used only once');
select throws_ok(
  format($$select public.create_kid_account(%L, 'kid_c', 'Again', false)$$, (select id from ids where name = 'kid_a_user')),
  null, 'That login already has a profile.', 'a login can have only one profile');
select throws_ok(
  format($$select public.create_kid_account(%L, 'Bad Name!', 'Spare', false)$$, (select id from ids where name = 'spare_user')),
  null, 'A username is 3 to 30 lowercase letters, numbers or _.', 'usernames are lowercase letters, numbers and _');
select throws_ok(
  $$select public.create_kid_account(gen_random_uuid(), 'kid_c', 'Nobody', false)$$,
  null, 'There''s no login with that id.', 'the login must exist first');
select throws_ok(
  format($$select public.create_kid_account(%L, 'kid_c', '  ', false)$$, (select id from ids where name = 'spare_user')),
  null, 'A display name can''t be empty.', 'a display name is required');

-- 3. The kid-login lookup ------------------------------------------------------------

select is(public.login_precheck('kid_a'),
  jsonb_build_object('is_kid', true, 'email', 'kid_a@kids.local', 'locked_until', null),
  'a kid''s username gives her hidden email, not locked');
select is(public.login_precheck('  KID_A '),
  jsonb_build_object('is_kid', true, 'email', 'kid_a@kids.local', 'locked_until', null),
  'usernames ignore capitals and spaces around them');
select is(public.login_precheck('the_parent'),
  jsonb_build_object('is_kid', false, 'email', null, 'locked_until', null),
  'a parent username gives nothing: the PIN door is for kids only');
select is(public.login_precheck('nobody_here'),
  jsonb_build_object('is_kid', false, 'email', null, 'locked_until', null),
  'an unknown username gives nothing');

-- 4. The lockout: 5 wrong PINs in a row lock for 15 minutes --------------------------

select is(tests.fail('kid_a'), jsonb_build_object('locked_until', null, 'tries_left', 4), '1st wrong PIN: 4 tries left');
select tests.clock('2026-10-05 09:01');
select tests.fail('kid_a');
select tests.fail('kid_a');
select is(tests.fail('KID_A'), jsonb_build_object('locked_until', null, 'tries_left', 1),
  '4th wrong PIN (any capitals): 1 try left, not locked yet');
select is(tests.lockout_alerts((select id from ids where name = 'kid_a')), 0::bigint, 'no alert before the lockout');
select is(tests.fail('kid_a'),
  jsonb_build_object('locked_until', '2026-10-05 09:16 America/Edmonton'::timestamptz, 'tries_left', 0),
  '5th wrong PIN in a row: locked for 15 minutes');
select is((public.login_precheck('kid_a') ->> 'locked_until')::timestamptz,
  '2026-10-05 09:16 America/Edmonton'::timestamptz, 'the lookup reports the lock');
select is(tests.lockout_alerts((select id from ids where name = 'kid_a')), 1::bigint, 'Dad gets one lockout alert');
select is(
  (select row(is_quiet, message)::text from public.alerts where kind = 'lockout'
    and account_id = (select id from ids where name = 'kid_a')),
  row(false, 'Kid A''s login is locked for 15 minutes after 5 wrong PINs in a row.')::text,
  'the alert is raised (not quiet) for a regular account, in plain words');
select ok(exists (select 1 from jsonb_array_elements(public.health_check() -> 'problems') p where p ->> 'alert_kind' = 'lockout'),
  'an open lockout alert fails the health check, so GitHub emails Dad');

select tests.clock('2026-10-05 09:10');
select is(tests.attempts('kid_a'), 5::bigint, 'five attempts recorded');
select is(public.record_login_attempt('kid_a', true),
  jsonb_build_object('locked_until', '2026-10-05 09:16 America/Edmonton'::timestamptz, 'tries_left', 0),
  'while locked, even a right PIN is refused');
select is(tests.attempts('kid_a'), 5::bigint, 'and nothing is recorded while locked');

select tests.clock('2026-10-05 09:16');
select is(public.login_precheck('kid_a') -> 'locked_until', 'null'::jsonb, 'exactly 15 minutes later she can try again');
select is(tests.fail('kid_a'), jsonb_build_object('locked_until', null, 'tries_left', 4),
  'after a lockout, the count starts again from 5');
select tests.fail('kid_a');
select tests.fail('kid_a');
select tests.fail('kid_a');
select is(public.record_login_attempt('kid_a', true), jsonb_build_object('locked_until', null, 'tries_left', 5),
  'a right PIN signs her in and resets the count');
select tests.fail('kid_a');
select tests.fail('kid_a');
select tests.fail('kid_a');
select is(tests.fail('kid_a'), jsonb_build_object('locked_until', null, 'tries_left', 1),
  'so 4 more wrong PINs after a success do not lock (only 5 in a row do)');
select is(tests.lockout_alerts((select id from ids where name = 'kid_a')), 1::bigint, 'still only the one alert');
select is(
  (select user_id from public.login_attempts where username = 'kid_a' order by id desc limit 1),
  (select id from ids where name = 'kid_a_user'), 'attempts record which login they were for');

-- 5. A test account's lockout is logged quietly --------------------------------------

select tests.clock('2026-10-05 10:00');
select tests.fail('kid_b') from generate_series(1, 4);
select is((tests.fail('kid_b') ->> 'locked_until')::timestamptz, '2026-10-05 10:15 America/Edmonton'::timestamptz,
  'a test kid locks the same way');
select is((select is_quiet from public.alerts where kind = 'lockout' and account_id = (select id from ids where name = 'kid_b')),
  true, 'but her alert is quiet');

-- 6. Unknown usernames and the parent's username lock too -------------------------

select tests.fail('nobody_here') from generate_series(1, 4);
select is((tests.fail('nobody_here') ->> 'tries_left')::int, 0, 'guessing at an unknown username locks too');
select is(
  (select row(is_quiet, message)::text from public.alerts where kind = 'lockout' and account_id is null
    and details ->> 'username' = 'nobody_here'),
  row(false, 'Someone typed 5 wrong PINs in a row for the username "nobody_here", which isn''t a kid''s login. It''s locked for 15 minutes.')::text,
  'and Dad hears about it');
select is(
  (select user_id from public.login_attempts where username = 'nobody_here' limit 1), null::uuid,
  'unknown usernames have no login id');
select tests.fail('the_parent') from generate_series(1, 5);
select ok((public.login_precheck('the_parent') ->> 'locked_until') is not null, 'the parent username locks on the PIN door too');
select is(
  (select user_id from public.login_attempts where username = 'the_parent' limit 1), null::uuid,
  'the PIN door never treats the parent as a known kid login');

-- 7. Odd input ------------------------------------------------------------------------

select throws_ok($$select public.record_login_attempt('', false)$$, null, 'A username is needed.',
  'an empty username is refused');
select tests.fail(repeat('x', 500));
select is(length((select username from public.login_attempts order by id desc limit 1)), 40,
  'a very long username is cut to 40 characters before it''s stored');

select * from finish();
rollback;
