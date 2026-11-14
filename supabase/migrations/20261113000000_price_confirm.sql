-- The price fix, part 1: confirmed closes (Dad, 2026-11-05, with his additions through 11-09;
-- docs/plans/price-fix-plan.md, sections 1, 2b and the safety net).
--
-- Found Nov 5: at the 4:30 pm fetch the provider's bar for that day can still hold a price from a
-- few minutes before the close, and our rule counted any close fetched after the close time as
-- final. From the cut-over:
--   1. A day's close is ready only from 9:00 pm Alberta time that day (confirm_time). The nightly
--      function isn't asked for it before then (missing_closes), store_close refuses it before
--      then, and final_close never counts a close fetched before then, however it got there.
--      Closes stored before the cut-over keep their old rule (close_ready_at).
--   2. The missing-close alert moves from 9:00 pm to 10:00 pm, after the 9:00 and 9:30 pm tries.
--      Between the 4:30 pm run and 9:00 pm the timer doesn't call the function just to wait for
--      today's closes; it still calls if any other work is outstanding or failed.
--   3. Catch-up in bounded steps: run_daily and reconcile_through take a most-days limit and say
--      whether there's more, so a long gap never runs past the 8-second statement limit (found
--      Nov 6). The one-argument versions are unchanged (time machine, demo, tests).
--   4. The provider's values are kept (price_observations) and compared with the stored closes
--      (check_price_mismatches, alert price_mismatch). Off until Dad turns it on, after the known
--      wrong closes are fixed on production day.

alter type public.alert_kind add value if not exists 'price_mismatch';

-- 1. The rule ----------------------------------------------------------------------------------------

-- The cut-over: the day this migration runs (production: the day of the production session).
-- Effective from 2026-01-01 so it applies to every day the app touches; a later row wins.
insert into public.settings (key, value, effective_date, note)
values ('closes_confirmed_from', public.app_today()::text, date '2026-01-01',
        'From this day, a close is final only if fetched at or after 9:00 pm Alberta time (the price fix).'),
       ('price_mismatch_check', 'off', date '2026-01-01',
        'Compare the provider''s values with the stored closes and alert Dad when they differ. Turned on after the known wrong closes are fixed.');

create function public.closes_confirmed_from()
returns date
language sql stable
set search_path = ''
as $$
  select public.setting_on('closes_confirmed_from', date 'infinity')::date;
$$;
comment on function public.closes_confirmed_from() is
  'The price fix''s cut-over: from this day a close is final only if fetched at or after 9:00 pm Alberta time.';

