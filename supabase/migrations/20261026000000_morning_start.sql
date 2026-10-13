-- The morning start (Dad, 2026-10-12). GitHub's own schedule for the daily Backup and
-- Health check fired 8 hours late on Oct 12, 2026 (and not at all on Oct 11): the health
-- check ran before the backup and failed on a 42-hour-old backup, and Dad's computer
-- warned about it at 9:30 am. The database's own timer is reliable, so it now starts both
-- workflows each morning through GitHub's API (workflow_dispatch). GitHub's schedule
-- stays, moved to the early afternoon, as a backstop.
--
-- 1. morning_kick() (pg_cron, every 15 minutes from 7:00 to 11:45 am Alberta time, which is
--    13:00 to 17:45 UTC all year: Alberta is UTC−6 all year from Nov 1, 2026, and the
--    database's own rule has it so since Mar 8, 2026):
--    - the Backup, once a day, unless a backup is already recorded today;
--    - then the Health check, once a day, once today's backup is recorded, or at 9:00 am
--      if it never is (so the keep-alive and the health record still happen);
--    - a reminder alert 21 days before the GitHub token expires, once per expiry date.
--    Each start is queued with queue_outside(), so nothing happens in a preview.
-- 2. send_outbox(), still the only sender: it now also sends the GitHub starts (token and
--    repo from Vault, never stored in the outbox), and reads GitHub's reply to each one.
--    A refusal (for example 401, an expired or revoked token), or no reply within an
--    hour, raises one github_dispatch_failed alert; the next accepted start settles it.
--    The nightly call is sent exactly as before.
-- 3. set_github_dispatch(repo, expires): Dad, once, in the SQL Editor. The repo and the
--    token's expiry date aren't secret; the token itself goes in through the Vault
--    screen, never a query (the SQL Editor keeps a history).
-- 4. The timer, and after_restore() puts it back.
--
-- No interest, GIC, fund, posting or nightly code is touched. Known answers:
-- supabase/tests/morning_dispatch_test.sql.

alter type public.alert_kind add value if not exists 'github_dispatch_failed';
alter type public.alert_kind add value if not exists 'github_token_expiring';

-- GitHub's reply to a start (its HTTP status, 0 for no answer), once read.
alter table public.outbox add column reply_status integer;
comment on column public.outbox.reply_status is
  'GitHub starts only: the HTTP status GitHub answered (0 for no answer within an hour), once send_outbox() has read it.';

-- Each workflow is started at most once a day, whatever happens.
create unique index outbox_github_once on public.outbox ((payload ->> 'dispatch_key')) where payload ? 'dispatch_key';

-- 1. The morning kick -------------------------------------------------------------------------------------

create function public.morning_kick()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_local timestamp := public.edmonton_local(public.app_now());
  v_today date := public.app_today();
  v_day text := to_char(public.app_today(), 'YYYY-MM-DD');
  v_expires_text text;
  v_expires date;
  v_backup_today boolean;
begin
  if public.in_preview() then
    return 'preview: nothing is started in a preview';
  end if;
  -- Not set up (your own computer, or production before RUNBOOK's "The morning start").
  if private.vault_value('github_dispatch_token') is null or private.vault_value('github_backup_repo') is null then
    return 'not set up: the GitHub token and repo aren''t in Vault';
  end if;
  if v_local::time < time '07:00' or v_local::time >= time '12:00' then
    return 'outside the morning window: 7:00 to 11:45 am Alberta time';
  end if;

  -- The token's expiry: one reminder per expiry date, from 21 days ahead.
  v_expires_text := private.vault_value('github_dispatch_token_expires');
  if v_expires_text ~ '^\d{4}-\d{2}-\d{2}$' then
    v_expires := v_expires_text::date;
    if v_expires - v_today <= 21
       and not exists (select 1 from public.alerts al
                        where al.kind = 'github_token_expiring' and al.details ->> 'expires' = v_expires_text) then
      insert into public.alerts (kind, is_quiet, message, details)
      values ('github_token_expiring', false,
              'The GitHub token that starts the morning backup '
                || case when v_expires > v_today then 'expires on ' else 'expired on ' end
                || to_char(v_expires, 'Mon FMDD, YYYY') || '. Make a new one '
                || case when v_expires > v_today then 'before then' else 'now' end
                || ': RUNBOOK, "Renew the GitHub token".',
              jsonb_build_object('expires', v_expires_text));
    end if;
  end if;

  v_backup_today := exists (select 1 from public.job_runs jr
                             where jr.job = 'backup' and jr.status = 'ok'
                               and public.edmonton_local(jr.finished_at)::date = v_today);

  -- The Backup: once a day, unless one is already recorded today.
  if not v_backup_today
     and not exists (select 1 from public.outbox o where o.payload ->> 'dispatch_key' = 'github:backup:' || v_day) then
    perform public.queue_outside('http', jsonb_build_object('target', 'github', 'workflow', 'backup',
                                                            'for_date', v_day, 'dispatch_key', 'github:backup:' || v_day));
    return 'queued: Backup';
  end if;

  if exists (select 1 from public.outbox o where o.payload ->> 'dispatch_key' = 'github:health:' || v_day) then
    return 'done: this morning''s Backup and Health check have been started';
  end if;

  -- The Health check: after today's backup, or at 9:00 am if there's none.
  if v_backup_today or v_local::time >= time '09:00' then
    perform public.queue_outside('http', jsonb_build_object('target', 'github', 'workflow', 'health',
                                                            'for_date', v_day, 'dispatch_key', 'github:health:' || v_day));
    return 'queued: Health check';
  end if;
  return 'waiting: today''s backup isn''t recorded yet (the Health check starts once it is, or at 9:00 am)';
end;
$$;
comment on function public.morning_kick() is
  'Run by pg_cron, 7:00 to 11:45 am Alberta time: starts GitHub''s Backup once a day, then the Health check once the backup is recorded (or at 9:00 am), and reminds Dad before the GitHub token expires. Does nothing without its Vault entries or in a preview.';
revoke all on function public.morning_kick() from public, anon, authenticated, service_role, backup_reader;

-- 2. The one sender, now for GitHub's starts too --------------------------------------------------------

create or replace function public.send_outbox()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.outbox;
  v_url text;
  v_key text;
  v_token text;
  v_repo text;
  v_file text;
  v_name text;
  v_status integer;
  v_req bigint;
  v_sent integer := 0;
begin
  if public.in_preview() then
    return 0;
  end if;

  -- GitHub's reply to each start already sent: read once. A refusal, or no reply within an
  -- hour, raises one alert; an accepted start settles it.
  for v_row in
    select * from public.outbox o
     where o.kind = 'http' and o.payload ->> 'target' = 'github'
       and o.sent_at is not null and o.reply_status is null
     order by o.id
     for update skip locked
  loop
    select coalesce(r.status_code, 0) into v_status from net._http_response r where r.id = v_row.net_request_id;
    if not found then
      if v_row.sent_at > public.app_now() - interval '1 hour' then
        continue;
      end if;
      v_status := 0;
    end if;
    update public.outbox set reply_status = v_status where id = v_row.id;
    v_name := case v_row.payload ->> 'workflow' when 'backup' then 'Backup' else 'Health check' end;
    if v_status between 200 and 299 then
      update public.alerts set resolved_at = public.app_now()
       where kind = 'github_dispatch_failed' and resolved_at is null;
    elsif not exists (select 1 from public.alerts al where al.kind = 'github_dispatch_failed' and al.resolved_at is null) then
      insert into public.alerts (kind, is_quiet, message, details)
      values ('github_dispatch_failed', false,
              case when v_status in (401, 403)
                   then 'GitHub refused this morning''s start of the ' || v_name || ' (' || v_status
                        || '): the token has probably expired or been revoked.'
                   else 'GitHub didn''t start this morning''s ' || v_name || ' ('
                        || case when v_status = 0 then 'no answer' else v_status::text end || ').'
              end
              || ' GitHub''s own schedule still runs later today. See RUNBOOK, "The morning start failed".',
              jsonb_build_object('workflow', v_row.payload ->> 'workflow', 'for_date', v_row.payload ->> 'for_date',
                                 'status', v_status));
    end if;
  end loop;

  for v_row in
    select * from public.outbox o
     where o.sent_at is null and o.kind = 'http' and o.attempts < 3
     order by o.id
     for update skip locked
  loop
    if v_row.payload ->> 'target' = 'nightly' then
      v_url := private.vault_value('nightly_function_url');
      v_key := private.vault_value('nightly_function_key');
      if v_url is null or v_key is null then
        update public.outbox set attempts = attempts + 1, last_error = 'the nightly function''s address or key isn''t in Vault'
         where id = v_row.id;
        continue;
      end if;
      -- pg_net sends it after this transaction commits. The function can take a while.
      v_req := net.http_post(url := v_url,
                             body := jsonb_build_object('mode', 'nightly'),
                             headers := jsonb_build_object('Content-Type', 'application/json', 'x-nightly-key', v_key),
                             timeout_milliseconds := 150000);
    elsif v_row.payload ->> 'target' = 'github' then
      v_file := case v_row.payload ->> 'workflow' when 'backup' then 'backup.yml' when 'health' then 'health-check.yml' end;
      if v_file is null then
        update public.outbox set attempts = attempts + 1, last_error = 'no sender for this message' where id = v_row.id;
        continue;
      end if;
      v_token := private.vault_value('github_dispatch_token');
      v_repo := private.vault_value('github_backup_repo');
      if v_token is null or v_repo is null then
        update public.outbox set attempts = attempts + 1, last_error = 'the GitHub token or repo isn''t in Vault'
         where id = v_row.id;
        continue;
      end if;
      -- The token only ever goes to GitHub's API, for big-bucks-backups.
      if v_repo !~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/big-bucks-backups$' then
        update public.outbox set attempts = attempts + 1, last_error = 'the repo in Vault isn''t <username>/big-bucks-backups'
         where id = v_row.id;
        continue;
      end if;
      v_req := net.http_post(url := 'https://api.github.com/repos/' || v_repo || '/actions/workflows/' || v_file || '/dispatches',
                             body := jsonb_build_object('ref', 'main'),
                             headers := jsonb_build_object('Accept', 'application/vnd.github+json',
                                                           'Authorization', 'Bearer ' || v_token,
                                                           'X-GitHub-Api-Version', '2022-11-28',
                                                           'User-Agent', 'big-bucks-morning-start',
                                                           'Content-Type', 'application/json'),
                             timeout_milliseconds := 30000);
    else
      update public.outbox set attempts = attempts + 1, last_error = 'no sender for this message'
       where id = v_row.id;
      continue;
    end if;
    update public.outbox set sent_at = public.app_now(), attempts = attempts + 1, net_request_id = v_req, last_error = null
     where id = v_row.id;
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end;
$$;
comment on function public.send_outbox() is
  'The only function that reaches outside the database. Stops at once in a preview. Sends queued calls to the nightly function and GitHub''s workflow starts through pg_net, and reads GitHub''s replies.';

-- 3. The setup (Dad, once, in the SQL Editor) -------------------------------------------------------------

-- Saves a Vault value, replacing any earlier one of that name.
create function private.vault_put(p_name text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := (select s.id from vault.secrets s where s.name = p_name limit 1);
begin
  if v_id is null then
    perform vault.create_secret(p_value, p_name);
  else
    perform vault.update_secret(v_id, p_value);
  end if;
end;
$$;
revoke all on function private.vault_put(text, text) from public, anon, authenticated, service_role, backup_reader;

create function public.set_github_dispatch(p_repo text, p_expires date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
begin
  if p_repo is null or p_repo !~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/big-bucks-backups$' then
    raise exception 'The repo must be <your GitHub username>/big-bucks-backups (RUNBOOK, "The morning start").';
  end if;
  if p_expires is null or p_expires <= v_today or p_expires > v_today + 366 then
    raise exception 'The expiry date must be after today and at most 366 days away: use the date GitHub showed for the token.';
  end if;
  perform private.vault_put('github_backup_repo', p_repo);
  perform private.vault_put('github_dispatch_token_expires', to_char(p_expires, 'YYYY-MM-DD'));
  -- A new date settles the reminder for the old one.
  update public.alerts set resolved_at = public.app_now()
   where kind = 'github_token_expiring' and resolved_at is null
     and details ->> 'expires' is distinct from to_char(p_expires, 'YYYY-MM-DD');
  return 'Saved: ' || p_repo || ', token expires ' || to_char(p_expires, 'Mon FMDD, YYYY') || '. '
         || case when private.vault_value('github_dispatch_token') is not null
                 then 'The token is in Vault too: the first start is at 7:00 am.'
                 else 'Now add the token in Vault as github_dispatch_token (RUNBOOK, "The morning start").' end;
end;
$$;
comment on function public.set_github_dispatch(text, date) is
  'Database owner only (SQL Editor): saves the backup repo and the GitHub token''s expiry date in Vault for the morning start. The token itself goes in through the Vault screen.';
revoke all on function public.set_github_dispatch(text, date) from public, anon, authenticated, service_role, backup_reader;

-- 4. The timer, and after a restore -----------------------------------------------------------------------

-- Every 15 minutes, 13:00 to 17:45 UTC: 7:00 to 11:45 am in Alberta, all year (UTC−6).
select cron.schedule('big-bucks-morning', '0,15,30,45 13,14,15,16,17 * * *',
                     'select public.morning_kick(); select public.send_outbox();');

-- As in 20261023000000_backups.sql, with the morning timer and the GitHub token added.
create or replace function public.after_restore()
returns table (step text, result text)
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_trigger t where t.tgname = 'protect_kid_login' and t.tgrelid = 'auth.users'::regclass) then
    create trigger protect_kid_login before update on auth.users
      for each row execute function public.protect_kid_login();
    step := 'Login guard'; result := 'Put back.';
  else
    step := 'Login guard'; result := 'Already there.';
  end if;
  return next;

  if not exists (select 1 from cron.job j where j.jobname = 'big-bucks-nightly') then
    perform cron.schedule('big-bucks-nightly', '0,30 22,23,0,1,2,3,4 * * *',
                          'select public.nightly_kick(); select public.send_outbox();');
    step := 'Nightly timer'; result := 'Put back.';
  else
    step := 'Nightly timer'; result := 'Already there.';
  end if;
  return next;

  if not exists (select 1 from cron.job j where j.jobname = 'big-bucks-morning') then
    perform cron.schedule('big-bucks-morning', '0,15,30,45 13,14,15,16,17 * * *',
                          'select public.morning_kick(); select public.send_outbox();');
    step := 'Morning timer'; result := 'Put back.';
  else
    step := 'Morning timer'; result := 'Already there.';
  end if;
  return next;

  if not exists (select 1 from vault.secrets s where s.name = 'kid_login_key') then
    perform public.new_kid_login_key();
    step := 'Login key'; result := 'Made a new one. Reset each girl''s PIN (RUNBOOK, "A girl forgot her PIN").';
  else
    step := 'Login key'; result := 'Already there.';
  end if;
  return next;

  step := 'Nightly function''s address and key';
  result := case when exists (select 1 from vault.secrets s where s.name = 'nightly_function_key')
                 then 'Already there.'
                 else 'Missing: redo production setup step 7 (set_nightly_vault).' end;
  return next;

  step := 'GitHub token for the morning start';
  result := case when exists (select 1 from vault.secrets s where s.name = 'github_dispatch_token')
                  and exists (select 1 from vault.secrets s where s.name = 'github_backup_repo')
                 then 'Already there.'
                 else 'Missing: redo RUNBOOK "The morning start" (a new token, then set_github_dispatch).' end;
  return next;
end;
$$;
comment on function public.after_restore() is
  'Database owner only, after restoring a backup into a new project: puts back the login guard and the nightly and morning timers, makes a new login key, and says what''s left.';
