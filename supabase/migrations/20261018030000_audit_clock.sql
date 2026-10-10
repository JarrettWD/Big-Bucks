-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). The time machine
-- can never switch on in production.
--
-- Before: app_now() honoured clock_override whenever the newest is_local_dev row
-- said 'true', and only the local seed wrote that row. Running the seed against
-- production (db push --include-seed) would have switched the time machine on
-- there. (supabase db reset --linked wipes production completely, this mark
-- included, so docs/RUNBOOK.md says never to run it; check_time_rules() would
-- then fail its production row.)
--
-- Now production marks itself, once and for good, right after the first
-- migration push (docs/RUNBOOK.md): select public.mark_production(); in the SQL
-- Editor. The settings table is append-only, so the mark can never be removed.
-- Once it's there:
--   * app_now() ignores clock_override whatever is_local_dev says;
--   * the local seed refuses to run (supabase/seed.sql checks for the mark);
--   * check_time_rules() has a row that passes only on a marked production
--     database with is_local_dev not 'true' (locally that row shows ok = false,
--     which is expected: this computer is not production).
-- The time machine, the demo and jobs:local also refuse a marked database.

create or replace function public.app_now()
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_local_dev text;
  v_override  text;
begin
  -- Production: always the real clock.
  if exists (select 1 from public.settings s where s.key = 'is_production') then
    return now();
  end if;

  select s.value into v_local_dev
    from public.settings s
   where s.key = 'is_local_dev'
   order by s.id desc
   limit 1;

  if v_local_dev is distinct from 'true' then
    return now();
  end if;

  select btrim(s.value) into v_override
    from public.settings s
   where s.key = 'clock_override'
   order by s.id desc
   limit 1;

  if v_override is null or v_override = '' then
    return now();
  end if;

  if v_override !~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' then
    raise exception 'clock_override "%" is not a valid Edmonton date and time. Use YYYY-MM-DD HH:MI, or an empty value to clear it.',
      v_override;
  end if;

  return public.edmonton_at(v_override::timestamp);
end;
$$;

-- Marks this database as production, for good. The database owner runs it once
-- from the SQL Editor right after the first migration push. Safe to run again.
create function public.mark_production()
returns text
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.settings s where s.key = 'is_production') then
    return 'Already marked as production.';
  end if;
  insert into public.settings (key, value, effective_date, note)
  values ('is_production', 'true', current_date,
          'Production: the time machine is off for good, and the local seed can''t run here.');
  if (select s.value from public.settings s where s.key = 'is_local_dev' order by s.id desc limit 1)
     is distinct from 'false' then
    insert into public.settings (key, value, effective_date, note)
    values ('is_local_dev', 'false', current_date, 'Production.');
  end if;
  return 'Marked as production: the time machine is off for good.';
end;
$$;
comment on function public.mark_production() is
  'Run once on production (SQL Editor): app_now() then ignores clock_override for good, and the local seed refuses to run.';

-- check_time_rules(): one more row, the production mark.
create or replace function public.check_time_rules()
returns table (check_name text, expected text, actual text, ok boolean)
language plpgsql stable
set search_path = ''
as $$
declare
  v_fmt constant text := 'YYYY-MM-DD HH24:MI';
  v_server_offset text;
  v_marked boolean := exists (select 1 from public.settings s where s.key = 'is_production');
  v_local_dev text := (select s.value from public.settings s where s.key = 'is_local_dev' order by s.id desc limit 1);
