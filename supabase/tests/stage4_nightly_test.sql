-- Stage 4, Part A (plan approved by Dad, 2026-10-09): saving closes, splits, the
-- price-call budget, the nightly kick and its timing, the one sender in a preview,
-- the 9:00 pm missing-close alert and the database-size alert. Known answers over
-- Feb and Mar 2027 (Alberta UTC−6; Toronto on standard time until Mar 14, so the
-- markets close at 3:00 pm Alberta time).
--
-- Works on a fresh database (CI) and on one holding the local demo: expectations
-- that depend on what's already stored are worked out from it.
begin;
select plan(90);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

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
create function tests.last_close(p_fund text) returns numeric language sql as $$
  select coalesce((select close from public.fund_prices where fund_id = p_fund order by price_date desc limit 1), 400);
$$;
create function tests.alerts(p_kind text, p_fund text, p_date date) returns integer language sql as $$
  select count(*)::int from public.alerts
   where kind::text = p_kind and details ->> 'fund_id' = p_fund and details ->> 'date' = p_date::text;
$$;
create function tests.queued() returns integer language sql as $$
  select count(*)::int from public.outbox where kind = 'http' and payload ->> 'target' = 'nightly';
$$;
-- Every job finished for a day, as the nightly run leaves it.
create function tests.finish_day(p_date date) returns void language sql as $$
  insert into public.job_runs (job, run_for_date, status, finished_at)
  select j::public.job_name, case when j = 'interest' then p_date - 1 else p_date end, 'ok', public.app_now()
    from unnest(array['expire', 'splits', 'settle', 'dividends', 'notes', 'gic_maturity', 'auto_move',
                      'monthly', 'rate_notices', 'interest', 'reconcile']) j;
$$;

-- A kid whose account opens on Feb 1, 2027, so closes matter from then on (or from
-- earlier, if the demo is loaded).
select tests.clock('2027-02-01 09:00');
insert into public.accounts (name, is_test) values ('Test stage4', true);

-- 1. store_close: when a close may be saved ------------------------------------------

select tests.clock('2027-03-01 14:59');
select is(tests.err($$select public.store_close('dow', date '2027-03-01', 400)$$),
  'The nyse market hasn''t closed yet on 2027-03-01, so that price isn''t a close.',
  'a close before the market closed (3:00 pm Alberta in March) is refused');
select is((select count(*)::int from public.fund_prices where price_date = '2027-03-01'), 0, '...and nothing is stored');

select tests.clock('2027-03-01 15:00');
select is(public.store_close('dow', date '2027-03-01', tests.last_close('dow')), 'stored',
  'at the close itself (3:00 pm Alberta), it is stored');
select isnt(public.final_close('dow', date '2027-03-01'), null::numeric, '...and it is final');
select is((select source from public.fund_prices where fund_id = 'dow' and price_date = '2027-03-01'), 'daily',
  '...as a daily close');

select is(tests.err($$select public.store_close('dow', date '2027-02-27', 400)$$),
  'The nyse market doesn''t trade on 2027-02-27, so there''s no close to store.', 'a Saturday is refused');
select is(tests.err($$select public.store_close('tsx', date '2027-02-15', 40)$$),
  'The tsx market doesn''t trade on 2027-02-15, so there''s no close to store.', 'a market holiday is refused');
select is(tests.err($$select public.store_close('dow', date '2027-03-01', 0)$$),
  'A close is a price above $0, with at most 8 decimal places.', 'a zero close is refused');
select is(tests.err($$select public.store_close('dow', date '2027-03-01', 1.123456789)$$),
  'A close is a price above $0, with at most 8 decimal places.', 'more than 8 decimals is refused');
select is(tests.err($$select public.store_close('nope', date '2027-03-01', 1)$$),
  'There''s no fund called "nope".', 'an unknown fund is refused');
select is(tests.err($$select public.store_close('dow', date '2027-03-01', 1, 'guess')$$),
  'A close comes from the daily series or the weekly backfill.', 'an unknown source is refused');

-- Never overwritten.
select is(public.store_close('dow', date '2027-03-01', tests.last_close('dow')), 'already',
  'the same close again changes nothing');
select is(public.store_close('dow', date '2027-03-01', tests.last_close('dow') + 1), 'differs',
  'a different close for a stored day is reported...');
select is((select close from public.fund_prices where fund_id = 'dow' and price_date = '2027-03-01'),
  tests.last_close('dow'), '...and the stored close is kept');

-- 2. Weekly backfill closes ---------------------------------------------------------------

select is(public.store_close('dow', date '2025-01-10', 425.5, 'weekly_backfill'), 'stored',
  'a weekly close from before the first account is stored');
select is(public.final_close('dow', date '2025-01-10'), null::numeric,
  '...but it is never final, so no trade, dividend or note can use it');
