-- Noticing when GitHub's scheduler skips a day (Dad, 2026-10-11). The daily backup and
-- the daily health check both run on GitHub's schedule, which skipped a whole morning on
-- Oct 11, 2026. The database's own timer (pg_cron → nightly_kick) now checks every evening:
-- no backup recorded for 36 hours raises one backup_failed alert, and no health check
-- recorded for 36 hours one health_check_missing alert, each settled by the next good run.
-- Never before the first backup or health check ever, never without the Vault setup
-- (your own computer), never right after the pre-launch reset; and the money jobs are
-- untouched: the kick still queues tonight's call while the alerts are open.
--
-- Works on a fresh database and on one holding the local demo: earlier backup and
-- health records and their alerts are set aside first (rolled back at the end).
-- June 2027 (Alberta is UTC−6).
begin;
select plan(27);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.open(p_kind text) returns integer language sql as $$
  select count(*)::int from public.alerts where kind::text = p_kind and resolved_at is null;
$$;
create function tests.backup_at(p_at text) returns void language plpgsql as $$
begin
  perform tests.clock(p_at);
  perform public.record_backup(jsonb_build_object('taken_at', public.app_now(), 'counts', tests.counts()));
end;
$$;
create function tests.health_at(p_at text) returns void language plpgsql as $$
begin
  perform tests.clock(p_at);
  perform public.record_health_check();
end;
$$;
-- Rows in each table the pre-launch reset clears, as the daily backup records them.
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
create function tests.kick_at(p_at text) returns text language plpgsql as $$
begin
  perform tests.clock(p_at);
  return public.nightly_kick();
end;
$$;

-- A clean slate for this test: no backup or health check ever, no open alerts of these kinds,
-- and none of the Vault entries (as on your own computer).
delete from public.job_runs where job::text in ('backup', 'health');
update public.alerts set resolved_at = now() where kind::text in ('backup_failed', 'health_check_missing') and resolved_at is null;
delete from vault.secrets where name in ('nightly_function_url', 'nightly_function_key');

-- 1. Without the Vault setup (your own computer): nothing, however old the records.
select tests.backup_at('2027-06-04 08:37');
select tests.health_at('2027-06-04 08:07');
select is(tests.kick_at('2027-06-06 21:00'), 'not set up: the nightly function''s address and key aren''t in Vault',
  'without the Vault setup, the kick does nothing');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0,
  '...and raises no alert, though the last backup and health check are 2½ days old');
delete from public.job_runs where job::text in ('backup', 'health');

select vault.create_secret('http://supabase_kong_big-bucks:8000/functions/v1/nightly', 'nightly_function_url');
select vault.create_secret('local-nightly-key-for-this-computer-only', 'nightly_function_key');

-- 2. Before the first backup or health check ever: nothing to compare with, no alert.
select is(tests.kick_at('2027-06-06 21:30'), 'queued', 'Sunday 9:30 pm: the kick queues tonight''s call');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0,
  'before any backup or health check was ever recorded, no alert');

-- 3. Two good mornings.
select tests.health_at('2027-06-07 08:07');
select tests.backup_at('2027-06-07 08:37');
select tests.health_at('2027-06-08 08:07');
select tests.backup_at('2027-06-08 08:37');
select is(tests.kick_at('2027-06-08 21:00'), 'queued', 'Tuesday 9:00 pm: a normal evening, the call is queued');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0, '...and no alert: both ran this morning');

-- 4. Wednesday: GitHub skips the morning. Neither runs.
select is(tests.kick_at('2027-06-09 16:30'), 'queued', 'Wednesday 4:30 pm: the call is queued');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0, '...no alert yet (32 hours)');
select is(tests.kick_at('2027-06-09 20:00'), 'queued', 'Wednesday 8:00 pm: the call is queued');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0,
  '...no alert yet (35½ hours since the health check, 35 since the backup)');
select is(tests.kick_at('2027-06-09 21:00'), 'queued',
  'Wednesday 9:00 pm: the call is still queued while the alerts go up (the money jobs carry on)');
select is(tests.open('backup_failed'), 1, '...one backup alert, 36 hours on');
select is(tests.open('health_check_missing'), 1, '...one health check alert');
select is((select message from public.alerts where kind = 'backup_failed' and resolved_at is null),
  'The daily backup hasn''t succeeded since Jun 8. Check the Backup workflow in the big-bucks-backups repo on GitHub (RUNBOOK, "A backup failed").',
  'the backup alert in plain words');
select is((select message from public.alerts where kind = 'health_check_missing' and resolved_at is null),
  'The daily health check hasn''t run since Jun 8. Check the Health check workflow in the big-bucks-backups repo on GitHub (RUNBOOK, "The health check didn''t run").',
  'the health check alert in plain words');
select is((select bool_or(is_quiet) from public.alerts where kind::text in ('backup_failed', 'health_check_missing') and resolved_at is null),
  false, 'neither is quiet: both show on Dad''s Dashboard');
select is(tests.kick_at('2027-06-09 21:30'), 'queued', 'Wednesday 9:30 pm: the call is queued');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 2, '...and still one alert of each, not more');
select is((public.health_check() -> 'problems') @> '[{"kind": "alert", "alert_kind": "backup_failed"}, {"kind": "alert", "alert_kind": "health_check_missing"}]'::jsonb,
  true, 'the next health check that does run fails on both, so GitHub emails Dad');

-- 5. Thursday morning: both run again, and each settles its own alert.
select tests.health_at('2027-06-10 08:07');
select is(tests.open('health_check_missing'), 0, 'the next health check settles its alert');
select is(tests.open('backup_failed'), 1, '...not the backup''s');
select tests.backup_at('2027-06-10 08:37');
select is(tests.open('backup_failed'), 0, 'the next backup settles its alert');

-- 6. Right after the pre-launch reset (which needs a backup from the last 2 hours): no alert.
select tests.clock('2027-06-10 09:00');
select ok(public.prelaunch_reset('clear the test history') like 'Test history cleared:%', 'Thursday 9:00 am: the pre-launch reset');
select is(tests.kick_at('2027-06-10 21:00'), 'queued', 'Thursday 9:00 pm: the call is queued');
select is(tests.open('backup_failed') + tests.open('health_check_missing'), 0,
  '...and no alert right after the reset: the backup and health check are from this morning');

-- 7. Who may call what: the health function (service role) records its run; the app can't.
select is(has_function_privilege('service_role', 'public.record_health_check()', 'execute'), true,
  'the health function (service role) records each health check');
select is(has_function_privilege('authenticated', 'public.record_health_check()', 'execute')
          or has_function_privilege('anon', 'public.record_health_check()', 'execute'), false,
  '...and no app sign-in can');

select * from finish();
rollback;
