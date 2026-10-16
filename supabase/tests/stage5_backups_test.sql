-- Stage 5: backups and data protection (plan approved by Dad 2026-10-10).
-- The backup login reads everything and changes nothing; each backup is recorded and
-- a backup that stops is noticed; Download backup is parent-with-MFA only, complete,
-- exact and logged; the pre-launch reset clears only history, needs a fresh backup
-- holding everything it clears, keeps every account and all configuration, and
-- refuses after launch; after_restore() puts back what a dump leaves out.
-- March 2027.
begin;
select plan(72);

create schema tests;
grant usage on schema tests to anon, authenticated, service_role, backup_reader;
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
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
grant execute on function tests.err(text) to anon, authenticated, service_role, backup_reader;
create function tests.new_kid(p_username text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
  insert into public.agreement_signatures (account_id, version, signer, signed_by)
    values (v_acct, 1, 'parent', v_user);
  update public.accounts set agreement_signed_at = public.app_now(), onboarding_done_at = public.app_now()
   where id = v_acct;
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
-- Rows in each table the reset clears, as the backup records them.
create function tests.counts() returns jsonb language plpgsql as $$
declare
  v_t text;
  v_n bigint;
  v_out jsonb := '{}'::jsonb;
begin
  foreach v_t in array private.prelaunch_tables() loop
    execute format('select count(*) from %s', v_t) into v_n;
    v_out := v_out || jsonb_build_object(v_t, v_n);
  end loop;
  return v_out;
end;
$$;
-- A backup recorded just now, as the backup workflow's last step does.
create function tests.backup(p_counts jsonb default null) returns text language plpgsql as $$
begin
  return public.record_backup(jsonb_build_object('taken_at', public.app_now(),
                                                 'counts', coalesce(p_counts, tests.counts())));
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2027-03-01 10:00');
select tests.new_kid('kid_s5');
select tests.fund('kid_s5', 2500);

-- 1. ping ------------------------------------------------------------------------------------------

set local role anon;
select is(public.ping(), 'ok', 'anyone can ping (the daily backup''s normal API request)');
reset role;

-- 2. The backup login: reads everything, changes nothing ---------------------------------------------

select is((select rolbypassrls from pg_roles where rolname = 'backup_reader'), true,
  'the backup login reads past row-level security, as pg_dump needs');
select is((select rolsuper or rolcreaterole or rolcreatedb from pg_roles where rolname = 'backup_reader'), false,
  '...and has no other powers');
select is(
  array(select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where c.relkind = 'r' and n.nspname in ('public', 'private')
           and not has_table_privilege('backup_reader', c.oid, 'SELECT') order by 1),
  '{}'::text[], 'it can read every table in public and private');
select is(
  array(select n.nspname || '.' || c.relname || ' ' || p
          from pg_class c join pg_namespace n on n.oid = c.relnamespace,
               unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
         where c.relkind = 'r' and n.nspname in ('public', 'private')
           and has_table_privilege('backup_reader', c.oid, p) order by 1),
  '{}'::text[], '...and can write to none of them');

create table public.stage5_new_table (id int);
select is(has_table_privilege('backup_reader', 'public.stage5_new_table', 'SELECT'), true,
  'a table added later is readable too, so it can never be left out of the backup');
drop table public.stage5_new_table;

-- What the backup login sees, collected as it (only inside this test, which is rolled
-- back), then checked as the owner: pgTAP itself isn't visible to that login.
grant backup_reader to postgres with inherit false;
set local role backup_reader;
select set_config('tests.br', jsonb_build_object(
  'alert', tests.err('insert into public.alerts (kind, message) values (''test'', ''x'')'),
  'account', tests.err('update public.accounts set name = name'),
  'reset', tests.err('select public.prelaunch_reset(''clear the test history'')'),
  'password', tests.err('select public.set_backup_login()'),
  'vault', tests.err('select count(*) from vault.decrypted_secrets'),
  'export', tests.err('select public.parent_backup_export()'),
  'ledger', (select count(*) from public.transactions),
  'auth', (select array_agg(table_name order by table_name) from private.backup_auth()),
  'users', (select row_count from private.backup_auth() where table_name = 'auth.users'),
  'hash', (select rows_json from private.backup_auth() where table_name = 'auth.users')::jsonb -> 0 ? 'encrypted_password',
  'exact', (select bool_and(amount ~ '^-?[0-9]+([.][0-9]+)?$') from private.backup_balances()))::text, true);
reset role;
create function tests.br(p_key text) returns text language sql as $$
  select current_setting('tests.br')::jsonb ->> p_key;
$$;
select ok(tests.br('alert') like 'permission denied%', 'the backup login can''t add an alert');
select ok(tests.br('account') like 'permission denied%', '...or change an account');
select ok(tests.br('reset') like 'permission denied%', '...or run the pre-launch reset');
select ok(tests.br('password') like 'permission denied%', '...or change its own password');
select ok(tests.br('vault') like 'permission denied%', '...or read Vault (the login key)');
select ok(tests.br('export') like 'permission denied%', '...or call Download backup');
select is(tests.br('ledger')::bigint, (select count(*) from public.transactions), 'it reads the whole ledger');
select is(tests.br('auth'), '["auth.identities", "auth.mfa_factors", "auth.users", "storage.buckets", "storage.objects"]',
  'it reads the logins a restore needs, and the storage counts');
select is(tests.br('users')::bigint, (select count(*) from auth.users), '...every login');
select is(tests.br('hash'), 'true', '...with its password hash, so a restore keeps every login');
select is(tests.br('exact'), 'true', 'its balances come as exact text');

select is((select amount from private.backup_balances() b
            join public.profiles p on p.account_id = b.account_id
           where p.username = 'kid_s5' and b.item = 'savings_cents'), '2500',
  'the balances are the database''s own (savings $25.00)');

select ok(tests.err('select public.record_backup(''{}''::jsonb)') like 'A backup record needs taken_at and counts.%',
  'a backup record without counts is refused');

-- set_backup_login: the owner only, and it changes the password (rolled back with this test).
set local role authenticated;
select ok(tests.err('select public.set_backup_login()') like 'permission denied%',
  'the app can''t set the backup login''s password');
reset role;
select ok(public.set_backup_login() like 'The backup login''s new password, shown only this once.%',
  'the owner gets a new password, shown once');
select is((select rolcanlogin from pg_roles where rolname = 'backup_reader'), true, '...and the login works');

-- 3. Each backup recorded; a backup that stops is noticed --------------------------------------------

create temp table had_backups as
  select exists (select 1 from public.job_runs where job = 'backup' and status = 'ok') as yes;
select is(case when (select yes from had_backups) then false else (public.check_backup_age() ->> 'late')::boolean end,
  false, 'before the first backup ever, nothing is late');

select tests.clock('2027-03-01 08:30');
select alike(tests.backup(), 'Backup recorded (%).', 'the workflow records a backup');
select is((select status::text || '/' || run_for_date::text from public.job_runs where job = 'backup' order by id desc limit 1),
  'ok/2027-03-01', '...in job_runs, for today');

select tests.clock('2027-03-02 20:00');
select is((public.check_backup_age() ->> 'late')::boolean, false, '35½ hours later: not late yet');
select tests.clock('2027-03-02 21:00');
select is(public.check_backup_age() ->> 'alert_raised', 'true', '36½ hours: a backup alert');
select is(public.check_backup_age() ->> 'alert_raised', 'false', '...only one');
select is((select message from public.alerts where kind = 'backup_failed' and resolved_at is null),
  'The daily backup hasn''t succeeded since Mar 1. Check the Backup workflow in the big-bucks-backups repo on GitHub (RUNBOOK, "A backup failed").',
  '...in plain words');
select is((public.health_check() -> 'problems') @> '[{"kind": "alert", "alert_kind": "backup_failed"}]'::jsonb, true,
  '...which fails the health check, so GitHub emails Dad');
select is((select is_quiet from public.alerts where kind = 'backup_failed' and resolved_at is null), false,
  '...and shows on his Dashboard');
select tests.backup();
select is((select count(*)::int from public.alerts where kind = 'backup_failed' and resolved_at is null), 0,
  'the next good backup settles it');

-- 4. Download backup ------------------------------------------------------------------------------

select tests.as_kid('kid_s5');
select ok(tests.err('select public.parent_backup_export()') like 'Only a parent signed in with the second step%',
  'a kid can''t download a backup');
select tests.as_parent('aal1');
select ok(tests.err('select public.parent_backup_export()') like 'Only a parent signed in with the second step%',
  'nor Dad without the authenticator code');
select tests.as_parent();
create temp table export as select public.parent_backup_export() as e;
select tests.nobody();

select is((select jsonb_array_length(e -> 'tables') from export),
  (select count(*)::int from pg_tables where schemaname in ('public', 'private')), 'every table is in it');
select is((select e ->> 'day' from export), '2027-03-02', 'it''s named by today''s date');
select is((select (t ->> 'rows')::bigint from export, jsonb_array_elements(e -> 'tables') t
            where t ->> 'name' = 'public.transactions'),
  (select count(*) from public.transactions), 'the ledger''s rows are all there');
select is((select jsonb_array_length((t ->> 'json')::jsonb) from export, jsonb_array_elements(e -> 'tables') t
            where t ->> 'name' = 'public.transactions'),
  (select count(*)::int from public.transactions), '...in the JSON file');
select is((select array_length(string_to_array(rtrim(t ->> 'csv', E'\n'), E'\n'), 1) from export, jsonb_array_elements(e -> 'tables') t
            where t ->> 'name' = 'public.transactions'),
  (select count(*)::int + 1 from public.transactions), '...and the CSV file (a header, then one line each)');
select ok((select split_part(t ->> 'csv', E'\n', 1) from export, jsonb_array_elements(e -> 'tables') t
            where t ->> 'name' = 'public.transactions') like 'id,account_id,%',
  'the CSV header names the columns');
select is((select position('code_hash' in t ->> 'csv') + position('code_hash' in t ->> 'json')
             from export, jsonb_array_elements(e -> 'tables') t where t ->> 'name' = 'private.kid_pin_resets'), 0,
  'a PIN reset code''s hash is left out of the download');
select is((select summary from public.parent_actions order by id desc limit 1),
  'Downloaded a backup (' || (select jsonb_array_length(e -> 'tables') from export) || ' tables, '
    || (select sum((t ->> 'rows')::bigint) from export, jsonb_array_elements(e -> 'tables') t) || ' rows).',
  'the download is in the parent log');
select is((select action || '/' || done_by::text from public.parent_actions order by id desc limit 1),
  'download_backup/00000000-0000-0000-0000-00000000000f', '...with who did it');

select is(private.csv_field('a,b'), '"a,b"', 'CSV: a comma is quoted');
select is(private.csv_field('say "hi"'), '"say ""hi"""', 'CSV: quotes are doubled');
select is(private.csv_field(null), '', 'CSV: null is empty');
select is(private.csv_field('12.34567891'), '12.34567891', 'CSV: a number stays exactly as it is');

-- 5. The pre-launch reset ------------------------------------------------------------------------------

set local role authenticated;
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'permission denied%',
  'the app can''t run the pre-launch reset');
