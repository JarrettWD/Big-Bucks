-- The price fix, part 1: confirmed closes (Dad, 2026-11-05; docs/plans/price-fix-plan.md).
-- From the cut-over, a day's close is final only if fetched at or after 9:00 pm Alberta time
-- that day: before then the provider's bar can still hold a price from a few minutes before
-- the close (Nov 5, 2026). Also: the missing-close alert at 10:00 pm, the timer waiting for
-- 9:00 pm, catch-up in bounded steps, and the provider-values check (off until Dad turns it on).
-- Known answers in March 2027 (Alberta UTC−6; markets close 3:00 pm Alberta until Mar 14).
-- Works on a fresh database (CI) and on one holding the local demo.
begin;
select plan(41);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
create function tests.alerts(p_kind text, p_fund text, p_date date) returns integer language sql as $$
  select count(*)::int from public.alerts
   where kind::text = p_kind and details ->> 'fund_id' = p_fund and details ->> 'date' = p_date::text;
$$;
create function tests.queued() returns integer language sql as $$
  select count(*)::int from public.outbox where kind = 'http' and payload ->> 'target' = 'nightly';
$$;

-- The cut-over for these tests: Mar 1, 2027 (the migration sets it to the day it runs).
insert into public.settings (key, value, effective_date) values ('closes_confirmed_from', '2027-03-01', date '2026-01-01');
select tests.clock('2027-02-01 09:00');
insert into public.accounts (name, is_test) values ('Test price confirm', true);

-- 1. The rule -------------------------------------------------------------------------------------

select is(public.closes_confirmed_from(), date '2027-03-01', 'the cut-over is the setting');
select is(public.confirm_time('nyse', date '2027-03-08'), '2027-03-09 03:00:00+00'::timestamptz,
  'a close is confirmed at 9:00 pm Alberta time (03:00 UTC the next day)');
select is(public.confirm_time('tsx', date '2027-03-08'), '2027-03-09 03:00:00+00'::timestamptz, '...for the TSX too');
select is(public.close_ready_at('nyse', date '2027-03-08'), public.confirm_time('nyse', date '2027-03-08'),
  'from the cut-over, a close is ready at 9:00 pm');
select is(public.close_ready_at('nyse', date '2027-02-26'), public.close_time('nyse', date '2027-02-26'),
  'before the cut-over, at the market close as before (closes already stored keep their rule)');

-- 2. store_close waits for 9:00 pm ---------------------------------------------------------------

select tests.clock('2027-03-08 20:59');
select is(tests.err($$select public.store_close('dow', date '2027-03-08', 400)$$),
  'The Dow Jones close for Mar 8 is confirmed at 9:00 pm Alberta time, so that price isn''t final yet.',
  'at 8:59 pm a close for today is refused, even 6 hours after the market closed');
select is((select count(*)::int from public.fund_prices where fund_id = 'dow' and price_date = '2027-03-08'), 0,
  '...nothing stored');
select tests.clock('2027-03-08 21:00');
select is(public.store_close('dow', date '2027-03-08', 400), 'stored', 'at 9:00 pm it is stored');
select is(public.final_close('dow', date '2027-03-08'), 400::numeric, '...and it is final');

-- 3. final_close never counts an earlier fetch, however it got there -------------------------------

select tests.clock('2027-03-09 16:30');
insert into public.fund_prices (fund_id, price_date, close) values ('nasdaq100', '2027-03-09', 648.58);
select is(public.final_close('nasdaq100', date '2027-03-09'), null::numeric,
  'a close fetched at 4:30 pm (a pre-close snapshot, as on Nov 5, 2026) is never final');
select tests.clock('2027-02-26 15:30');
insert into public.fund_prices (fund_id, price_date, close)
select 'nasdaq100', '2027-02-26', 600 where not exists
  (select 1 from public.fund_prices where fund_id = 'nasdaq100' and price_date = '2027-02-26');
select isnt(public.final_close('nasdaq100', date '2027-02-26'), null::numeric,
  'before the cut-over, a close fetched after the market close stays final (history is unchanged)');

