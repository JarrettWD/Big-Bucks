-- Logins (stage 6): creating accounts, the kid-login lookup, and the PIN lockout.
begin;
select plan(69);

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
  '2026-10-05 09:00-06'::timestamptz, 'the account opens at the app clock''s time');
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
  jsonb_build_object('is_kid', true, 'user_id', (select id from ids where name = 'kid_a_user'), 'email', 'kid_a@kids.local', 'reset_pending', false, 'locked_until', null),
  'a kid''s username gives her hidden email, not locked');
select is(public.login_precheck('  KID_A '),
  jsonb_build_object('is_kid', true, 'user_id', (select id from ids where name = 'kid_a_user'), 'email', 'kid_a@kids.local', 'reset_pending', false, 'locked_until', null),
  'usernames ignore capitals and spaces around them');
select is(public.login_precheck('the_parent'),
  jsonb_build_object('is_kid', false, 'user_id', null, 'email', null, 'reset_pending', false, 'locked_until', null),
  'a parent username gives nothing: the PIN door is for kids only');
select is(public.login_precheck('nobody_here'),
  jsonb_build_object('is_kid', false, 'user_id', null, 'email', null, 'reset_pending', false, 'locked_until', null),
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
  jsonb_build_object('locked_until', '2026-10-05 09:16-06'::timestamptz, 'tries_left', 0),
  '5th wrong PIN in a row: locked for 15 minutes');
select is((public.login_precheck('kid_a') ->> 'locked_until')::timestamptz,
  '2026-10-05 09:16-06'::timestamptz, 'the lookup reports the lock');
select is(tests.lockout_alerts((select id from ids where name = 'kid_a')), 1::bigint, 'Dad gets one lockout alert');
select is(
  (select row(is_quiet, message)::text from public.alerts where kind = 'lockout'
    and account_id = (select id from ids where name = 'kid_a')),
  row(false, 'Kid A''s login is locked for 15 minutes on one device after 5 wrong PINs in a row.')::text,
  'the alert is raised (not quiet) for a regular account, in plain words');
select ok(exists (select 1 from jsonb_array_elements(public.health_check() -> 'problems') p where p ->> 'alert_kind' = 'lockout'),
  'an open lockout alert fails the health check, so GitHub emails Dad');