reset role;
set local role service_role;
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'permission denied%',
  '...nor the server');
reset role;
select tests.as_parent();
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'Only the database owner can run the pre-launch reset%',
  '...nor anything carrying a sign-in, even as the owner');
select tests.nobody();
select ok(tests.err('select public.prelaunch_reset(''yes'')') like 'To confirm, type exactly: select public.prelaunch_reset(''clear the test history'');%',
  'it needs the exact words');

-- No backup in the last 2 hours.
select tests.clock('2027-03-02 23:30');
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'Take a backup first:%',
  'it refuses without a backup from the last 2 hours');

-- A fresh backup that doesn't hold everything (one deposit since).
select tests.backup();
select tests.fund('kid_s5', 500);
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'Something changed since the last backup (public.%',
  'it refuses when something changed since the backup');

-- Stage 9: a wish, its photo and Dad's "Got it" marker are test history too.
select tests.backup();
insert into public.wishlist_items (id, account_id, name, price_cents, stars)
values ('99999999-0000-0000-0000-000000000009', (select account_id from public.profiles where username = 'kid_s5'), 'Kite', 2500, 4);
insert into public.wishlist_photos (wishlist_item_id, account_id, photo, thumb)
values ('99999999-0000-0000-0000-000000000009', (select account_id from public.profiles where username = 'kid_s5'),
        '\xffd8ff'::bytea || decode(repeat('ab', 200), 'hex'), '\xffd8ff'::bytea || decode(repeat('ab', 200), 'hex'));
