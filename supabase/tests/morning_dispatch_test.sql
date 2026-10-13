-- The morning start (Dad, 2026-10-12). GitHub's own schedule fired 8 hours late on Oct 12,
-- 2026, so the health check ran before the backup (a false red) and Dad's computer warned
-- about a 35-hour-old backup. The database's own timer (pg_cron → morning_kick, every 15
-- minutes from 7:00 to 11:45 am Alberta time) now starts both workflows through GitHub's
-- API: the Backup once a day, then the Health check once that backup is recorded (or at
-- 9:00 am if it never is). GitHub's schedule stays as a backstop.
--
-- Checked here: nothing without the Vault setup or in a preview; the window, in summer and
-- winter alike (Alberta is UTC−6 all year); each workflow started once a day; the Health
-- check always after the Backup; a backstop run on the same day is harmless; GitHub's reply
-- to each start (a refusal raises one alert, the next good start settles it); the token's
-- expiry reminder; who may call what; the timer; and the nightly sender unchanged.
--
-- Works on a fresh database and on one holding the local demo: earlier backup and health
-- records, alerts of these kinds and GitHub entries are set aside first (rolled back at the
-- end). Nothing is really sent: pg_net only sends once a transaction commits.
begin;
select plan(78);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.open(p_kind text) returns integer language sql as $$
  select count(*)::int from public.alerts where kind::text = p_kind and resolved_at is null;
$$;
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
create function tests.kick_at(p_at text) returns text language plpgsql as $$
begin
  perform tests.clock(p_at);
  return public.morning_kick();
end;
$$;
create function tests.send_at(p_at text) returns integer language plpgsql as $$
begin
  perform tests.clock(p_at);
  return public.send_outbox();
end;
$$;
-- Starts queued for a day: 'backup', 'health', or both (null).
create function tests.starts(p_day text, p_workflow text default null) returns integer language sql as $$
  select count(*)::int from public.outbox
   where payload ->> 'target' = 'github' and payload ->> 'for_date' = p_day
     and (p_workflow is null or payload ->> 'workflow' = p_workflow);
$$;
-- Requests waiting in pg_net for GitHub's API.
create function tests.github_requests() returns integer language sql as $$
  select count(*)::int from net.http_request_queue where url like 'https://api.github.com/%';
$$;
-- GitHub's reply to the start of one workflow on one day, as pg_net would store it.
create function tests.reply(p_day text, p_workflow text, p_status integer) returns void language sql as $$
  insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg)
  select o.net_request_id, p_status, null, '{}'::jsonb, '', false, null
    from public.outbox o
   where o.payload ->> 'target' = 'github' and o.payload ->> 'for_date' = p_day
     and o.payload ->> 'workflow' = p_workflow;
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;

-- A clean slate: no backup or health check recorded, no open alerts of these kinds, no GitHub
-- starts, and none of the GitHub Vault entries (as on your own computer).
delete from public.job_runs where job::text in ('backup', 'health');
update public.alerts set resolved_at = now()
 where kind::text in ('backup_failed', 'health_check_missing', 'github_dispatch_failed', 'github_token_expiring')
   and resolved_at is null;
delete from public.outbox where payload ->> 'target' = 'github';
delete from net.http_request_queue where url like 'https://api.github.com/%';
delete from vault.secrets where name in ('github_dispatch_token', 'github_backup_repo', 'github_dispatch_token_expires');

-- 1. Without the Vault setup (your own computer): nothing ------------------------------------------------

select is(tests.kick_at('2027-06-07 07:00'), 'not set up: the GitHub token and repo aren''t in Vault',
  'without the Vault setup, the morning kick does nothing');
select is(tests.starts('2027-06-07'), 0, '...and starts nothing');

-- 2. The setup: the token in Vault (Dad, through the Vault screen), then the repo and the expiry ----------