select tests.clock('2026-10-05 09:10');
select is(tests.attempts('kid_a'), 5::bigint, 'five attempts recorded');
select is(public.record_login_attempt('kid_a', true),
  jsonb_build_object('locked_until', '2026-10-05 09:16-06'::timestamptz, 'tries_left', 0),
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
select is((tests.fail('kid_b') ->> 'locked_until')::timestamptz, '2026-10-05 10:15-06'::timestamptz,
  'a test kid locks the same way');
select is((select is_quiet from public.alerts where kind = 'lockout' and account_id = (select id from ids where name = 'kid_b')),
  true, 'but her alert is quiet');

-- 6. Unknown usernames and the parent's username lock too -------------------------

select tests.fail('nobody_here') from generate_series(1, 4);
select is((tests.fail('nobody_here') ->> 'tries_left')::int, 0, 'guessing at an unknown username locks too');
select is(
  (select row(is_quiet, message)::text from public.alerts where kind = 'lockout' and account_id is null
    and details ->> 'username' = 'nobody_here'),
  row(true, 'Someone typed wrong PINs for a username that isn''t a kid''s login (nobody_here). Nothing to do: there''s no account behind it.')::text,
  'Dad''s log notes it quietly: there''s no account to protect, and it doesn''t fail the health check');
select is(
  (select user_id from public.login_attempts where username = 'nobody_here' limit 1), null::uuid,
  'unknown usernames have no login id');
select tests.fail('the_parent') from generate_series(1, 5);
select ok((public.login_precheck('the_parent') ->> 'locked_until') is not null, 'the parent username locks on the PIN door too');
select is(
  (select user_id from public.login_attempts where username = 'the_parent' limit 1), null::uuid,
  'the PIN door never treats the parent as a known kid login');

-- 6b. Pre-launch audit (2026-10-08): devices, the username-wide lock, quiet alerts --------

-- A stranger's device can't keep her locked out: 5 wrong PINs lock only that device.
select tests.clock('2026-10-06 09:00');
update public.alerts set resolved_at = public.app_now() where kind = 'lockout';
select public.record_login_attempt('kid_a', false, '203.0.113.7') from generate_series(1, 4);
select is((public.record_login_attempt('kid_a', false, '203.0.113.7') ->> 'locked_until')::timestamptz,
  '2026-10-06 09:15-06'::timestamptz, '5 wrong PINs from one device lock that device for 15 minutes');
select ok((public.login_precheck('kid_a', '203.0.113.7') ->> 'locked_until') is not null, 'that device is locked...');
select is(public.login_precheck('kid_a', '198.51.100.20') -> 'locked_until', 'null'::jsonb,
  '...but her own device (another address) is not');
select is(public.record_login_attempt('kid_a', true, '198.51.100.20'),
  jsonb_build_object('locked_until', null, 'tries_left', 5), 'so she can still sign in from it');
select is((select count(*)::int from public.login_attempts where client in ('203.0.113.7', '198.51.100.20')), 0,
  'IP addresses are never stored, only a keyed hash of them');
select is((select count(distinct client)::int from public.login_attempts where username = 'kid_a' and client <> ''), 2,
  '...one label per device');

-- Spreading guesses over many devices doesn't help: 20 in a row lock the username for everyone.
select tests.clock('2026-10-07 10:00');
update public.alerts set resolved_at = public.app_now() where kind = 'lockout';
select public.record_login_attempt('kid_a', false, '192.0.2.' || (n / 4)) from generate_series(1, 19) n;
select is(public.login_precheck('kid_a', '198.51.100.20') -> 'locked_until', 'null'::jsonb,
  '19 wrong PINs spread over 5 devices: no device has 5 in a row, nothing is locked yet');
select is((public.record_login_attempt('kid_a', false, '192.0.2.99') ->> 'locked_until')::timestamptz,
  '2026-10-07 10:15-06'::timestamptz, 'the 20th wrong PIN in a row, from any device, locks the username...');
select ok((public.login_precheck('kid_a', '198.51.100.20') ->> 'locked_until') is not null,
  '...for every device, hers included, for 15 minutes');
select is(
  (select message from public.alerts where kind = 'lockout' and resolved_at is null and details ->> 'username' = 'kid_a'),
  'Kid A''s login is locked for 15 minutes: 20 wrong PINs in a day, from more than one device.',
  'Dad''s alert says so');

-- One open alert per username: more lockouts while Dad hasn't looked add nothing.
select tests.clock('2026-10-07 10:20');
select public.record_login_attempt('kid_a', false, '203.0.113.8') from generate_series(1, 5);
select is((select count(*)::int from public.alerts where kind = 'lockout' and resolved_at is null
            and details ->> 'username' = 'kid_a'), 1, 'another lockout while the alert is open adds no second alert');

-- Usernames that aren't a kid's share one quiet alert, however many are tried.
select public.record_login_attempt('random_' || n / 5, false, '203.0.113.9') from generate_series(0, 24) n;
select is((select count(*)::int from public.alerts where kind = 'lockout' and resolved_at is null
            and details ->> 'not_a_kid' = 'true'), 1, 'made-up usernames share one open quiet alert');
select ok(not exists (select 1 from jsonb_array_elements(public.health_check() -> 'problems') p
                       where p ->> 'alert_kind' = 'lockout' and p ->> 'message' like 'Someone typed%'),
  '...which never fails the health check');

-- Old attempts are deleted after 30 days.
select tests.clock('2026-11-10 09:00');
select public.record_login_attempt('kid_b', true);
select is((select count(*)::int from public.login_attempts where attempted_at < '2026-10-11'::timestamptz), 0,
  'attempts older than 30 days are deleted');

-- Her Supabase Auth password is worked out from her PIN on the server; it is never the PIN.
select is(length(public.kid_auth_password((select id from ids where name = 'kid_a_user'), '123456')), 64,
  'her Auth password is a 64-character key');
select isnt(public.kid_auth_password((select id from ids where name = 'kid_a_user'), '123456'), '123456',
  '...never her PIN');
select is(public.kid_auth_password((select id from ids where name = 'kid_a_user'), '123456'),
          public.kid_auth_password((select id from ids where name = 'kid_a_user'), '123456'),
  '...the same every time for the same login and PIN');
select isnt(public.kid_auth_password((select id from ids where name = 'kid_a_user'), '123456'),
            public.kid_auth_password((select id from ids where name = 'kid_b_user'), '123456'),
  '...and different for another kid with the same PIN');
select throws_ok($$select public.kid_auth_password(gen_random_uuid(), '12345')$$, null, 'A PIN is exactly 6 digits.',
  'only a 6-digit PIN');
select is(
  array(select r from unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.kid_auth_password(uuid, text)', 'execute')),
  array['service_role'], 'only the server can work it out (the app''s users can''t)');

-- A kid can't change her own password or email through Supabase Auth.
select throws_ok(
  format($$update auth.users set encrypted_password = 'x' where id = %L$$, (select id from ids where name = 'kid_a_user')),
  '42501', 'A kid''s PIN and login can''t be changed from the app.', 'a kid''s password can''t be changed');
select throws_ok(
  format($$update auth.users set email = 'new@kids.local' where id = %L$$, (select id from ids where name = 'kid_a_user')),
  '42501', 'A kid''s PIN and login can''t be changed from the app.', '...nor her email');
select lives_ok(
  format($$update auth.users set last_sign_in_at = now() where id = %L$$, (select id from ids where name = 'kid_a_user')),
  'signing in (which updates her login row) still works');
select lives_ok(
  format($$update auth.users set encrypted_password = 'x' where id = %L$$, (select id from ids where name = 'parent_user')),
  'the parent''s own password can still change');

-- 7. Odd input ------------------------------------------------------------------------

select throws_ok($$select public.record_login_attempt('', false)$$, null, 'A username is needed.',
  'an empty username is refused');
select tests.fail(repeat('x', 500));
select is(length((select username from public.login_attempts order by id desc limit 1)), 40,
  'a very long username is cut to 40 characters before it''s stored');

select * from finish();
rollback;