insert into public.wishlist_parent_marks (wishlist_item_id, note) values ('99999999-0000-0000-0000-000000000009', 'Got it');
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'Something changed since the last backup (public.wishlist_%',
  'a wish or photo added since the backup counts as a change too');

-- What must survive.
select tests.backup();
create temp table kept as
  select (select count(*) from public.accounts) as accounts, (select count(*) from public.profiles) as profiles,
         (select count(*) from auth.users) as logins, (select count(*) from public.rates) as rates,
         (select count(*) from public.settings) as settings, (select count(*) from public.cancellations) as cancellations,
         (select count(*) from public.glossary) as glossary, (select count(*) from public.fund_prices) as prices,
         (select count(*) from public.fund_price_corrections) as corrections, (select count(*) from public.price_calls) as calls,
         (select count(*) from public.parent_actions) as log, (select count(*) from public.job_runs) as jobs,
         (select count(*) from public.market_holidays) as holidays, (select count(*) from public.agreement_versions) as agreements;
create temp table before_counts as select tests.counts() as c;

select alike(public.prelaunch_reset('clear the test history'),
  'Test history cleared: % rows from 17 tables. Every account, rate, setting and price is kept, and every balance is now $0.00.',
  'with a fresh backup holding everything, it clears the test history');
select is(tests.counts(), (select jsonb_object_agg(k, 0) from jsonb_object_keys((select c from before_counts)) k),
  'every history table is empty: ledger, accruals, GICs, requests, notices, questions, goals, badges, wish list (photos and marks too), signatures, What''s new seen, alerts, login attempts, outbox, PIN resets');
