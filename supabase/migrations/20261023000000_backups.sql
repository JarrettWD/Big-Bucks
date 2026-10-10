-- Stage 5: backups and data protection (plan approved by Dad, 2026-10-10).
--
-- 1. ping(): the daily backup's normal API request, so the project always has
--    outside activity (SPEC, Backups & data protection, item 2).
-- 2. backup_reader: the read-only login the daily backup uses. It can read every
--    table (it bypasses row-level security, like pg_dump needs) and change nothing,
--    except recording its own result through record_backup(). If its password ever
--    leaked, nobody could change a cent with it. set_backup_login() gives it a
--    password, shown once (like set_nightly_vault). The backup runs pg_dump itself:
--    `supabase db dump` always switches to the postgres role, which this login can't.
-- 3. record_backup() and check_backup_age(): each successful backup is recorded in
--    job_runs (job 'backup'). Once one has been recorded, the health check raises a
--    backup_failed alert when none has succeeded for 36 hours, so a backup that
--    quietly stopped reaches Dad's Dashboard and email.
-- 4. parent_backup_export(): every table as CSV and JSON text for the Download
--    backup button (parent with MFA, logged). The Edge Function only zips it.
-- 5. prelaunch_reset(): the database owner only, from the SQL Editor. Clears the
--    beta's history, keeps every account and all configuration, needs a backup from
--    the last 2 hours holding everything it clears, and refuses once launched_at is
--    set. Each reset is kept in prelaunch_resets.
-- 6. after_restore(): what a restore into a new project must put back, because the
--    dump leaves it out: the login guard on auth.users, the nightly timer, and a new
--    login key (Vault's old one can't be read there).

-- 1. ping ---------------------------------------------------------------------------------------------

create function public.ping()
returns text
language sql
stable
set search_path = ''
as $$
  select 'ok'::text;
$$;
comment on function public.ping() is
  'The daily backup''s normal API request (the Free plan''s keep-alive). Reads nothing.';
revoke all on function public.ping() from public, anon, authenticated, service_role;
grant execute on function public.ping() to anon, authenticated;

-- 5a. The reset's own record (made before the grants below, so the backup reads it) ------------------

create table public.prelaunch_resets (
  id            bigint generated always as identity primary key,
  done_at       timestamptz not null default public.app_now(),
  backup_run_id bigint not null,
  cleared       jsonb not null
);
comment on table public.prelaunch_resets is
  'Each pre-launch reset: when, the backup taken first (job_runs id), and how many rows it cleared from each table. Append-only.';
create trigger prelaunch_resets_no_update_delete
  before update or delete on public.prelaunch_resets
  for each row execute function public.reject_append_only_change();
create trigger prelaunch_resets_no_truncate
  before truncate on public.prelaunch_resets
  for each statement execute function public.reject_append_only_change();
alter table public.prelaunch_resets enable row level security;
create policy prelaunch_resets_read on public.prelaunch_resets for select to authenticated
  using ((select public.is_parent()));
revoke all on public.prelaunch_resets from public, anon, authenticated, service_role;
grant select on public.prelaunch_resets to authenticated;

-- 2. The backup's read-only login ----------------------------------------------------------------------

-- Roles belong to the whole server, so a database reset on Dad's computer keeps it.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'backup_reader') then
    create role backup_reader nologin bypassrls;
  end if;
end;
$$;
comment on role backup_reader is
  'Big Bucks: the daily backup''s login. Reads every table, changes nothing except recording its own result (record_backup).';

grant usage on schema public, private to backup_reader;
grant select on all tables in schema public, private to backup_reader;
grant select on all sequences in schema public, private to backup_reader;
-- Tables added later are readable too, so a new table can never be left out of the backup.
alter default privileges for role postgres in schema public, private grant select on tables to backup_reader;
alter default privileges for role postgres in schema public, private grant select on sequences to backup_reader;