select vault.create_secret('test-token-not-a-real-one', 'github_dispatch_token');
select is(tests.kick_at('2027-06-07 07:00'), 'not set up: the GitHub token and repo aren''t in Vault',
  'the token alone isn''t enough: the repo is missing');
select ok(tests.err('select public.set_github_dispatch(''example-owner/some-other-repo'', date ''2028-06-01'')')
            like 'The repo must be <your GitHub username>/big-bucks-backups%',
  'set_github_dispatch refuses any repo but big-bucks-backups');
select ok(tests.err('select public.set_github_dispatch(''example-owner/big-bucks-backups'', date ''2027-06-07'')')
            like 'The expiry date must be after today%',
  '...and an expiry date that isn''t after today');
select ok(tests.err('select public.set_github_dispatch(''example-owner/big-bucks-backups'', date ''2028-06-08'')')
            like 'The expiry date must be after today%',
  '...and one more than 366 days away (GitHub''s longest)');
select is(public.set_github_dispatch('example-owner/big-bucks-backups', date '2028-06-01'),
  'Saved: example-owner/big-bucks-backups, token expires Jun 1, 2028. The token is in Vault too: the first start is at 7:00 am.',
  'set_github_dispatch saves the repo and the expiry date');
select is(private.vault_value('github_backup_repo'), 'example-owner/big-bucks-backups', '...the repo, in Vault');
select is(private.vault_value('github_dispatch_token_expires'), '2028-06-01', '...and the expiry date');

-- 3. A normal morning (Monday, June 7, 2027) ----------------------------------------------------------

select is(tests.kick_at('2027-06-07 06:59'), 'outside the morning window: 7:00 to 11:45 am Alberta time',
  '6:59 am: too early, nothing is started');
select is(tests.kick_at('2027-06-07 07:00'), 'queued: Backup', '7:00 am: the Backup is started');
select is(tests.starts('2027-06-07', 'backup'), 1, '...once');
select is(tests.starts('2027-06-07', 'health'), 0, '...and not the Health check yet');
select is((select count(*)::int from public.outbox where payload::text like '%test-token%'), 0,
  'the token is never stored in the outbox');

select is(tests.send_at('2027-06-07 07:00'), 1, 'the sender sends it');
select is(tests.github_requests(), 1, '...one request to GitHub''s API');
select is((select url from net.http_request_queue where url like 'https://api.github.com/%'),
  'https://api.github.com/repos/example-owner/big-bucks-backups/actions/workflows/backup.yml/dispatches',
  '...to start backup.yml in the repo from Vault');
select is((select method::text from net.http_request_queue where url like 'https://api.github.com/%'), 'POST', '...a POST');
select is((select convert_from(body, 'utf8')::jsonb from net.http_request_queue where url like 'https://api.github.com/%'),
  '{"ref": "main"}'::jsonb, '...on main');
select is((select headers from net.http_request_queue where url like 'https://api.github.com/%'),
  jsonb_build_object('Accept', 'application/vnd.github+json', 'Authorization', 'Bearer test-token-not-a-real-one',
                     'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'big-bucks-morning-start',
                     'Content-Type', 'application/json'),
  '...with the token from Vault and the headers GitHub asks for');
select is((select count(*)::int from public.outbox where payload::text like '%test-token%' or last_error like '%test-token%'), 0,
  '...and the token still isn''t in the outbox');

select is(tests.kick_at('2027-06-07 07:15'),
  'waiting: today''s backup isn''t recorded yet (the Health check starts once it is, or at 9:00 am)',
  '7:15 am: the Backup is still running, so the Health check waits');
select is(tests.starts('2027-06-07', 'backup'), 1, '...and the Backup isn''t started again');

select tests.backup_at('2027-06-07 07:19');
select is(tests.kick_at('2027-06-07 07:30'), 'queued: Health check', '7:30 am: the backup is recorded, so the Health check is started');
select is(tests.send_at('2027-06-07 07:30'), 1, '...and sent');
select is((select count(*)::int from net.http_request_queue
            where url = 'https://api.github.com/repos/example-owner/big-bucks-backups/actions/workflows/health-check.yml/dispatches'),
  1, '...to start health-check.yml');
