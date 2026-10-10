-- Stage 4, step 1, second round (second audit, 2026-10-08; Dad's review). The kid login.
--
-- 1. Lockouts escalate and can't be reset by someone else's success:
--    * A device's count of wrong PINs in a row is reset only by a right PIN on that
--      same device (before, any success reset every device's count).
--    * The username-wide count is every wrong PIN in the last 24 hours (since the
--      last lock for everyone), whatever device it came from; a right PIN doesn't
--      reset it. 20 lock the username for everyone.
--    * A lock lasts 15 minutes; the second of the same kind within 24 hours lasts an
--      hour; the third and later, 24 hours.
-- 2. PIN reset (Dad's decision): reset_kid_pin (Dad, authenticator code, logged,
--    with a notice to her) makes a one-time 6-digit code that Dad gives her. Her
--    old PIN stops working at once and she is signed out on every device. At her
--    next sign-in she types the code, then chooses a new PIN (kid-login:
--    check_pin_reset_code, finish_pin_reset). The code lasts 7 days, and wrong
--    codes count as wrong PINs in the lockout. set_kid_pin is the setup script's
--    way (server only).
-- 3. new_kid_login_key (database owner only): a new login key, for when the old one
--    is lost (for example a restore into a new project). Every kid then needs a PIN
--    reset (docs/RUNBOOK.md).

create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;

-- 1. Escalating lockouts -----------------------------------------------------------------------------

-- How long the next lock of this kind lasts.
create function public.login_lock_length(p_username text, p_client text, p_scope text)
returns interval
language sql stable
set search_path = ''
as $$
  select case count(*) when 0 then interval '15 minutes' when 1 then interval '1 hour' else interval '24 hours' end
    from public.login_attempts la
   where la.username = p_username and la.lock_scope = p_scope
     and (p_scope = 'username' or la.client = p_client)
     and la.attempted_at > public.app_now() - interval '24 hours';
$$;

-- In words, for Dad's alert.
create function public.lock_length_words(p interval)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p >= interval '24 hours' then '24 hours' when p >= interval '1 hour' then 'an hour'
              else '15 minutes' end;
$$;

create or replace function public.record_login_attempt(p_username text, p_succeeded boolean, p_client text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text := public.login_username(p_username);
  v_client text := public.login_client(p_client);
  v_now timestamptz := public.app_now();
  v_locked timestamptz;
  v_kid record;
  v_after bigint;
  v_since timestamptz;
  v_fails int;
  v_all_fails int;
  v_scope text;
  v_length interval;
  v_until timestamptz;
  v_known boolean;
begin
  if v_username = '' then
    raise exception 'A username is needed.';
  end if;
  -- One at a time per username, so two quick tries can't both slip under the limit.
  perform pg_advisory_xact_lock(hashtext('login:' || v_username));

  -- Old attempts aren't needed: the counts look back at most 24 hours.
  delete from public.login_attempts la where la.attempted_at < v_now - interval '30 days';

  v_locked := public.login_locked_until(v_username, v_client);
  if v_locked > v_now then
    return jsonb_build_object('locked_until', v_locked, 'tries_left', 0);
  end if;

  select p.user_id, p.account_id, p.display_name, a.is_test into v_kid
    from public.profiles p join public.accounts a on a.id = p.account_id
   where p.username = v_username and p.role = 'investor';
  v_known := v_kid.account_id is not null;

  if p_succeeded then
    insert into public.login_attempts (username, user_id, succeeded, client)
    values (v_username, v_kid.user_id, true, v_client);
    return jsonb_build_object('locked_until', null, 'tries_left', 5);
  end if;

  -- This device's wrong PINs in a row: since its last right PIN or lock, or the last lock for everyone.
  select coalesce(max(la.id), 0) into v_after
    from public.login_attempts la
   where la.username = v_username
     and (la.lock_scope = 'username' or (la.client = v_client and (la.succeeded or la.lock_scope = 'device')));
  select count(*) + 1 into v_fails
    from public.login_attempts la
   where la.username = v_username and la.client = v_client and la.id > v_after and not la.succeeded;

  -- Every wrong PIN for this username in the last 24 hours, since the last lock for everyone.
  select greatest(v_now - interval '24 hours',
                  coalesce(max(la.attempted_at) filter (where la.lock_scope = 'username'), '-infinity'))
    into v_since
    from public.login_attempts la where la.username = v_username;
  select count(*) + 1 into v_all_fails
    from public.login_attempts la
   where la.username = v_username and not la.succeeded and la.attempted_at > v_since;

  if v_all_fails >= 20 then
    v_scope := 'username';
  elsif v_fails >= 5 then
    v_scope := 'device';
  end if;
  if v_scope is not null then
    v_length := public.login_lock_length(v_username, v_client, v_scope);
    v_until := v_now + v_length;
  end if;
  insert into public.login_attempts (username, user_id, succeeded, locked_until, lock_scope, client)
    values (v_username, v_kid.user_id, false, v_until, v_scope, v_client);

  -- One open alert per username; usernames that aren't a kid's share one quiet alert.
  if v_scope is not null and not exists (
       select 1 from public.alerts al
        where al.kind = 'lockout' and al.resolved_at is null
          and case when v_known then al.details ->> 'username' = v_username
                   else al.details ->> 'not_a_kid' = 'true' end) then
    insert into public.alerts (kind, account_id, is_quiet, message, details)
    values ('lockout', v_kid.account_id, not v_known or v_kid.is_test,
            case when not v_known
              then 'Someone typed wrong PINs for a username that isn''t a kid''s login (' || v_username
                   || '). Nothing to do: there''s no account behind it.'
              when v_scope = 'username'
              then format('%s''s login is locked for %s: 20 wrong PINs in a day, from more than one device.',
                          v_kid.display_name, public.lock_length_words(v_length))
              else format('%s''s login is locked for %s on one device after 5 wrong PINs in a row.',
                          v_kid.display_name, public.lock_length_words(v_length))
            end,
            jsonb_build_object('username', v_username, 'locked_until', v_until, 'scope', v_scope,
                               'not_a_kid', not v_known));
  end if;

  return jsonb_build_object('locked_until', v_until, 'tries_left', greatest(5 - v_fails, 0));
end;
$$;

-- 2. PIN reset ------------------------------------------------------------------------------------------

create table private.kid_pin_resets (
  account_id  uuid primary key references public.accounts (id),
  code_hash   text not null,
  created_at  timestamptz not null default public.app_now(),
  expires_at  timestamptz not null,
  created_by  uuid
);

-- The only way a kid's password changes: these functions turn this on for themselves.
create or replace function public.protect_kid_login()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.encrypted_password is distinct from old.encrypted_password or new.email is distinct from old.email)
     and exists (select 1 from public.profiles p where p.user_id = old.id and p.role = 'investor')
     and not (coalesce(current_setting('bigbucks.kid_pin_change', true), '') = 'on'
              and new.email is not distinct from old.email) then
    raise exception 'A kid''s PIN and login can''t be changed from the app.' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- Internal: sets her Supabase Auth password (bcrypt, as Supabase Auth stores it).
create function public.write_kid_password(p_user_id uuid, p_password text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('bigbucks.kid_pin_change', 'on', true);
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf', 10))
   where id = p_user_id;
  perform set_config('bigbucks.kid_pin_change', '', true);
end;
$$;

-- Dad resets her PIN. Returns the one-time code to give her (shown once, never stored).
create function public.reset_kid_pin(p_account_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kid record;
  v_code text;
  v_b bytea := extensions.gen_random_bytes(4);
begin
  perform public.require_parent();
  select p.user_id, a.name into v_kid
    from public.profiles p join public.accounts a on a.id = p.account_id
   where p.account_id = p_account_id and p.role = 'investor';
  if not found then
    raise exception 'There''s no such kid''s login.';
  end if;

  -- A random 6-digit code (4 random bytes, 0 to 4,294,967,295, mod 1,000,000).
  v_code := lpad((((get_byte(v_b, 0)::bigint << 24) | (get_byte(v_b, 1) << 16) | (get_byte(v_b, 2) << 8)
                   | get_byte(v_b, 3)) % 1000000)::text, 6, '0');
  insert into private.kid_pin_resets (account_id, code_hash, expires_at, created_by)
  values (p_account_id, public.kid_auth_password(v_kid.user_id, v_code), public.app_now() + interval '7 days', auth.uid())
  on conflict (account_id) do update
    set code_hash = excluded.code_hash, created_at = excluded.created_at, expires_at = excluded.expires_at,
        created_by = excluded.created_by;
  -- Her old PIN stops working, and she is signed out everywhere.
  perform public.write_kid_password(v_kid.user_id, encode(extensions.gen_random_bytes(32), 'hex'));
  delete from auth.sessions s where s.user_id = v_kid.user_id;

  perform public.notify(p_account_id, 'request', 'Dad reset your PIN',
    'Next time you sign in, type the code Dad gives you instead of your PIN. Then you''ll choose a new PIN.',
    'pin_reset:' || p_account_id || ':' || extract(epoch from public.app_now())::bigint);
  perform public.log_parent_action('reset_kid_pin', p_account_id, null,
    'Reset ' || v_kid.name || '''s PIN. She chooses a new one at her next sign-in.', '{}'::jsonb);
  return v_code;
end;
$$;

-- kid-login: is a reset waiting for her, and is this her code?
create function public.check_pin_reset_code(p_user_id uuid, p_code text)
returns boolean
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if coalesce(p_code, '') !~ '^\d{6}$' then
    return false;
  end if;
  return exists (select 1 from private.kid_pin_resets r join public.profiles p on p.account_id = r.account_id
                  where p.user_id = p_user_id and r.expires_at > public.app_now()
                    and r.code_hash = public.kid_auth_password(p_user_id, p_code));
end;
$$;

-- kid-login: she typed her code and chose a new PIN.
create function public.finish_pin_reset(p_user_id uuid, p_code text, p_new_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := (select p.account_id from public.profiles p where p.user_id = p_user_id and p.role = 'investor');
begin
  if not public.check_pin_reset_code(p_user_id, p_code) then
    raise exception 'That code didn''t match.';
  end if;
  if coalesce(p_new_pin, '') !~ '^\d{6}$' then
    raise exception 'A PIN is exactly 6 digits.';
  end if;
  if p_new_pin = p_code then
    raise exception 'Choose a new PIN, not Dad''s code.';
  end if;
  perform public.write_kid_password(p_user_id, public.kid_auth_password(p_user_id, p_new_pin));
  delete from private.kid_pin_resets r where r.account_id = v_account;
end;
$$;

-- The setup script (server only): set a kid's PIN directly.
create function public.set_kid_pin(p_username text, p_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kid record;
begin
  select p.user_id, p.account_id into v_kid from public.profiles p
   where p.username = public.login_username(p_username) and p.role = 'investor';
  if not found then
    raise exception 'There''s no kid with that username.';
  end if;
  perform public.write_kid_password(v_kid.user_id, public.kid_auth_password(v_kid.user_id, p_pin));
  delete from private.kid_pin_resets r where r.account_id = v_kid.account_id;
end;
$$;

-- The lookup also says whether a PIN reset is waiting.
create or replace function public.login_precheck(p_username text, p_client text default null)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_username text := public.login_username(p_username);
  v_user uuid;
  v_account uuid;
  v_email text;
  v_locked timestamptz := public.login_locked_until(v_username, public.login_client(p_client));
begin
  select u.id, u.email, p.account_id into v_user, v_email, v_account
    from public.profiles p join auth.users u on u.id = p.user_id
   where p.username = v_username and p.role = 'investor';
  return jsonb_build_object(
    'is_kid', v_email is not null,
    'user_id', v_user,
    'email', v_email,
    'reset_pending', exists (select 1 from private.kid_pin_resets r
                              where r.account_id = v_account and r.expires_at > public.app_now()),
    'locked_until', case when v_locked > public.app_now() then v_locked end);
end;
$$;

-- Dad's list for Settings → Logins.
create function public.parent_logins()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'account_id', a.id, 'name', a.name, 'is_test', a.is_test, 'username', p.username,
             'reset_pending', r.account_id is not null and r.expires_at > public.app_now(),
             'reset_expires', case when r.expires_at > public.app_now() then public.fmt_date(public.edmonton_local(r.expires_at)::date) end)
           order by a.is_test, a.name)
      from public.accounts a
      join public.profiles p on p.account_id = a.id and p.role = 'investor'
      left join private.kid_pin_resets r on r.account_id = a.id), '[]'::jsonb);
end;
$$;

-- 3. A new login key ----------------------------------------------------------------------------------

create function public.new_kid_login_key()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := (select s.id from vault.secrets s where s.name = 'kid_login_key');
begin
  if v_id is null then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'kid_login_key',
      'Big Bucks: turns a kid''s PIN into her Supabase Auth password, and hashes login IP addresses.');
  else
    perform vault.update_secret(v_id, encode(extensions.gen_random_bytes(32), 'hex'));
  end if;
  return 'A new login key is in place. Every kid''s PIN now needs a reset (Settings → Logins).';
end;
$$;

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement', 'correct_fund_price', 'record_market_closure',
                    'reset_kid_pin', 'record_early_close'));

revoke all on all tables in schema private from public, anon, authenticated, service_role;
revoke all on function public.login_lock_length(text, text, text) from public, anon, authenticated, service_role;
revoke all on function public.lock_length_words(interval) from public, anon, authenticated, service_role;
revoke all on function public.write_kid_password(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.new_kid_login_key() from public, anon, authenticated, service_role;
revoke all on function public.reset_kid_pin(uuid) from public, anon, authenticated, service_role;
revoke all on function public.parent_logins() from public, anon, authenticated, service_role;
revoke all on function public.check_pin_reset_code(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.finish_pin_reset(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.set_kid_pin(text, text) from public, anon, authenticated, service_role;
revoke all on function public.login_precheck(text, text) from public, anon, authenticated, service_role;
revoke all on function public.record_login_attempt(text, boolean, text) from public, anon, authenticated, service_role;
grant execute on function public.reset_kid_pin(uuid) to authenticated;
grant execute on function public.parent_logins() to authenticated;
grant execute on function public.check_pin_reset_code(uuid, text) to service_role;
grant execute on function public.finish_pin_reset(uuid, text, text) to service_role;
grant execute on function public.set_kid_pin(text, text) to service_role;
grant execute on function public.login_precheck(text, text) to service_role;
grant execute on function public.record_login_attempt(text, boolean, text) to service_role;