-- The logins. Supabase owns the auth schema and doesn't let postgres grant it, so the
-- backup reads the three login tables a restore needs through this function: users
-- (with each password hash), identities, and authenticator factors (Dad's MFA). Sessions
-- and refresh tokens are left out on purpose: a restore signs everyone in again, and
-- live sign-in tokens never sit in the backup repo. Storage isn't used by Big Bucks:
-- its two counts must stay 0, or the backup fails (something would be left out).
-- Rows come back as JSON text, in id order.
create function private.backup_auth()
returns table (table_name text, row_count bigint, rows_json text)
language plpgsql
stable
security definer
set search_path = ''
set timezone to 'UTC'
as $$
begin
  return query select 'auth.users'::text, count(*), coalesce(json_agg(to_jsonb(u) order by u.id)::text, '[]')
                 from auth.users u;
  return query select 'auth.identities'::text, count(*), coalesce(json_agg(to_jsonb(i) order by i.id)::text, '[]')
                 from auth.identities i;
  return query select 'auth.mfa_factors'::text, count(*), coalesce(json_agg(to_jsonb(f) order by f.id)::text, '[]')
                 from auth.mfa_factors f;
  return query select 'storage.buckets'::text, count(*), null::text from storage.buckets;
  return query select 'storage.objects'::text, count(*), null::text from storage.objects;
end;
$$;
comment on function private.backup_auth() is
  'The backup login only: the login tables a restore needs, as JSON text, and the (always empty) storage counts.';
revoke all on function private.backup_auth() from public, anon, authenticated, service_role;
grant execute on function private.backup_auth() to backup_reader;

-- Every account's balances, worked out by the database's own views, for the backup's
-- balances.csv and the restore drill's comparison. Only what doesn't depend on the
-- day: savings, held, GICs, and each fund's units and cost (a fund's value moves with
-- each close, and the drill runs on a later day).
create function private.backup_balances()
returns table (account_id uuid, account_name text, is_test boolean, item text, amount text)
language sql
stable
security definer
set search_path = ''
as $$
  select b.account_id, a.name, a.is_test, v.item, v.amount
    from public.account_balances b
    join public.accounts a on a.id = b.account_id
   cross join lateral (values ('savings_cents', b.savings_cents::text), ('held_cents', b.held_cents::text),
                              ('gic_cents', b.gic_cents::text), ('stock_cost_cents', b.stock_cost_cents::text)) v(item, amount)
  union all
  select p.account_id, a.name, a.is_test, x.item, x.amount
    from public.fund_positions p
    join public.accounts a on a.id = p.account_id
   cross join lateral (values ('units:' || p.fund_id, p.units::text), ('cost_cents:' || p.fund_id, p.cost_cents::text)) x(item, amount)
   order by 1, 4;
$$;
comment on function private.backup_balances() is
  'The backup login only: every account''s savings, held, GICs and fund units and cost, for the restore drill.';
revoke all on function private.backup_balances() from public, anon, authenticated, service_role;
grant execute on function private.backup_balances() to backup_reader;

-- A new password for the backup login, shown only this once. The database owner runs
-- it from the SQL Editor (RUNBOOK). Running it again makes a new password: then
-- update the SUPABASE_DB_URL secret in the backup repo.
create function public.set_backup_login()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_password text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  execute format('alter role backup_reader with login password %L', v_password);
  return 'The backup login''s new password, shown only this once. Save it in your password manager: '
         || v_password;
end;
$$;
comment on function public.set_backup_login() is
  'Database owner only (SQL Editor): gives the backup_reader login a new password and shows it once.';
revoke all on function public.set_backup_login() from public, anon, authenticated, service_role, backup_reader;

-- 3. Recording each backup, and noticing when they stop -----------------------------------------------