select is(tests.err(format($$select public.store_close('dow', %L, 400, 'weekly_backfill')$$,
                           public.first_trading_day_from('nyse', public.first_account_day()))),
  format('A weekly backfill close is only for days before the first account opened (%s).', public.first_account_day()),
  'a weekly close on or after the first account''s day is refused');

-- 3. A big move with no split -------------------------------------------------------------

select tests.clock('2027-03-02 15:00');
select is(public.store_close('dow', date '2027-03-02', round(tests.last_close('dow') * 1.26, 4)), 'stored',
  'a 26% jump is still stored (it may be real)...');
select is((select count(*)::int from public.alerts where kind = 'price_jump' and is_quiet
            and details ->> 'fund_id' = 'dow' and details ->> 'date' = '2027-03-02'), 1,
  '...with one quiet alert for Dad to check it');
select is(public.store_close('nasdaq100', date '2027-03-02', round(tests.last_close('nasdaq100') * 1.24, 4)), 'stored',
  'a 24% move is stored...');
select is(tests.alerts('price_jump', 'nasdaq100', '2027-03-02'), 0, '...with no alert');

-- A split recorded in between explains the move: no alert.
select tests.clock('2027-03-03 12:00');
select is(public.record_split('dow', date '2027-03-04', 1, 2), 'recorded', 'a split for a later day is recorded');
select is(public.record_split('dow', date '2027-03-04', 1, 2), 'already', '...and the same split again changes nothing');
select tests.clock('2027-03-04 15:00');
select is(public.store_close('dow', date '2027-03-04', round(tests.last_close('dow') / 2, 4)), 'stored',
  'the half-price close on the split day is stored...');
select is(tests.alerts('price_jump', 'dow', '2027-03-04'), 0, '...with no alert, since the split explains it');

-- 4. Splits: too late is an alert, not a change ----------------------------------------------

select is(public.record_split('nasdaq100', date '2027-03-04', 1, 3), 'recorded',
  'a split for today, before tonight''s split job, is recorded');
insert into public.job_runs (job, run_for_date, status, finished_at) values ('splits', '2027-03-04', 'ok', public.app_now());
select is(public.record_split('tsx', date '2027-03-04', 1, 2), 'too_late',
  'once tonight''s split job has run, a split for today is too late');
select is((select count(*)::int from public.alerts where kind = 'late_split' and not is_quiet
            and details ->> 'fund_id' = 'tsx'), 1, '...and Dad gets an alert');
select is((select count(*)::int from public.fund_splits where fund_id = 'tsx' and split_date = '2027-03-04'), 0,
  '...and nothing is recorded');
select is(public.record_split('tsx', date '2027-02-26', 2, 1), 'too_late', 'a split since the first account opened is too late');
select is(public.record_split('tsx', date '2027-02-26', 2, 1), 'too_late', '...asked again');
select is(tests.alerts('late_split', 'tsx', '2027-02-26'), 1, '...still one alert');
select is(public.record_split('nasdaq100', date '2000-03-20', 1, 2), 'history',
  'a split from long before any account is old history: nothing to do');
select is(tests.alerts('late_split', 'nasdaq100', '2000-03-20'), 0, '...and no alert');
select is(public.record_split('dow', date '2027-03-04', 1, 3), 'differs',
  'a different ratio for a recorded split is reported...');
select is(tests.alerts('late_split', 'dow', '2027-03-04'), 1, '...with an alert');
select is(tests.err($$select public.record_split('dow', date '2027-04-01', 2, 2)$$),
  'A split needs its day and two different whole numbers (2-for-1 is from 1, to 2).', 'a ratio that changes nothing is refused');

-- 5. store_closes: refusals are reported, not fatal; storing settles the missing alert --------

insert into public.alerts (kind, message, details)
values ('missing_price', 'test', jsonb_build_object('fund_id', 'tsx', 'date', '2027-03-04'));
select is(public.store_closes('tsx', jsonb_build_array(
            jsonb_build_object('date', '2027-03-03', 'close', '41.25'),
            jsonb_build_object('date', '2027-03-04', 'close', '41.5'),
            jsonb_build_object('date', '2027-03-06', 'close', '41.75'),
            jsonb_build_object('date', '2027-03-05', 'close', '41.8'))) -> 'counts',
  '{"stored": 2, "refused": 2}'::jsonb, 'several closes at once: the good ones are stored, the others reported');
select is((select count(*)::int from public.alerts where kind = 'missing_price' and details ->> 'fund_id' = 'tsx'
             and details ->> 'date' = '2027-03-04' and resolved_at is null), 0,
  'storing a close settles its "missing close" alert');

-- 6. The price-call budget: 20 a day -----------------------------------------------------------

select is((select count(*)::int from generate_series(1, 20) i
            where public.claim_price_call('daily', 'DIA') is not null), 20, '20 calls a day go ahead');