-- 9:00 pm Alberta time on the day: by then the provider's bar holds the real close.
create function public.confirm_time(p_market public.market, p_date date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select public.edmonton_at(p_date + time '21:00');
$$;
comment on function public.confirm_time(public.market, date) is
  'When a day''s close is confirmed: 9:00 pm Alberta time that day (the price fix, Nov 2026). The same for both markets.';

-- From when a day's close may be fetched, stored and used.
create function public.close_ready_at(p_market public.market, p_date date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select case when p_date >= coalesce(public.closes_confirmed_from(), date 'infinity')
              then public.confirm_time(p_market, p_date)
              else public.close_time(p_market, p_date) end;
$$;
comment on function public.close_ready_at(public.market, date) is
  'When a day''s close is ready: confirm_time from the cut-over, the market close before it (history keeps its rule).';

create or replace function public.final_close(p_fund_id text, p_date date)
returns numeric
language sql stable
set search_path = ''
as $$
  select fp.close
    from public.fund_prices fp join public.funds f on f.id = fp.fund_id
   where fp.fund_id = p_fund_id and fp.price_date = p_date and fp.source = 'daily'
     and fp.fetched_at >= public.close_ready_at(f.market, p_date);
$$;
comment on function public.final_close(text, date) is
  'A fund''s daily close for a day, only once it is final (fetched at or after close_ready_at: 9:00 pm Alberta time from the price fix). Null otherwise, and always null for a weekly backfill close.';

-- store_close: from 20261021000000_stage4_nightly.sql (1 change: a daily close waits for its ready time).
create or replace function public.store_close(p_fund_id text, p_date date, p_close numeric, p_source text default 'daily')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_prices;
  v_prev public.fund_prices;
  v_first date := public.first_account_day();
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_date is null then
    raise exception 'A close needs its day.';
  end if;
  if p_close is null or p_close <= 0 or p_close <> round(p_close, 8) then
    raise exception 'A close is a price above $0, with at most 8 decimal places.';
  end if;
  if p_source is null or p_source not in ('daily', 'weekly_backfill') then
    raise exception 'A close comes from the daily series or the weekly backfill.';
  end if;
  if not public.is_trading_day(v_fund.market, p_date) then
    raise exception 'The % market doesn''t trade on %, so there''s no close to store.', v_fund.market, p_date;
  end if;
  if public.app_now() < public.close_time(v_fund.market, p_date) then
    raise exception 'The % market hasn''t closed yet on %, so that price isn''t a close.', v_fund.market, p_date;
  end if;
  -- The price fix: until 9:00 pm the provider's bar may still hold a price from before the close.
  if p_source = 'daily' and public.app_now() < public.close_ready_at(v_fund.market, p_date) then
    raise exception 'The % close for % is confirmed at 9:00 pm Alberta time, so that price isn''t final yet.',
      v_fund.name, public.fmt_date(p_date);
  end if;
  if p_source = 'weekly_backfill' and v_first is not null and p_date >= v_first then
    raise exception 'A weekly backfill close is only for days before the first account opened (%).', v_first;
  end if;

  -- Takes turns with settlement and price fixes on the same fund and day.
  perform pg_advisory_xact_lock(hashtext('close:' || p_fund_id || ':' || p_date));

  select * into v_old from public.fund_prices fp where fp.fund_id = p_fund_id and fp.price_date = p_date;
  if found then
    -- Never overwritten: a wrong close is fixed by Dad (correct_fund_price).
    return case when v_old.close = p_close then 'already' else 'differs' end;
  end if;

  -- A big move with no split recorded between the two closes: worth a look.
  select * into v_prev from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date < p_date
   order by fp.price_date desc limit 1;
  if found and abs(p_close - v_prev.close) > 0.25 * v_prev.close
     and not exists (select 1 from public.fund_splits s
                      where s.fund_id = p_fund_id and s.split_date > v_prev.price_date and s.split_date <= p_date) then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('price_jump', true,
            'The ' || v_fund.name || ' close for ' || public.fmt_date(p_date) || ' ('
              || public.fmt_money4(p_close * 100) || ') moved more than 25% from the one before ('
              || public.fmt_money4(v_prev.close * 100) || ', ' || public.fmt_date(v_prev.price_date)
              || ') and no split is recorded. Check it against the exchange; if it''s wrong, fix it.',
            jsonb_build_object('fund_id', p_fund_id, 'date', p_date, 'close', p_close,
                               'previous_date', v_prev.price_date, 'previous_close', v_prev.close));
  end if;

  insert into public.fund_prices (fund_id, price_date, close, source) values (p_fund_id, p_date, p_close, p_source);

  -- Its "missing close" alert, if there was one, is settled.
  update public.alerts al set resolved_at = public.app_now()
   where al.kind = 'missing_price' and al.resolved_at is null
     and al.details ->> 'fund_id' = p_fund_id and al.details ->> 'date' = p_date::text;
  return 'stored';
end;
$$;
comment on function public.store_close(text, date, numeric, text) is
  'The server''s only way to save a close. Refuses a close before it is ready (9:00 pm Alberta time from the price fix), a non-trading day, and a weekly close once accounts exist. Never overwrites.';

-- missing_closes: from 20261021000000_stage4_nightly.sql (1 change: only days whose close is ready).
create or replace function public.missing_closes(p_through date)
returns table (fund_id text, symbol text, market public.market, price_date date)
language sql stable
set search_path = ''
as $$
  select f.id, f.proxy_symbol, f.market, d::date
    from public.funds f
   cross join lateral generate_series(
           greatest(coalesce(public.first_account_day(),
                             (select max(fp.price_date) + 1 from public.fund_prices fp where fp.fund_id = f.id),
                             p_through),
                    p_through - 140),
           p_through, interval '1 day') d
   where public.is_trading_day(f.market, d::date)
     and public.close_ready_at(f.market, d::date) <= public.app_now()
     and not exists (select 1 from public.fund_prices fp where fp.fund_id = f.id and fp.price_date = d::date)
   order by f.sort_order, d;
$$;

-- 2. The evening timer ----------------------------------------------------------------------------------

-- Only today's closes (not ready until 9:00 pm) and the fund work waiting for them are left:
-- the 4:30 pm run did everything else.
create function public.nightly_waiting_for_confirm()
returns boolean
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_status jsonb := public.nightly_status(v_today);
begin
  if public.app_now() >= public.confirm_time('nyse', v_today) then
    return false;
  end if;
  -- An earlier day's close is still missing, or a job failed: call.
  if exists (select 1 from public.missing_closes(v_today)) then
    return false;
  end if;
  if exists (select 1 from public.job_runs jr
              where jr.status = 'failed'
                and not exists (select 1 from public.job_runs ok
                                 where ok.job = jr.job and ok.run_for_date = jr.run_for_date and ok.status = 'ok')) then
    return false;
  end if;
  -- Every job still waiting for today is fund work, which needs today's close.
  if exists (select 1 from jsonb_array_elements_text(v_status -> 'jobs_waiting') j
              where j not in ('splits', 'settle', 'dividends', 'notes')) then
    return false;
  end if;
  -- Yesterday has been checked (today's check waits for tonight's work).
  return coalesce((select max(jr.run_for_date) from public.job_runs jr where jr.job = 'reconcile'), date '-infinity')
         >= v_today - 1;
end;
$$;
comment on function public.nightly_waiting_for_confirm() is
  'True between the 4:30 pm run and 9:00 pm when only today''s closes (confirmed at 9:00 pm) and the fund work waiting for them are left.';

-- nightly_kick: from 20261025000000_outside_jobs.sql (2 changes: the missing-close alert from
-- 10:00 pm, not 9:00 pm; before 9:00 pm, no call just to wait for today's closes).
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
  -- After the 9:00 and 9:30 pm tries (the price fix).
  if v_local::time >= time '22:00' then
    perform public.raise_missing_price_alerts(v_today);
  end if;
  if (public.nightly_status(v_today) ->> 'done')::boolean then
    return 'done: tonight''s work is finished';
  end if;
  if public.nightly_waiting_for_confirm() then
    return 'waiting: today''s closes are confirmed at 9:00 pm';
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
  'Run by pg_cron. From 4:30 pm Alberta time: checks GitHub''s backup and health check are still running, then queues one call to the nightly function until tonight''s work is done, skipping the wait for today''s closes before 9:00 pm. Missing-close alerts from 10:00 pm. Does nothing without its Vault entries.';

comment on function public.raise_missing_price_alerts(date) is
  'From 10:00 pm Alberta time (the price fix): one "missing close" alert per fund and day still missing.';

-- 3. Catch-up in bounded steps ---------------------------------------------------------------------------

-- At most p_max_days days of new core work per call, then "more" says whether to call again.
-- The window counts from the first day whose core work isn't done, so a fund waiting for a close
-- never holds it in place.
create function public.run_daily(p_through date, p_max_days integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_core public.job_name[] := array['expire', 'gic_maturity', 'auto_move', 'monthly', 'rate_notices', 'interest']::public.job_name[];
  v_start date;
  v_to date;
  v_r jsonb;
begin
  if p_max_days is null or p_max_days < 1 then
    raise exception 'A bounded run needs at least 1 day.';
  end if;
  select least(
           (select min(jr.run_for_date) from public.job_runs jr
             where jr.job = any (v_core) and jr.status <> 'ok'
               and not exists (select 1 from public.job_runs ok
                                where ok.job = jr.job and ok.run_for_date = jr.run_for_date and ok.status = 'ok')),
           (select max(jr.run_for_date) + 1 from public.job_runs jr where jr.job = any (v_core) and jr.status = 'ok'))
    into v_start;
  v_start := coalesce(v_start, (select min(public.edmonton_local(a.created_at)::date) from public.accounts a), p_through);
  v_to := least(p_through, greatest(v_start, v_start + p_max_days - 1));
  v_r := public.run_daily(v_to);
  return v_r || jsonb_build_object(
    'through', v_to,
    'more', v_to < p_through and (v_r ->> 'core_completed_through')::date is not distinct from v_to);
end;
$$;
comment on function public.run_daily(date, integer) is
  'run_daily in bounded steps (the price fix, 2b): at most p_max_days days of new core work per call; "more" is true when the caller should call again.';

-- At most p_max_days days per call. Tonight's day is checked once tonight's work is done (or from
-- 9:00 pm, whatever is left), not at the 4:30 pm run before its trades settle.
create function public.reconcile_through(p_through date, p_max_days integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
  v_day date;
  v_r jsonb;
  v_days jsonb := '[]'::jsonb;
  v_problems integer := 0;
  v_held boolean := false;
begin
  if p_max_days is null or p_max_days < 1 then
    raise exception 'A bounded check needs at least 1 day.';
  end if;
  select max(jr.run_for_date) + 1 into v_from from public.job_runs jr where jr.job = 'reconcile';
  v_from := coalesce(v_from, p_through);
  v_to := least(p_through, v_from + p_max_days - 1);
  if v_to = public.app_today() and public.app_now() < public.confirm_time('nyse', v_to)
     and not (public.nightly_status(v_to) ->> 'jobs_waiting' = '[]'
              and public.nightly_status(v_to) ->> 'closes_missing' = '[]') then
    v_to := v_to - 1;
    v_held := true;
  end if;
  v_day := v_from;
  while v_day <= v_to loop
    v_r := public.reconcile(v_day);
    v_days := v_days || to_jsonb(v_day);
    if v_r ->> 'status' <> 'ok' then
      v_problems := v_problems + 1;
    end if;
    v_day := v_day + 1;
  end loop;
  return jsonb_build_object('reconciled', v_days, 'days_with_problems', v_problems,
                            'held_for_tonight', v_held, 'more', v_to < p_through and not v_held);
end;
$$;
comment on function public.reconcile_through(date, integer) is
  'reconcile_through in bounded steps (the price fix, 2b): at most p_max_days days per call; "more" is true when the caller should call again.';

-- 4. The provider's values, and the mismatch check ------------------------------------------------------

create table public.price_observations (
  id          bigint generated always as identity primary key,
  fund_id     text not null references public.funds (id),
  price_date  date not null,
  close       numeric(20,8) not null check (close > 0),
  observed_at timestamptz not null default public.app_now()
);
comment on table public.price_observations is
  'What the price provider said for each recent day, each time the nightly function asked (the price fix). Append-only; compared with the stored closes by check_price_mismatches. Parent only.';
create index price_observations_day_idx on public.price_observations (fund_id, price_date, observed_at desc);
create trigger price_observations_no_update_delete before update or delete on public.price_observations
  for each row execute function public.reject_append_only_change();
create trigger price_observations_no_truncate before truncate on public.price_observations
  for each statement execute function public.reject_append_only_change();
alter table public.price_observations enable row level security;
create policy price_observations_read on public.price_observations for select to authenticated
  using ((select public.is_parent()));
revoke all on public.price_observations from public, anon, authenticated, service_role;
grant select on public.price_observations to authenticated, service_role;
revoke all on sequence public.price_observations_id_seq from public, anon, authenticated, service_role;

-- The nightly function hands over what the provider returned: [{date, close}, ...].
create function public.record_price_observations(p_fund_id text, p_values jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if not exists (select 1 from public.funds f where f.id = p_fund_id) then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'array' then
    raise exception 'The provider''s values come as a list of {date, close}.';
  end if;
  insert into public.price_observations (fund_id, price_date, close)
  select p_fund_id, (v ->> 'date')::date, (v ->> 'close')::numeric
    from jsonb_array_elements(p_values) v
   where (v ->> 'close')::numeric > 0;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function public.record_price_observations(text, jsonb) is
  'The nightly function''s record of what the provider returned for each recent day (the price fix).';

-- A stored final close the provider now disagrees with by 1¢ or more: one alert for Dad, with both
-- values. Never changes money. Only observations taken once the close was ready count, and only
-- while the setting price_mismatch_check is on.
create function public.check_price_mismatches()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
  v_n integer := 0;
begin
  if public.setting_on('price_mismatch_check', public.app_today()) is distinct from 'on' then
    return 0;
  end if;
  for v_m in
    select fp.fund_id, f.name, fp.price_date, fp.close as stored, o.close as observed
      from public.fund_prices fp
      join public.funds f on f.id = fp.fund_id
      join lateral (select po.close from public.price_observations po
                     where po.fund_id = fp.fund_id and po.price_date = fp.price_date
                       and po.observed_at >= public.close_ready_at(f.market, fp.price_date)
                     order by po.observed_at desc, po.id desc limit 1) o on true
     where fp.source = 'daily' and fp.fetched_at >= public.close_ready_at(f.market, fp.price_date)
       and abs(o.close - fp.close) >= 0.01
     order by f.sort_order, fp.price_date
  loop
    continue when exists (select 1 from public.alerts al
                           where al.kind = 'price_mismatch' and al.details ->> 'fund_id' = v_m.fund_id
                             and al.details ->> 'date' = v_m.price_date::text
                             and (al.details ->> 'stored')::numeric = v_m.stored);
    insert into public.alerts (kind, is_quiet, message, details)
    values ('price_mismatch', false,
            'The ' || v_m.name || ' close stored for ' || public.fmt_date(v_m.price_date) || ' is '
              || public.fmt_money4(v_m.stored * 100) || ', but the provider now says '
              || public.fmt_money4(v_m.observed * 100)
              || '. Check it against the official close; if it''s wrong, fix it with "Fix a close".',
            jsonb_build_object('fund_id', v_m.fund_id, 'date', v_m.price_date, 'stored', v_m.stored,
                               'observed', v_m.observed));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
comment on function public.check_price_mismatches() is
  'The price fix''s safety net: alerts Dad once per stored close the provider now disagrees with by 1¢ or more. Does nothing unless price_mismatch_check is on.';

-- Grants ---------------------------------------------------------------------------------------------------

revoke all on function public.closes_confirmed_from() from public, anon, authenticated, service_role;
revoke all on function public.confirm_time(public.market, date) from public, anon, authenticated, service_role;
revoke all on function public.close_ready_at(public.market, date) from public, anon, authenticated, service_role;
revoke all on function public.nightly_waiting_for_confirm() from public, anon, authenticated, service_role;
revoke all on function public.run_daily(date, integer) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_through(date, integer) from public, anon, authenticated, service_role;
revoke all on function public.record_price_observations(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.check_price_mismatches() from public, anon, authenticated, service_role;

grant execute on function public.closes_confirmed_from() to authenticated, service_role;
grant execute on function public.confirm_time(public.market, date) to authenticated, service_role;
grant execute on function public.close_ready_at(public.market, date) to authenticated, service_role;
grant execute on function public.run_daily(date, integer) to service_role;
grant execute on function public.reconcile_through(date, integer) to service_role;
grant execute on function public.record_price_observations(text, jsonb) to service_role;
grant execute on function public.check_price_mismatches() to service_role;