-- The backup workflow calls this last, after its commit reached GitHub. p_details is
-- {"taken_at": …, "counts": {"public.transactions": 123, …}}: what the backup holds,
-- which prelaunch_reset() checks. A successful backup settles an open backup alert.
create function public.record_backup(p_details jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if jsonb_typeof(p_details -> 'counts') is distinct from 'object'
     or (p_details ->> 'taken_at') is null then
    raise exception 'A backup record needs taken_at and counts.' using errcode = '22023';
  end if;
  insert into public.job_runs (job, run_for_date, status, details, finished_at)
  values ('backup', public.app_today(), 'ok', p_details, public.app_now())
  returning id into v_id;
  update public.alerts set resolved_at = public.app_now()
   where kind = 'backup_failed' and resolved_at is null;
  return 'Backup recorded (' || v_id || ').';
end;
$$;
comment on function public.record_backup(jsonb) is
  'The backup login only: records a successful backup in job_runs and settles an open backup alert.';
revoke all on function public.record_backup(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.record_backup(jsonb) to backup_reader;

-- The health function calls this every morning. Once a backup has ever been
-- recorded, none for 36 hours raises one backup_failed alert (one open at a time).
create function public.check_backup_age()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last timestamptz := (select max(jr.finished_at) from public.job_runs jr
                          where jr.job = 'backup' and jr.status = 'ok');
  v_late boolean;
  v_raised boolean := false;
begin
  v_late := v_last is not null and public.app_now() - v_last > interval '36 hours';
  if v_late and not exists (select 1 from public.alerts al where al.kind = 'backup_failed' and al.resolved_at is null) then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('backup_failed', false,
            'The daily backup hasn''t succeeded since ' || public.fmt_date(public.edmonton_local(v_last)::date)
              || '. Check the Backup workflow in the big-bucks-backups repo on GitHub (RUNBOOK, "A backup failed").',
            jsonb_build_object('last_backup_at', v_last));
    v_raised := true;
  end if;
  return jsonb_build_object('last_backup_at', v_last, 'late', v_late, 'alert_raised', v_raised);
end;
$$;
comment on function public.check_backup_age() is
  'The health check: a backup_failed alert when no backup has succeeded for 36 hours (once one ever has).';
revoke all on function public.check_backup_age() from public, anon, authenticated, service_role;
grant execute on function public.check_backup_age() to service_role;

-- 4. Download backup ----------------------------------------------------------------------------------

-- One CSV field: empty for null, quoted when it holds a comma, a quote, a line break
-- or spaces at either end.
create function private.csv_field(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_value is null then ''
           when p_value ~ '[",\r\n]' or p_value <> btrim(p_value) then '"' || replace(p_value, '"', '""') || '"'
           else p_value
         end;
$$;

-- Columns left out of the Download backup: a PIN reset code's hash could be guessed
-- (6 digits), and the zip may sit on a phone. The daily backup keeps everything.
create function private.export_skip(p_table text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_table when 'private.kid_pin_resets' then array['code_hash'] else array[]::text[] end;
$$;

-- Every table in public and private, as CSV and JSON text. Numbers stay text all the
-- way to the zip, so no fund unit or cent is ever rounded by a JSON parser. Times
-- are in UTC. Logged, like every parent action.
create function public.parent_backup_export()
returns jsonb
language plpgsql
security definer
set search_path = ''
set timezone to 'UTC'
as $$
declare
  v_t record;
  v_cols text[];
  v_skip text[];
  v_sql text;
  v_rows bigint;
  v_csv text;
  v_json text;
  v_tables jsonb := '[]'::jsonb;
  v_total bigint := 0;
begin
  perform public.require_parent();

  for v_t in
    select n.nspname as s, c.relname as t, n.nspname || '.' || c.relname as name
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r', 'p') and n.nspname in ('public', 'private')
     order by n.nspname, c.relname
  loop
    v_skip := private.export_skip(v_t.name);
    select array_agg(a.attname::text order by a.attnum) into v_cols
      from pg_attribute a
     where a.attrelid = format('%I.%I', v_t.s, v_t.t)::regclass and a.attnum > 0 and not a.attisdropped
       and not (a.attname::text = any (v_skip));

    v_sql := format(
      'select count(*), '
      || 'coalesce(string_agg(array_to_string(array[%s], '',''), E''\n'' order by x::text), ''''), '
      || 'coalesce(json_agg(to_jsonb(x) - %L::text[] order by x::text)::text, ''[]'') '
      || 'from %I.%I x',
      (select string_agg(format('private.csv_field(x.%I::text)', c), ', ') from unnest(v_cols) c),
      v_skip, v_t.s, v_t.t);
    execute v_sql into v_rows, v_csv, v_json;

    v_csv := (select string_agg(private.csv_field(c), ',') from unnest(v_cols) c)
             || E'\n' || v_csv || case when v_rows > 0 then E'\n' else '' end;
    v_tables := v_tables || jsonb_build_object('name', v_t.name, 'rows', v_rows, 'csv', v_csv, 'json', v_json);
    v_total := v_total + v_rows;
  end loop;

  perform public.log_parent_action('download_backup', null, null,
    'Downloaded a backup (' || jsonb_array_length(v_tables) || ' tables, ' || v_total || ' rows).',
    jsonb_build_object('tables', jsonb_array_length(v_tables), 'rows', v_total));

  return jsonb_build_object('taken_at', public.app_now(), 'day', public.app_today(), 'tables', v_tables);
end;
$$;
comment on function public.parent_backup_export() is
  'Download backup (parent with MFA): every table as CSV and JSON text, logged. The download-backup function zips it.';
revoke all on function private.csv_field(text) from public, anon, authenticated, service_role;
revoke all on function private.export_skip(text) from public, anon, authenticated, service_role;
revoke all on function public.parent_backup_export() from public, anon, authenticated, service_role;
grant execute on function public.parent_backup_export() to authenticated;

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement', 'correct_fund_price', 'record_market_closure',
                    'reset_kid_pin', 'record_early_close', 'download_backup'));

-- 5b. The pre-launch reset ----------------------------------------------------------------------------

-- The beta's history, which the reset clears. Everything else is kept: every account
-- and login (Dad, 2026-10-10: keep all accounts, test kid included), rates, settings,
-- cancellations (a cancelled rate change must stay cancelled), the glossary, notes,
-- holidays, funds, prices, splits, price corrections, price calls (today's budget),
-- agreement wording, What's new features, job_runs (so no night re-runs) and the
-- parent log.
create function private.prelaunch_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['public.transactions', 'public.interest_accruals', 'public.gic_holdings', 'public.requests',
               'public.notifications', 'public.questions', 'public.goals', 'public.badges',
               'public.wishlist_items', 'public.wishlist_parent_marks', 'public.agreement_signatures',
               'public.whats_new_seen', 'public.alerts', 'public.login_attempts', 'public.outbox',
               'private.kid_pin_resets'];
$$;

create function public.prelaunch_reset(p_confirm text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_phrase constant text := 'clear the test history';
  v_tables text[] := private.prelaunch_tables();
  v_backup public.job_runs;
  v_t text;
  v_now bigint;
  v_then bigint;
  v_cleared jsonb := '{}'::jsonb;
  v_total bigint := 0;
  v_trg record;
begin
  -- Only the database owner, from the SQL Editor: never through the app or the API.
  if current_user <> 'postgres' or coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    raise exception 'Only the database owner can run the pre-launch reset, from the Supabase SQL Editor.'
      using errcode = '42501';
  end if;
  if p_confirm is distinct from c_phrase then
    raise exception 'To confirm, type exactly: select public.prelaunch_reset(''%'');', c_phrase
      using errcode = '22023';
  end if;
  if exists (select 1 from public.settings s where s.key = 'launched_at') then
    raise exception 'Big Bucks has launched (launched_at is set), so the pre-launch reset can never run again.'
      using errcode = '42501';
  end if;

  -- Nothing may change between the check below and the clearing.
  foreach v_t in array v_tables loop
    execute format('lock table %s in access exclusive mode', v_t);
  end loop;

  -- A backup first, from the last 2 hours, holding every row about to be cleared.
  select * into v_backup from public.job_runs jr
   where jr.job = 'backup' and jr.status = 'ok' order by jr.finished_at desc, jr.id desc limit 1;
  if v_backup.id is null or public.app_now() - v_backup.finished_at > interval '2 hours' then
    raise exception 'Take a backup first: in the big-bucks-backups repo, Actions → Backup → Run workflow. When it''s green, run this again within 2 hours.'
      using errcode = '55000';
  end if;
  foreach v_t in array v_tables loop
    execute format('select count(*) from %s', v_t) into v_now;
    v_then := (v_backup.details -> 'counts' ->> v_t)::bigint;
    if v_then is distinct from v_now then
      raise exception 'Something changed since the last backup (% has % rows now, % in the backup). Take a new backup first.',
        v_t, v_now, coalesce(v_then::text, 'none') using errcode = '55000';
    end if;
    v_cleared := v_cleared || jsonb_build_object(v_t, v_now);
    v_total := v_total + v_now;
  end loop;

  -- The append-only guards stop TRUNCATE for every role. They're off only inside this
  -- transaction, and only on the tables being cleared: if anything fails, all of it,
  -- the guards included, rolls back.
  for v_trg in
    select t.tgrelid::regclass::text as tbl, t.tgname
      from pg_trigger t
     where not t.tgisinternal and t.tgfoid = 'public.reject_append_only_change()'::regprocedure
       and t.tgrelid::regclass::text = any (v_tables)
  loop
    execute format('alter table %s disable trigger %I', v_trg.tbl, v_trg.tgname);
  end loop;

  -- No CASCADE: if a kept table ever points at a cleared one, this stops instead.
  execute 'truncate table ' || array_to_string(v_tables, ', ');

  for v_trg in
    select t.tgrelid::regclass::text as tbl, t.tgname
      from pg_trigger t
     where not t.tgisinternal and t.tgfoid = 'public.reject_append_only_change()'::regprocedure
       and t.tgrelid::regclass::text = any (v_tables)
  loop
    execute format('alter table %s enable trigger %I', v_trg.tbl, v_trg.tgname);
  end loop;

  -- The accounts stay, with their agreement and onboarding cleared (their signatures are history).
  update public.accounts
     set agreement_signed_at = null, onboarding_done_at = null, onboarding_step = null, onboarding_card = 0;

  insert into public.prelaunch_resets (backup_run_id, cleared) values (v_backup.id, v_cleared);

  return 'Test history cleared: ' || v_total || ' rows from ' || array_length(v_tables, 1)
         || ' tables. Every account, rate, setting and price is kept, and every balance is now $0.00.';
end;
$$;
comment on function public.prelaunch_reset(text) is
  'Database owner only (SQL Editor). Clears the beta''s history after a fresh backup; keeps accounts and configuration; refuses once launched_at is set.';
revoke all on function private.prelaunch_tables() from public, anon, authenticated, service_role;
revoke all on function public.prelaunch_reset(text) from public, anon, authenticated, service_role, backup_reader;

-- 6. After a restore into a new project ---------------------------------------------------------------

-- The dump holds the girls' data and every function, but not what lives in Supabase's
-- own schemas: the login guard on auth.users, the nightly timer (pg_cron) and Vault.
-- This puts the first two back and makes a new login key, then says what's left for
-- Dad. Safe to run again: it only does what's missing.
create function public.after_restore()
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
end;
$$;
comment on function public.after_restore() is
  'Database owner only, after restoring a backup into a new project: puts back the login guard and the nightly timer, makes a new login key, and says what''s left.';
revoke all on function public.after_restore() from public, anon, authenticated, service_role, backup_reader;
