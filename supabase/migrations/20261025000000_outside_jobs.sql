-- Noticing a skipped day without GitHub (Dad, 2026-10-11). The daily backup and the
-- daily health check both run on GitHub's schedule, and on Oct 11, 2026 neither fired.
-- Until now only the health check called check_backup_age(), so a day GitHub skipped
-- silenced both. The database's own timer (pg_cron → nightly_kick, every 30 minutes
-- from 4:30 pm) now checks every evening too:
--
-- 1. record_health_check(): the health function records each health check it runs
--    (job_runs, job 'health'), and the run settles an open health_check_missing alert.
-- 2. check_health_age(): once any health check has been recorded, none for 36 hours
--    raises one health_check_missing alert, like check_backup_age() for the backup.
-- 3. nightly_kick() calls both from 4:30 pm (check_outside_jobs), before deciding
--    whether tonight's work is done, so they run every evening. Nothing else in the
--    kick changes: tonight's call is queued exactly as before, alerts or not.
--
-- No interest, GIC, fund or posting code is touched. Known answers:
-- supabase/tests/outside_jobs_test.sql.

alter type public.job_name add value if not exists 'health';
alter type public.alert_kind add value if not exists 'health_check_missing';

-- 1. The health function records each run ---------------------------------------------------------------

create function public.record_health_check()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.job_runs (job, run_for_date, status, details, finished_at)
  values ('health', public.app_today(), 'ok', null, public.app_now())
  returning id into v_id;
  update public.alerts set resolved_at = public.app_now()
   where kind = 'health_check_missing' and resolved_at is null;
  return 'Health check recorded (' || v_id || ').';
end;
$$;
comment on function public.record_health_check() is
  'The health function: records that the daily health check ran, and settles an open health_check_missing alert.';
revoke all on function public.record_health_check() from public, anon, authenticated, service_role, backup_reader;
grant execute on function public.record_health_check() to service_role;

-- 2. A health check that stops ------------------------------------------------------------------------

-- Once a health check has ever been recorded, none for 36 hours raises one
-- health_check_missing alert (one open at a time). The next health check settles it.
create function public.check_health_age()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last timestamptz := (select max(jr.finished_at) from public.job_runs jr
                          where jr.job = 'health' and jr.status = 'ok');
  v_late boolean;
  v_raised boolean := false;
begin
  v_late := v_last is not null and public.app_now() - v_last > interval '36 hours';
  if v_late and not exists (select 1 from public.alerts al where al.kind = 'health_check_missing' and al.resolved_at is null) then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('health_check_missing', false,
            'The daily health check hasn''t run since ' || public.fmt_date(public.edmonton_local(v_last)::date)
              || '. Check the Health check workflow in the big-bucks-backups repo on GitHub (RUNBOOK, "The health check didn''t run").',
            jsonb_build_object('last_health_check_at', v_last));
    v_raised := true;
  end if;
  return jsonb_build_object('last_health_check_at', v_last, 'late', v_late, 'alert_raised', v_raised);
end;
$$;
comment on function public.check_health_age() is
  'The nightly timer: a health_check_missing alert when no health check has run for 36 hours (once one ever has).';
revoke all on function public.check_health_age() from public, anon, authenticated, service_role, backup_reader;

-- Both outside jobs, for the timer.
create function public.check_outside_jobs()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object('backup', public.check_backup_age(), 'health', public.check_health_age());
$$;
comment on function public.check_outside_jobs() is
  'The nightly timer: are GitHub''s daily backup and health check still running? Raises their alerts after 36 hours.';
revoke all on function public.check_outside_jobs() from public, anon, authenticated, service_role, backup_reader;

-- 3. The timer checks every evening ---------------------------------------------------------------------

-- As in 20261021000000_stage4_nightly.sql, with one line added: check_outside_jobs()
-- from 4:30 pm, before the "done" check, so it runs every evening.
create or replace function public.nightly_kick()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_local timestamp := public.edmonton_local(public.app_now());
  v_today date := public.app_today();
begin
  -- Not set up (your own computer, or production before RUNBOOK's Vault step).
  if private.vault_value('nightly_function_url') is null or private.vault_value('nightly_function_key') is null then
    return 'not set up: the nightly function''s address and key aren''t in Vault';
  end if;
  if v_local::time < time '16:30' then
    return 'too early: the run starts at 4:30 pm Alberta time';
  end if;
  -- GitHub's daily backup and health check: still running? (Alerts after 36 hours.)
  perform public.check_outside_jobs();
  if v_local::time >= time '21:00' then
    perform public.raise_missing_price_alerts(v_today);
  end if;
  if (public.nightly_status(v_today) ->> 'done')::boolean then
    return 'done: tonight''s work is finished';
  end if;
  -- One call at a time: the last one may still be working.
  if exists (select 1 from public.outbox o
              where o.kind = 'http' and o.payload ->> 'target' = 'nightly'
                and o.created_at > public.app_now() - interval '25 minutes') then
    return 'waiting: a call went out less than 25 minutes ago';
  end if;
  perform public.queue_outside('http', jsonb_build_object('target', 'nightly', 'for_date', v_today));
  return 'queued';
end;
$$;
comment on function public.nightly_kick() is
  'Run by pg_cron. From 4:30 pm Alberta time: checks GitHub''s backup and health check are still running, then queues one call to the nightly function until tonight''s work is done. Does nothing without its Vault entries.';
