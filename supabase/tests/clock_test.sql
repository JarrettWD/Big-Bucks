-- Known-answer tests for the settings table and the app clock.
-- Each test file runs in a transaction that is rolled back, so the rows
-- inserted here never persist. now() is fixed for the whole transaction.
begin;
select plan(26);

-- Structure
select has_table('public', 'settings', 'settings table exists');
select has_function('public', 'app_now', 'app_now() exists');
select has_function('public', 'app_today', 'app_today() exists');

-- The migration's default and the local seed
select is(
  (select value from public.settings where key = 'is_local_dev' order by id asc limit 1),
  'false',
  'the migration sets is_local_dev to false'
);
select is(
  (select value from public.settings where key = 'is_local_dev' order by id desc limit 1),
  'true',
  'the local seed sets is_local_dev to true'
);

-- Local dev, no override: real time
insert into public.settings (key, value, effective_date) values ('is_local_dev', 'true', '2026-10-02');
select is(public.app_now(), now(), 'local dev with no override: app_now() is the real time');
select is(public.app_today(), (now() at time zone 'America/Edmonton')::date,
  'local dev with no override: app_today() is the real Edmonton date');

-- Local dev, override set: frozen at that Edmonton time
insert into public.settings (key, value, effective_date) values ('clock_override', '2026-11-15 09:30', '2026-10-02');
select is(public.app_now(), '2026-11-15 09:30:00 America/Edmonton'::timestamptz,
  'override freezes app_now() at the Edmonton time set');
select is(public.app_today(), date '2026-11-15', 'override sets app_today()');
select is(public.app_now(), public.app_now(), 'the frozen clock does not move');

-- Daylight saving: Edmonton is UTC-6 in summer, UTC-7 in winter
insert into public.settings (key, value, effective_date) values ('clock_override', '2026-07-01 12:00', '2026-10-02');
select is(public.app_now(), '2026-07-01 18:00:00+00'::timestamptz, 'summer: noon in Edmonton is 18:00 UTC');
insert into public.settings (key, value, effective_date) values ('clock_override', '2026-12-01 12:00', '2026-10-02');
select is(public.app_now(), '2026-12-01 19:00:00+00'::timestamptz, 'winter: noon in Edmonton is 19:00 UTC');

-- The Edmonton date, not the UTC date
insert into public.settings (key, value, effective_date) values ('clock_override', '2026-12-31 23:30', '2026-10-02');
select is(public.app_today(), date '2026-12-31', 'late on Dec 31 in Edmonton, app_today() is still Dec 31');
select is((public.app_now() at time zone 'UTC')::date, date '2027-01-01', '...even though it is already Jan 1 in UTC');

-- Date only means midnight
insert into public.settings (key, value, effective_date) values ('clock_override', '2027-02-28', '2026-10-02');
select is(public.app_now(), '2027-02-28 00:00:00 America/Edmonton'::timestamptz, 'a date with no time means midnight');

-- The newest row wins, whatever its effective_date
insert into public.settings (key, value, effective_date) values ('clock_override', '2027-05-01 08:00', '2099-01-01');
insert into public.settings (key, value, effective_date) values ('clock_override', '2027-03-01 08:00', '2000-01-01');
select is(public.app_today(), date '2027-03-01', 'the newest clock_override row wins regardless of effective_date');

-- A bad value is an error, not silently ignored
insert into public.settings (key, value, effective_date) values ('clock_override', 'next tuesday', '2026-10-02');
select throws_like('select public.app_now()', '%not a valid Edmonton date and time%',
  'a badly formatted override raises an error');

-- An empty value clears the override
insert into public.settings (key, value, effective_date) values ('clock_override', '', '2026-10-02');
select is(public.app_now(), now(), 'an empty override clears it: app_now() is the real time again');

-- Production: is_local_dev false ignores any override
insert into public.settings (key, value, effective_date) values ('clock_override', '2030-01-01 12:00', '2026-10-02');
select is(public.app_today(), date '2030-01-01', '(check) the override is active while is_local_dev is true');
insert into public.settings (key, value, effective_date) values ('is_local_dev', 'false', '2099-12-31');
select is(public.app_now(), now(), 'is_local_dev false: the override is ignored by app_now()');
select is(public.app_today(), (now() at time zone 'America/Edmonton')::date,
  'is_local_dev false: app_today() is the real Edmonton date');

-- Append-only, for every role
select throws_like($$update public.settings set value = 'true' where key = 'is_local_dev'$$,
  '%append-only%', 'settings rejects UPDATE');
select throws_like($$delete from public.settings where key = 'clock_override'$$,
  '%append-only%', 'settings rejects DELETE');
select throws_like('truncate public.settings', '%append-only%', 'settings rejects TRUNCATE');

-- The app's roles cannot write to settings directly (stage 1 adds functions)
set local role authenticated;
select throws_ok($$insert into public.settings (key, value, effective_date) values ('clock_override', '', '2026-10-02')$$,
  '42501', null, 'a signed-in user cannot insert into settings directly');
reset role;
set local role anon;
select throws_ok($$insert into public.settings (key, value, effective_date) values ('clock_override', '', '2026-10-02')$$,
  '42501', null, 'an anonymous caller cannot insert into settings directly');
reset role;

select * from finish();
rollback;