select is(tests.kick_at('2027-06-07 07:45'), 'done: this morning''s Backup and Health check have been started',
  '7:45 am: done for the day');
select is(tests.kick_at('2027-06-07 11:45'), 'done: this morning''s Backup and Health check have been started',
  '11:45 am: still done, nothing started again');
select is(tests.starts('2027-06-07'), 2, '...one Backup and one Health check, no more');
select is(tests.kick_at('2027-06-07 12:00'), 'outside the morning window: 7:00 to 11:45 am Alberta time',
  'noon: the window has closed');

-- GitHub accepted both (204): no alert.
select tests.reply('2027-06-07', 'backup', 204);
select tests.reply('2027-06-07', 'health', 204);
select tests.send_at('2027-06-07 07:45');
select is(tests.open('github_dispatch_failed'), 0, 'GitHub accepted both starts (204): no alert');
select is((select array_agg(reply_status order by id) from public.outbox where payload ->> 'for_date' = '2027-06-07'),
  array[204, 204], '...and each reply is noted, so it''s read only once');

-- 4. The backstop runs too, later the same day: harmless -----------------------------------------------

select tests.health_at('2027-06-07 13:10');
select tests.backup_at('2027-06-07 12:40');
select is((select count(*)::int from public.job_runs where job = 'backup' and run_for_date = date '2027-06-07'), 2,
  'a backstop backup the same day is a second record, side by side');
select tests.clock('2027-06-07 21:00');
select is(public.check_outside_jobs() -> 'backup' ->> 'late', 'false', 'the evening check sees a fresh backup');
select is(public.check_outside_jobs() -> 'health' ->> 'late', 'false', '...and a fresh health check');
select is(tests.open('backup_failed') + tests.open('health_check_missing') + tests.open('github_dispatch_failed'), 0,
  '...and raises no alert');
select is((select count(*)::int from jsonb_array_elements(public.health_check() -> 'problems') p
            where p ->> 'alert_kind' in ('backup_failed', 'health_check_missing', 'github_dispatch_failed', 'github_token_expiring')),
  0, 'the health check finds none of these alerts either');

-- 5. A late backstop backup after midnight: the morning starts only the Health check --------------------

select tests.backup_at('2027-06-08 01:30');
select is(tests.kick_at('2027-06-08 07:00'), 'queued: Health check',
  'Tuesday 7:00 am: a backup is already recorded today (1:30 am), so only the Health check is started');
select is(tests.starts('2027-06-08', 'backup'), 0, '...no second Backup');
select tests.send_at('2027-06-08 07:00');
select tests.reply('2027-06-08', 'health', 204);
select is(tests.kick_at('2027-06-08 07:15'), 'done: this morning''s Backup and Health check have been started',
  '7:15 am: done');

-- 6 and 7. GitHub refuses (the token expired or was revoked), and no backup by 9:00 am ------------------

select is(tests.kick_at('2027-06-09 07:00'), 'queued: Backup', 'Wednesday 7:00 am: the Backup is started');
select tests.send_at('2027-06-09 07:00');
select tests.reply('2027-06-09', 'backup', 401);
select is(tests.kick_at('2027-06-09 08:45'),
  'waiting: today''s backup isn''t recorded yet (the Health check starts once it is, or at 9:00 am)',
  '8:45 am: no backup recorded, still waiting');
select is(tests.kick_at('2027-06-09 09:00'), 'queued: Health check', '9:00 am: the Health check is started anyway');
select tests.send_at('2027-06-09 09:00');
select is(tests.open('github_dispatch_failed'), 1, 'GitHub refused the Backup''s start (401): one alert');
select is((select message from public.alerts where kind = 'github_dispatch_failed' and resolved_at is null),
  'GitHub refused this morning''s start of the Backup (401): the token has probably expired or been revoked. GitHub''s own schedule still runs later today. See RUNBOOK, "The morning start failed".',
  '...in plain words');