-- 4. missing_closes asks for today's close only from 9:00 pm -----------------------------------------

select tests.clock('2027-03-10 16:30');
select is((select count(*)::int from public.missing_closes(date '2027-03-10') where price_date = '2027-03-10'), 0,
  'at 4:30 pm the nightly doesn''t ask for today''s closes');
select tests.clock('2027-03-10 21:00');
select is((select count(*)::int from public.missing_closes(date '2027-03-10') where price_date = '2027-03-10'), 3,
  'at 9:00 pm it asks for all three');

-- 5. The timer: waits for 9:00 pm, then the missing-close alert at 10:00 pm ------------------------

select vault.create_secret('http://supabase_kong_big-bucks:8000/functions/v1/nightly', 'nightly_function_url');
select vault.create_secret('local-nightly-key-for-this-computer-only', 'nightly_function_key');

-- Mar 11: every core job done at the 4:30 pm run; only today's closes (and the fund jobs) wait.
select tests.clock('2027-03-11 16:30');
insert into public.job_runs (job, run_for_date, status, finished_at)
select j::public.job_name, case when j = 'interest' then date '2027-03-10' else date '2027-03-11' end, 'ok', public.app_now()
  from unnest(array['expire', 'gic_maturity', 'auto_move', 'monthly', 'rate_notices', 'interest', 'reconcile']) j;
-- Every earlier day's closes are in (so only today's are missing).
insert into public.fund_prices (fund_id, price_date, close)
select m.fund_id, m.price_date, 100 from public.missing_closes(date '2027-03-10') m;
select tests.clock('2027-03-11 17:00');
-- GitHub's backup failing isn't the nightly function's to fix: it has its own alert.
insert into public.job_runs (job, run_for_date, status, finished_at, details)
values ('backup', '2027-03-11', 'failed', public.app_now(), '{"error": "test"}');
select is(public.nightly_kick(), 'waiting: today''s closes are confirmed at 9:00 pm',
  'between the 4:30 pm run and 9:00 pm, no call just to wait for today''s closes (a failed backup doesn''t change that)');
select is(tests.queued(), 0, '...nothing queued');
select tests.clock('2027-03-11 21:00');
select is(public.nightly_kick(), 'queued', 'at 9:00 pm, a call for the closes');
select tests.clock('2027-03-11 21:30');
select is(public.nightly_kick(), 'queued', '9:30 pm, still missing: another call');
select is(tests.alerts('missing_price', 'dow', '2027-03-11'), 0, '...but no alert yet (the confirm runs get their chance)');
select tests.clock('2027-03-11 21:59');
select public.nightly_kick();
select is(tests.alerts('missing_price', 'dow', '2027-03-11'), 0, 'no alert at 9:59 pm');
select tests.clock('2027-03-11 22:00');
select public.nightly_kick();
select is(tests.alerts('missing_price', 'dow', '2027-03-11'), 1, 'at 10:00 pm, an alert for the missing Dow close');
select is((select count(*)::int from public.alerts where kind = 'missing_price' and not is_quiet
            and details ->> 'date' = '2027-03-11'), 3, '...one per fund');
select tests.clock('2027-03-11 22:01');
select public.store_close(f.id, date '2027-03-11', 100) from public.funds f;
select is((select count(*)::int from public.alerts where kind = 'missing_price' and details ->> 'date' = '2027-03-11'
            and resolved_at is null), 0, 'each clears itself as its close is stored');

-- A core job that failed is still retried every half hour, 9:00 pm or not.
select tests.clock('2027-03-12 16:30');
insert into public.job_runs (job, run_for_date, status, finished_at, details)
values ('interest', '2027-03-11', 'failed', public.app_now(), '{"error": "test"}');
select tests.clock('2027-03-12 17:00');
select is(public.nightly_kick(), 'queued', 'a failed core job: the kick still calls, before 9:00 pm');

-- 6. Catch-up in bounded steps ----------------------------------------------------------------------

-- Expire is a core job: it needs no close, so each day it runs counts.
create temp table before_expire as
  select coalesce(max(run_for_date), date '2027-01-31') as d from public.job_runs where job = 'expire' and status = 'ok';
