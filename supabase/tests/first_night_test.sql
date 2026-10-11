-- The first night, through the timer (Dad, 2026-10-10). On the evening the first
-- account opens, "yesterday's" savings interest can't exist (no account was open),
-- so the nightly run must not wait for it: the timer finishes after one call instead
-- of calling every 30 minutes until 10:30 pm, as it did on production's first night.
-- With no account at all (a brand-new project), the same. A real day's missing
-- interest is still waited for. And launch night (Dad's case): after
-- prelaunch_reset() and the girls' new accounts, the first night is one call too.
--
-- This drives the real timer path: nightly_kick() at 4:30 and 5:00 pm, with the jobs
-- and the check run in between as the nightly function runs them (run_daily,
-- reconcile_through). The time machine runs the jobs directly, so it never did.
--
-- It needs a database with no accounts (as CI has, or after `supabase db reset`); on
-- one holding the local demo, it says so and skips. Either way it says which in a
-- NOTICE, which shows in CI's log.
--
-- May 2027: Saturday May 8 (no market trades) is the first account's day; launch day
-- is Saturday May 15.
begin;
select plan(21);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.queued() returns integer language sql as $$
  select count(*)::int from public.outbox where kind = 'http' and payload ->> 'target' = 'nightly';
$$;
-- What the nightly function does after a call: the jobs through the day, then the check.
create function tests.nightly_work(p_day date) returns void language plpgsql as $$
begin
  perform public.run_daily(p_day);
  perform public.reconcile_through(p_day);
end;
$$;
-- A whole ordinary evening: each trading fund's final close, then the work.
create function tests.full_night(p_day date) returns void language plpgsql as $$
begin
  perform tests.clock(p_day || ' 16:30');
  insert into public.fund_prices (fund_id, price_date, close, fetched_at)
  select f.id, p_day, 100, public.close_time(f.market, p_day) + interval '30 minutes'
    from public.funds f
   where public.is_trading_day(f.market, p_day)
     and not exists (select 1 from public.fund_prices p where p.fund_id = f.id and p.price_date = p_day);
  perform tests.nightly_work(p_day);
end;
$$;
create function tests.waiting(p_day date) returns jsonb language sql as $$
  select public.nightly_status(p_day) -> 'jobs_waiting';
$$;
-- Rows in each table the reset clears, as the daily backup records them.
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

create function tests.first_night() returns setof text language plpgsql as $$
declare
  v_reset text;
begin
  if exists (select 1 from public.accounts) then
    raise notice 'first_night_test: SKIPPED all 21 checks: the database already has accounts (run supabase db reset).';
    return query select skip('needs a database with no accounts yet (run supabase db reset): the local demo is loaded', 21);
    return;
  end if;

  perform vault.create_secret('http://supabase_kong_big-bucks:8000/functions/v1/nightly', 'nightly_function_url');
  perform vault.create_secret('local-nightly-key-for-this-computer-only', 'nightly_function_key');

  -- A brand-new project: no account at all. Nothing is owed, so no interest is waited for.
  perform tests.clock('2027-05-07 17:00');
  return next is(tests.waiting(date '2027-05-07') @> '["interest"]', false,
    'with no account at all, the evening doesn''t wait for interest');

  -- The first account opens on Saturday morning.
  perform tests.clock('2027-05-08 09:00');
  insert into public.accounts (name, is_test) values ('Test first night', true);
  return next is(public.first_account_day(), date '2027-05-08', 'the first account opens on Sat May 8');

  -- Its first evening. One call at 4:30 pm, the work, then the 5:00 pm kick finds it done.
  perform tests.clock('2027-05-08 16:30');
  return next is(public.nightly_kick(), 'queued', 'first night, 4:30 pm: one call');
  perform tests.nightly_work(date '2027-05-08');
  return next is(tests.waiting(date '2027-05-08') @> '["interest"]', false,
    '...and yesterday''s (May 7) interest isn''t waited for: no account was open');
  return next is(public.nightly_status(date '2027-05-08') ->> 'done', 'true', '...so the evening is done');
  perform tests.clock('2027-05-08 17:00');
  return next is(public.nightly_kick(), 'done: tonight''s work is finished', 'at 5:00 pm the kick does nothing');
  perform tests.clock('2027-05-08 22:30');
  return next is(public.nightly_kick(), 'done: tonight''s work is finished', '...nor at 10:30 pm');
  return next is(tests.queued(), 1, 'one call on the first night, not one every 30 minutes');
  return next is((select status::text from public.job_runs where job = 'interest' and run_for_date = '2027-05-08'
                   order by id desc limit 1), 'retrying',
    'May 8''s own interest waits for the day to end, as every day''s does');

  -- The second evening. Until its work runs, May 8's interest (a real day) is waited for.
  perform tests.clock('2027-05-09 16:30');
  return next is(public.nightly_kick(), 'queued', 'second night, 4:30 pm: one call');
  return next is(tests.waiting(date '2027-05-09') @> '["interest"]', true,
    '...and a real day''s missing interest (May 8) is still waited for');
  perform tests.nightly_work(date '2027-05-09');
  return next is((select status::text from public.job_runs where job = 'interest' and run_for_date = '2027-05-08'
                   order by id desc limit 1), 'ok', 'May 8''s interest is worked out on the 9th');
  perform tests.clock('2027-05-09 17:00');
  return next is(public.nightly_kick(), 'done: tonight''s work is finished', 'at 5:00 pm the second night is done too');
  return next is(tests.queued(), 2, 'one call each night');

  -- Launch night. The beta runs a week (Mon-Fri with closes), then on Saturday morning
  -- the test history is cleared after a fresh backup, and the girls' accounts open.
  perform tests.full_night(d::date) from generate_series(date '2027-05-10', date '2027-05-14', interval '1 day') d;
  perform tests.clock('2027-05-15 09:00');
  perform public.record_backup(jsonb_build_object('taken_at', public.app_now(), 'counts', tests.counts()));
  v_reset := public.prelaunch_reset('clear the test history');
  return next ok(v_reset like 'Test history cleared:%', 'Sat May 15: the pre-launch reset clears the test history');
  perform tests.clock('2027-05-15 10:00');
  insert into public.accounts (name, is_test) values ('Launch kid A', false), ('Launch kid B', false);
  return next is(public.first_account_day(), date '2027-05-08',
    'the first account day is still the test kid''s (accounts and job history are kept), not launch day');
  return next is(tests.queued(), 0, 'the reset cleared the outbox');

  perform tests.clock('2027-05-15 16:30');
  return next is(public.nightly_kick(), 'queued', 'launch night, 4:30 pm: one call');
  perform tests.nightly_work(date '2027-05-15');
  return next is(public.nightly_status(date '2027-05-15') ->> 'done', 'true',
    '...the work runs (yesterday''s interest, May 14, was a real day and is worked out) and the evening is done');
  perform tests.clock('2027-05-15 17:00');
  return next is(public.nightly_kick(), 'done: tonight''s work is finished', 'at 5:00 pm the kick does nothing');
  return next is(tests.queued(), 1, 'one call on launch night');

  raise notice 'first_night_test: ran all 21 checks on a database with no accounts beforehand.';
end;
$$;

select * from tests.first_night();

select * from finish();
rollback;