select is((select is_quiet from public.alerts where kind = 'github_dispatch_failed' and resolved_at is null), false,
  '...on Dad''s Dashboard');
select tests.reply('2027-06-09', 'health', 401);
select tests.send_at('2027-06-09 09:30');
select is(tests.open('github_dispatch_failed'), 1, 'the Health check''s refusal too: still one alert, not two');
select is((public.health_check() -> 'problems') @> '[{"kind": "alert", "alert_kind": "github_dispatch_failed"}]'::jsonb, true,
  'the backstop''s health check fails on it, so GitHub emails Dad');

select is(tests.kick_at('2027-06-10 07:00'), 'queued: Backup', 'Thursday 7:00 am: the Backup is started (a new token)');
select tests.send_at('2027-06-10 07:00');
select tests.reply('2027-06-10', 'backup', 204);
select tests.send_at('2027-06-10 07:15');
select is(tests.open('github_dispatch_failed'), 0, '...GitHub accepts it, and the alert settles');

-- No answer at all within an hour: an alert too.
select tests.backup_at('2027-06-10 07:20');
select is(tests.kick_at('2027-06-10 07:30'), 'queued: Health check', '7:30 am: the Health check is started');
select tests.send_at('2027-06-10 07:30');
select tests.send_at('2027-06-10 08:15');
select is(tests.open('github_dispatch_failed'), 0, 'no reply after 45 minutes: no alert yet');
select tests.send_at('2027-06-10 08:45');
select is((select message from public.alerts where kind = 'github_dispatch_failed' and resolved_at is null),
  'GitHub didn''t start this morning''s Health check (no answer). GitHub''s own schedule still runs later today. See RUNBOOK, "The morning start failed".',
  'no reply after 75 minutes: one alert, in plain words');

-- 8. In a preview, or without the token when it's time to send: nothing goes out ------------------------

select set_config('bigbucks.preview', 'on', true);
select is(tests.kick_at('2027-06-11 07:00'), 'preview: nothing is started in a preview', 'in a preview, the morning kick starts nothing');
select is(tests.starts('2027-06-11'), 0, '...and queues nothing');
select set_config('bigbucks.preview', '', true);
select is(tests.kick_at('2027-06-11 07:00'), 'queued: Backup', 'out of the preview, Friday''s Backup is queued');
select set_config('bigbucks.preview', 'on', true);
select is(public.send_outbox(), 0, 'in a preview, the sender sends nothing');
select set_config('bigbucks.preview', '', true);
select is((select sent_at from public.outbox where payload ->> 'for_date' = '2027-06-11'), null, '...and the start is still waiting');

delete from vault.secrets where name = 'github_dispatch_token';
select tests.clock('2027-06-11 07:00');
select is(tests.github_requests() - (select count(*)::int from public.outbox where payload ->> 'target' = 'github' and sent_at is not null),
  0, '(every request so far is one the sender sent)');
select is(public.send_outbox(), 0, 'with the token gone from Vault, nothing is sent');
select is((select last_error from public.outbox where payload ->> 'for_date' = '2027-06-11'),
  'the GitHub token or repo isn''t in Vault', '...and the start says why');
select vault.create_secret('test-token-not-a-real-one', 'github_dispatch_token');

-- 9. The token's expiry reminder ---------------------------------------------------------------------------

select public.set_github_dispatch('example-owner/big-bucks-backups', date '2027-07-05');
select tests.kick_at('2027-06-13 07:00');
select is(tests.open('github_token_expiring'), 0, '22 days before the token expires: no reminder');
select tests.kick_at('2027-06-14 07:00');
select is(tests.open('github_token_expiring'), 1, '21 days before: one reminder');
select is((select message from public.alerts where kind = 'github_token_expiring' and resolved_at is null),
  'The GitHub token that starts the morning backup expires on Jul 5, 2027. Make a new one before then: RUNBOOK, "Renew the GitHub token".',
  '...in plain words');