begin
  -- 1. The pinned Alberta rule: noon UTC−6 on both sides of Nov 1, 2026.
  return query
    select x.n, x.e, to_char(public.edmonton_local(x.m), v_fmt), to_char(public.edmonton_local(x.m), v_fmt) = x.e
      from (values
        ('Alberta, 18:00 UTC on Sat Oct 31, 2026', timestamptz '2026-10-31 18:00:00+00', '2026-10-31 12:00'),
        ('Alberta, 18:00 UTC on Mon Nov 2, 2026 (no clock change)', timestamptz '2026-11-02 18:00:00+00', '2026-11-02 12:00'),
        ('Alberta, 18:00 UTC on Fri Jan 15, 2027', timestamptz '2027-01-15 18:00:00+00', '2027-01-15 12:00'),
        ('Alberta, 05:30 UTC on Jan 1, 2027 is still Dec 31', timestamptz '2027-01-01 05:30:00+00', '2026-12-31 23:30'),
        ('Alberta, 18:00 UTC on Thu Jul 1, 2027', timestamptz '2027-07-01 18:00:00+00', '2027-07-01 12:00')
      ) as x(n, m, e);

  return query
    select 'Alberta midnight starting Dec 1, 2026, in UTC'::text, '2026-12-01 06:00'::text,
           to_char(public.edmonton_start(date '2026-12-01') at time zone 'UTC', v_fmt),
           to_char(public.edmonton_start(date '2026-12-01') at time zone 'UTC', v_fmt) = '2026-12-01 06:00';

  -- 2. The server's Toronto data: 4:00 pm Toronto in UTC either side of each clock change.
  return query
    select x.n, x.e, to_char((x.l at time zone 'America/Toronto') at time zone 'UTC', v_fmt),
           to_char((x.l at time zone 'America/Toronto') at time zone 'UTC', v_fmt) = x.e
      from (values
        ('Toronto 4:00 pm Fri Oct 30, 2026 in UTC (summer time)', timestamp '2026-10-30 16:00', '2026-10-30 20:00'),
        ('Toronto 4:00 pm Mon Nov 2, 2026 in UTC (standard time)', timestamp '2026-11-02 16:00', '2026-11-02 21:00'),
        ('Toronto 4:00 pm Fri Mar 12, 2027 in UTC (standard time)', timestamp '2027-03-12 16:00', '2027-03-12 21:00'),
        ('Toronto 4:00 pm Mon Mar 15, 2027 in UTC (summer time)', timestamp '2027-03-15 16:00', '2027-03-15 20:00'),
        ('Toronto 4:00 pm Fri Nov 5, 2027 in UTC (summer time)', timestamp '2027-11-05 16:00', '2027-11-05 20:00'),
        ('Toronto 4:00 pm Mon Nov 8, 2027 in UTC (standard time)', timestamp '2027-11-08 16:00', '2027-11-08 21:00')
      ) as x(n, l, e);

  -- 3. Market closes in Alberta time, from close_time().
  return query
    select x.n, x.e, to_char(public.edmonton_local(public.close_time(x.mk::public.market, x.d)), v_fmt),
           to_char(public.edmonton_local(public.close_time(x.mk::public.market, x.d)), v_fmt) = x.e
      from (values
        ('NYSE close Fri Oct 30, 2026, Alberta time', 'nyse', date '2026-10-30', '2026-10-30 14:00'),
        ('NYSE close Mon Nov 2, 2026, Alberta time', 'nyse', date '2026-11-02', '2026-11-02 15:00'),
        ('NYSE early close Fri Nov 27, 2026, Alberta time', 'nyse', date '2026-11-27', '2026-11-27 12:00'),
        ('TSX early close Thu Dec 24, 2026, Alberta time', 'tsx', date '2026-12-24', '2026-12-24 12:00'),
        ('TSX close Fri Mar 12, 2027, Alberta time', 'tsx', date '2027-03-12', '2027-03-12 15:00'),
        ('TSX close Mon Mar 15, 2027, Alberta time', 'tsx', date '2027-03-15', '2027-03-15 14:00')
      ) as x(n, mk, d, e);

  -- 4. The app clock follows the real clock (no time-machine override).
  return query
    select 'app_now() is the real time (no clock override)'::text, 'yes'::text,
           case when public.app_now() = now() then 'yes' else 'no: ' || public.app_now()::text end,
           public.app_now() = now();
  return query
    select 'app_today() is the Alberta date right now'::text, public.edmonton_local(now())::date::text,
           public.app_today()::text, public.app_today() = public.edmonton_local(now())::date;

  -- 5. This is production, marked for good: the time machine can never switch on.
  return query
    select 'Marked as production (select public.mark_production();), time machine off for good'::text, 'yes'::text,
           case when v_marked and v_local_dev is distinct from 'true' then 'yes'
                when v_marked then 'no: is_local_dev is still true'
                else 'no: not marked yet (expected on your own computer, never on production)' end,
           v_marked and v_local_dev is distinct from 'true';

  -- 6. Information only: does the server's own time-zone data know the new rule?
  --    The app doesn't rely on it, so either answer is fine.
  v_server_offset := to_char((timestamptz '2026-12-01 18:00:00+00' at time zone 'America/Edmonton'), 'HH24:MI');
  return query
    select 'Information only: server''s own Alberta data, 18:00 UTC on Dec 1, 2026'::text, '12:00'::text,
           v_server_offset || case when v_server_offset = '12:00' then ' (up to date)'
                                   else ' (old data; harmless, the app uses its pinned rule)' end,
           null::boolean;
end;
$$;

revoke all on function public.mark_production() from public, anon, authenticated, service_role;
revoke all on function public.check_time_rules() from public, anon, authenticated, service_role;