select is(public.claim_price_call('daily', 'DIA'), null::bigint, 'the 21st is refused');
select tests.clock('2027-03-05 09:00');
select isnt(public.claim_price_call('splits', 'DIA'), null::bigint, 'the next day starts fresh');

-- 7. The nightly kick ------------------------------------------------------------------------

select is(public.nightly_target(), date '2027-03-04', 'before 4:30 pm, the run works through yesterday');
select tests.clock('2027-03-05 16:30');
select is(public.nightly_target(), date '2027-03-05', 'from 4:30 pm, through today');

select is(public.nightly_kick(), 'not set up: the nightly function''s address and key aren''t in Vault',
  'without its Vault entries, the kick does nothing (your own computer)');
select is(tests.queued(), 0, '...and queues nothing');

select vault.create_secret('http://supabase_kong_big-bucks:8000/functions/v1/nightly', 'nightly_function_url');
select vault.create_secret('local-nightly-key-for-this-computer-only', 'nightly_function_key');

select tests.clock('2027-03-05 16:29');
select is(public.nightly_kick(), 'too early: the run starts at 4:30 pm Alberta time', 'at 4:29 pm, too early');
select is(tests.queued(), 0, '...nothing queued');
select tests.clock('2027-03-05 16:30');
select is(public.nightly_kick(), 'queued', 'at 4:30 pm, one call is queued');
select is(tests.queued(), 1, '...exactly one');
select tests.clock('2027-03-05 16:54');
select is(public.nightly_kick(), 'waiting: a call went out less than 25 minutes ago', 'a kick soon after waits for it');
select tests.clock('2027-03-05 17:00');
select is(public.nightly_kick(), 'queued', 'half an hour later, still not done: another call');
select is(tests.queued(), 2, '...two in all');

-- Finished work is never repeated.
select tests.clock('2027-03-05 17:30');
select public.store_close(f.id, date '2027-03-05', 100) from public.funds f
 where not exists (select 1 from public.fund_prices p where p.fund_id = f.id and p.price_date = '2027-03-05');
select tests.finish_day(date '2027-03-05');
select is((public.nightly_status(date '2027-03-05') ->> 'done')::boolean, true, 'with closes, jobs and the check done, the day is done');
select is(public.nightly_kick(), 'done: tonight''s work is finished', '...and the kick does nothing');
select is(tests.queued(), 2, '...nothing more queued');

-- 8. The 9:00 pm missing-close alert ------------------------------------------------------------

select tests.clock('2027-03-08 20:59');
select is(public.nightly_kick(), 'queued', 'Monday 8:59 pm with no closes: a call');
select is(tests.alerts('missing_price', 'dow', '2027-03-08'), 0, '...but no alert before 9:00 pm');
select tests.clock('2027-03-08 21:00');
select public.nightly_kick();
select is(tests.alerts('missing_price', 'dow', '2027-03-08'), 1, 'at 9:00 pm, an alert for the missing Dow close');
select is((select count(*)::int from public.alerts where kind = 'missing_price' and not is_quiet
            and details ->> 'date' = '2027-03-08'), 3, '...one per fund, none of them quiet');
select tests.clock('2027-03-08 21:30');
select public.nightly_kick();
select is(tests.alerts('missing_price', 'dow', '2027-03-08'), 1, 'a later kick doesn''t repeat it');
select is((public.health_check() ->> 'ok')::boolean, false, 'an open missing-close alert fails the health check');

-- 9. The one sender ------------------------------------------------------------------------------

select set_config('bigbucks.preview', 'on', true);
select is(public.send_outbox(), 0, 'in a preview, the sender sends nothing');
select is((select count(*)::int from public.outbox where sent_at is not null), 0, '...and marks nothing sent');
select set_config('bigbucks.preview', '', true);
select is(public.send_outbox(), 4,
  'outside a preview, it sends every queued call');
select is((select count(*)::int from public.outbox where kind = 'http' and (sent_at is null or net_request_id is null)), 0,
  '...each handed to pg_net');
select is((select count(*)::int from net.http_request_queue
            where url = 'http://supabase_kong_big-bucks:8000/functions/v1/nightly'
              and headers ->> 'x-nightly-key' = 'local-nightly-key-for-this-computer-only'), 4,
  '...to the address and with the key from Vault (never stored in the outbox)');
select is((select count(*)::int from public.outbox where payload::text like '%local-nightly-key%'), 0,
  'the key is not in the outbox');

-- 10. Database size --------------------------------------------------------------------------------

select is(public.database_size_alert(399 * 1024 * 1024) -> 'alert_raised', 'false'::jsonb, '399 MB: no alert');
select is(public.database_size_alert(401 * 1024 * 1024) -> 'alert_raised', 'true'::jsonb, '401 MB: an alert');
select is(public.database_size_alert(450 * 1024 * 1024) -> 'alert_raised', 'false'::jsonb, '...only one while it''s open');
select is((select message from public.alerts where kind = 'database_size'),
  'The database is 401 MB of the free plan''s 500 MB. See RUNBOOK, "The database is getting big".', '...in Dad''s words');