select tests.kick_at('2027-06-14 07:15');
select is(tests.open('github_token_expiring'), 1, '...still one at the next tick');
update public.alerts set resolved_at = now() where kind = 'github_token_expiring' and resolved_at is null;  -- Dad acknowledges it
select tests.kick_at('2027-06-15 07:00');
select is(tests.open('github_token_expiring'), 0, 'once acknowledged, it doesn''t come back for the same date');
select public.set_github_dispatch('example-owner/big-bucks-backups', date '2027-06-30');
select tests.kick_at('2027-06-16 07:00');
select is(tests.open('github_token_expiring'), 1, 'a new date that is also close: a new reminder');
select public.set_github_dispatch('example-owner/big-bucks-backups', date '2028-06-01');
select is(tests.open('github_token_expiring'), 0, 'a new token''s date a year out settles it');

-- 10. Alberta time all year: the same window in January -------------------------------------------------

select tests.clock('2028-01-12 07:00');
select is(public.app_now(), timestamptz '2028-01-12 13:00:00+00', 'January 7:00 am in Alberta is 13:00 UTC, as in June');
select is(tests.kick_at('2028-01-12 06:45'), 'outside the morning window: 7:00 to 11:45 am Alberta time', 'January 6:45 am: too early');
select is(tests.kick_at('2028-01-12 07:00'), 'queued: Backup', 'January 7:00 am: the Backup is started');
select is((select schedule from cron.job where jobname = 'big-bucks-morning'), '0,15,30,45 13,14,15,16,17 * * *',
  'the timer runs every 15 minutes, 13:00 to 17:45 UTC (7:00 to 11:45 am Alberta time, all year)');
select is((select command from cron.job where jobname = 'big-bucks-morning'),
  'select public.morning_kick(); select public.send_outbox();', '...the kick, then the one sender');

-- 11. The nightly sender is unchanged ------------------------------------------------------------------

delete from vault.secrets where name in ('nightly_function_url', 'nightly_function_key');
select vault.create_secret('http://supabase_kong_big-bucks:8000/functions/v1/nightly', 'nightly_function_url');
select vault.create_secret('local-nightly-key-for-this-computer-only', 'nightly_function_key');
select public.queue_outside('http', jsonb_build_object('target', 'nightly', 'for_date', '2028-01-12'));
select tests.send_at('2028-01-12 16:30');
select is((select headers from net.http_request_queue where url = 'http://supabase_kong_big-bucks:8000/functions/v1/nightly' order by id desc limit 1),
  jsonb_build_object('Content-Type', 'application/json', 'x-nightly-key', 'local-nightly-key-for-this-computer-only'),
  'the nightly call is sent exactly as before');

-- 12. After a restore, and who may call what -----------------------------------------------------------

select cron.unschedule('big-bucks-morning');
select is((select result from public.after_restore() where step = 'Morning timer'), 'Put back.',
  'after a restore, the morning timer is put back');
select is((select schedule from cron.job where jobname = 'big-bucks-morning'), '0,15,30,45 13,14,15,16,17 * * *',
  '...on the same schedule');
select is((select result from public.after_restore() where step = 'GitHub token for the morning start'), 'Already there.',
  '...and it says whether the GitHub token is in Vault');
select is(
  array(select r || ': ' || f from unnest(array['anon', 'authenticated', 'service_role']) r,
                                  unnest(array['public.morning_kick()', 'public.send_outbox()', 'public.set_github_dispatch(text, date)']) f
         where has_function_privilege(r, f, 'execute')),
  '{}'::text[], 'no app sign-in, nor the service role, can start, send or set anything');

select * from finish();
rollback;