select tests.clock('2027-03-31 21:30');
create temp table step1 as select public.run_daily(date '2027-03-31', 5) as r;
create temp table n1 as select count(distinct run_for_date)::int as n from public.job_runs
  where job = 'expire' and status = 'ok' and run_for_date > (select d from before_expire);
select ok((select n from n1) between 1 and 5, 'one bounded call runs at most 5 days');
select is((select r ->> 'more' from step1), 'true', '...and says there''s more to do');
create temp table step2 as select public.run_daily(date '2027-03-31', 5) as r;
select ok((select count(distinct run_for_date)::int from public.job_runs
            where job = 'expire' and status = 'ok' and run_for_date > (select d from before_expire))
           between (select n from n1) + 1 and (select n from n1) + 5,
  'the next call carries on from there, again at most 5 days');
-- Then all the way, in steps.
do $$
begin
  for i in 1 .. 60 loop
    exit when (public.run_daily(date '2027-03-31', 5) ->> 'more') = 'false';
  end loop;
end;
$$;
select is((select max(run_for_date) from public.job_runs where job = 'expire' and status = 'ok'), date '2027-03-31',
  'calls keep going until tonight''s day is done');
select is((select count(*)::int from (select run_for_date from public.job_runs where job = 'expire' and status = 'ok'
            group by run_for_date having count(*) > 1) x), 0, '...each day exactly once');
select is((select count(*)::int from (select posting_key from public.transactions where posting_key is not null
            group by posting_key having count(*) > 1) x), 0, '...nothing posted twice');

-- reconcile_through in bounded steps too.
create temp table rec1 as select public.reconcile_through(date '2027-03-31', 5) as r;
select ok(jsonb_array_length((select r -> 'reconciled' from rec1)) <= 5, 'one bounded check covers at most 5 days');
do $$
begin
  for i in 1 .. 60 loop
    exit when (public.reconcile_through(date '2027-03-31', 5) ->> 'more') = 'false';
  end loop;
end;
$$;
select is((select count(*)::int from public.job_runs where job = 'reconcile' and run_for_date = '2027-03-31'), 1,
  '...and the checks keep going to tonight, each day once');
select is(public.run_daily(date '2027-03-31', 5) ->> 'more', 'false', 'nothing left: "more" is false');

-- 7. The provider's values, and the mismatch check (off until Dad turns it on) --------------------

select tests.clock('2027-04-01 21:30');
select is(public.record_price_observations('dow', jsonb_build_array(
            jsonb_build_object('date', '2027-03-08', 'close', '400.05'),
            jsonb_build_object('date', '2027-03-11', 'close', '100'))), 2,
  'each fetch keeps what the provider returned');
select is(public.check_price_mismatches(), 0, 'with the check off (as the migration leaves it), no alert');
insert into public.settings (key, value, effective_date) values ('price_mismatch_check', 'on', date '2026-01-01');
select is(public.check_price_mismatches(), 1, 'on: one mismatch (Mar 8: $400.00 stored, $400.05 now)');
select is(tests.alerts('price_mismatch', 'dow', '2027-03-08'), 1, '...an alert for that close');
select is((select message from public.alerts where kind = 'price_mismatch' and details ->> 'date' = '2027-03-08'),
  'The Dow Jones close stored for Mar 8 is $400.0000, but the provider now says $400.0500. Check it against the official close; if it''s wrong, fix it with "Fix a close".',
  '...in Dad''s words');
select is(tests.alerts('price_mismatch', 'dow', '2027-03-11'), 0, 'a close that matches: no alert');
select is(public.check_price_mismatches(), 0, 'the next run doesn''t repeat it');
-- An observation taken before a close was ready doesn't count.
select tests.clock('2027-04-02 16:30');
select public.record_price_observations('tsx', jsonb_build_array(jsonb_build_object('date', '2027-04-02', 'close', '99')));
select is(public.check_price_mismatches(), 0, 'a 4:30 pm snapshot of today never raises a mismatch');
select is(public.check_price_mismatches(), 0, 'a mismatch is only ever raised once per close');

select * from finish();
rollback;