select is((public.health_check() -> 'problems') @> '[{"alert_kind": "database_size"}]'::jsonb, true,
  'the health check reports it');

-- The health check's "Send test alert".
select isnt(public.raise_test_alert(), null::bigint, 'a test alert goes on Dad''s Dashboard...');
select is((select count(*)::int from public.alerts where kind = 'test' and not is_quiet and resolved_at is null), 1,
  '...as a real (not quiet) alert');
select is((public.health_check() -> 'problems') @> '[{"alert_kind": "test"}]'::jsonb, true,
  '...so the health check fails and GitHub emails him');
select public.raise_test_alert();
select is((select count(*)::int from public.alerts where kind = 'test' and resolved_at is null), 1,
  'sending another while one is open adds nothing');

-- 11. Who may run what ---------------------------------------------------------------------------------

select is(
  array(select r || ' ' || f from unnest(array['anon', 'authenticated']) r,
          unnest(array['public.store_close(text, date, numeric, text)', 'public.store_closes(text, jsonb, text)',
                       'public.record_split(text, date, integer, integer, text)', 'public.claim_price_call(text, text)',
                       'public.finish_price_call(bigint, boolean, text)', 'public.nightly_plan()',
                       'public.nightly_status(date)', 'public.reconcile_through(date)', 'public.check_database_size()',
                       'public.nightly_kick()', 'public.send_outbox()', 'public.database_size_alert(bigint)',
                       'public.raise_missing_price_alerts(date)', 'private.vault_value(text)',
                       'public.raise_test_alert()']) f
         where has_function_privilege(r, f, 'execute')),
  '{}'::text[], 'no app sign-in can save prices, record splits, kick the run, send or read Vault');
select is(
  array(select f from unnest(array['public.nightly_kick()', 'public.send_outbox()', 'public.database_size_alert(bigint)',
                                   'public.raise_missing_price_alerts(date)', 'private.vault_value(text)',
                                   'public.set_nightly_vault(text)']) f
         where has_function_privilege('service_role', f, 'execute')),
  '{}'::text[], 'the service role can''t kick, send or read Vault either (only pg_cron does)');
select is(
  array(select f from unnest(array['public.store_closes(text, jsonb, text)', 'public.record_split(text, date, integer, integer, text)',
                                   'public.nightly_plan()', 'public.reconcile_through(date)', 'public.check_database_size()',
                                   'public.raise_test_alert()']) f
         where not has_function_privilege('service_role', f, 'execute')),
  '{}'::text[], 'the nightly and health functions (service role) can do their work');

-- 12. Setting up the Vault entries on production --------------------------------------------------------

select is(tests.err($$select public.set_nightly_vault('http://127.0.0.1:54321/nightly')$$),
  'Use the nightly function''s address from RUNBOOK: https://<project ref>.supabase.co/…/nightly',
  'only a hosted project''s nightly address is accepted');
create temp table vault_key as
  select public.set_nightly_vault('https://abcdefghijklmnopqrst.supabase.co/functions/v1/nightly') as k;
select matches((select k from vault_key), '^[0-9a-f]{64}$', 'it makes a long random key and answers it once');
select is((select private.vault_value('nightly_function_key')), (select k from vault_key), '...kept in Vault');
select is((select private.vault_value('nightly_function_url')),
  'https://abcdefghijklmnopqrst.supabase.co/functions/v1/nightly', '...with the address');
select isnt(public.set_nightly_vault('https://abcdefghijklmnopqrst.supabase.co/functions/v1/nightly'),
  (select k from vault_key), 'running it again makes a new key');
select is((select count(*)::int from vault.secrets where name in ('nightly_function_url', 'nightly_function_key')), 2,
  '...replacing the old one, not adding another');
select is(
  array(select r from unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.set_nightly_vault(text)', 'execute')),
  '{}'::text[], 'only the database owner (SQL Editor) can set them');

-- 13. The schedule ---------------------------------------------------------------------------------------

select is((select schedule from cron.job where jobname = 'big-bucks-nightly'), '0,30 22,23,0,1,2,3,4 * * *',
  'pg_cron wakes every 30 minutes from 22:00 to 04:30 UTC (4:00 to 10:30 pm in Alberta)');
select is((select command from cron.job where jobname = 'big-bucks-nightly'),
  'select public.nightly_kick(); select public.send_outbox();', '...to kick, then send');
select isnt(to_regprocedure('public.send_outbox()'), null, 'the named sender exists (parent_approvals_test checks it stops in a preview)');

select * from finish();
rollback;