select is((select count(*) from public.transactions), 0::bigint, '...the ledger included');
select is((select array[accounts, profiles, logins] from kept),
  array[(select count(*) from public.accounts), (select count(*) from public.profiles), (select count(*) from auth.users)],
  'every account and login is kept, test kid included');
select is((select array[rates, settings, cancellations, glossary, prices, corrections, calls, holidays, agreements] from kept),
  array[(select count(*) from public.rates), (select count(*) from public.settings), (select count(*) from public.cancellations),
        (select count(*) from public.glossary), (select count(*) from public.fund_prices),
        (select count(*) from public.fund_price_corrections), (select count(*) from public.price_calls),
        (select count(*) from public.market_holidays), (select count(*) from public.agreement_versions)],
  'configuration is kept: rates, settings, cancellations, glossary, prices, corrections, price calls, holidays, agreement wording');
select is((select array[log, jobs] from kept),
  array[(select count(*) from public.parent_actions), (select count(*) from public.job_runs)],
  '...and the parent log and job history (so no night runs again)');
select is((select sum(total_worth_cents)::bigint from public.account_balances), 0::bigint, 'every balance is $0.00');
select is((select count(*)::int from public.accounts where agreement_signed_at is not null or onboarding_done_at is not null), 0,
  'each account starts its agreement and onboarding afresh');
select is((select cleared -> 'public.transactions' from public.prelaunch_resets order by id desc limit 1),
  (select c -> 'public.transactions' from before_counts), 'the reset records what it cleared');

select ok(tests.err('truncate public.transactions') is not null, 'the ledger''s guard is back on: truncate is refused again');
select is(
  array(select t.tgrelid::regclass::text || ' ' || t.tgname from pg_trigger t
         where t.tgfoid = 'public.reject_append_only_change()'::regprocedure and t.tgenabled <> 'O' order by 1),
  '{}'::text[], '...and every append-only guard is switched on again');
select ok(tests.err('update public.prelaunch_resets set cleared = ''{}''') is not null, 'the reset record itself is append-only');

-- After launch, never again.
select tests.backup();
insert into public.settings (key, value, effective_date) values ('launched_at', '2027-03-03 09:00', date '2027-03-03');
select ok(tests.err('select public.prelaunch_reset(''clear the test history'')') like 'Big Bucks has launched (launched_at is set), so the pre-launch reset can never run again.%',
  'once launched_at is set, it refuses for good');

-- 6. After a restore ------------------------------------------------------------------------------------

select cron.unschedule('big-bucks-nightly');
select is((select result from public.after_restore() where step = 'Nightly timer'), 'Put back.',
  'after a restore, the nightly timer is put back');
select is((select schedule from cron.job where jobname = 'big-bucks-nightly'), '0,30 22,23,0,1,2,3,4 * * *',
  '...on the same schedule');
select is((select result from public.after_restore() where step = 'Login guard'), 'Already there.',
  'the login guard is left alone when it''s there');
select is((select result from public.after_restore() where step = 'Login key'), 'Already there.',
  'and so is the login key');
set local role authenticated;
select ok(tests.err('select * from public.after_restore()') like 'permission denied%', 'the app can''t run it');
reset role;

select * from finish();
rollback;
