-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). The kid login.
--
-- 1. Her Supabase Auth password is no longer her PIN (audit: must fix). Anyone
--    with the app's public key could otherwise guess PINs straight against
--    Supabase Auth, skipping kid-login and its lockout. Her password is now an
--    HMAC of her login id and PIN, keyed by a secret kept in Supabase Vault, so
--    only the server (kid-login and the setup script, through
--    kid_auth_password) can turn a PIN into her password. Her hidden email is
--    random too (the scripts choose it), never worked out from her username.
-- 2. The lockout counts per device as well as per username (audit: should fix).
--    5 wrong PINs in a row from one device lock that device out of that
--    username for 15 minutes, so a stranger can't keep her locked out. 20 wrong
--    PINs in a row from any mix of devices lock the username for everyone for 15
--    minutes, so spreading guesses over many devices doesn't help either.
--    Devices are told apart by a keyed hash of their IP address; the address
--    itself is never stored.
-- 3. Alerts don't pile up: one open lockout alert per username, and attempts on
--    usernames that aren't a kid's (unknown names, or the parent's) are logged
--    quietly in a single open alert. Attempts older than 30 days are deleted.
-- 4. A kid can't change her own password or email (audit: should fix). A
--    trigger on auth.users refuses it, whoever asks.

-- 1. The key, and her password from her PIN ------------------------------------------------------

select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'kid_login_key',
  'Big Bucks: turns a kid''s PIN into her Supabase Auth password, and hashes login IP addresses.');

-- Internal: the key as bytes.
create function public.kid_login_key()
returns bytea
language sql stable
security definer
set search_path = ''
as $$
  select decode(s.decrypted_secret, 'hex') from vault.decrypted_secrets s where s.name = 'kid_login_key';
$$;

-- Her Supabase Auth password: HMAC-SHA256(login id : PIN). Server only.
create function public.kid_auth_password(p_user_id uuid, p_pin text)
returns text
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_key bytea := public.kid_login_key();
begin
  if p_user_id is null or coalesce(p_pin, '') !~ '^\d{6}$' then
    raise exception 'A PIN is exactly 6 digits.';
  end if;
  if v_key is null then
    raise exception 'The kid login key is missing from Vault.';
  end if;
  return encode(extensions.hmac(convert_to('pin:' || p_user_id || ':' || p_pin, 'UTF8'), v_key, 'sha256'), 'hex');
end;
$$;
comment on function public.kid_auth_password(uuid, text) is
  'A kid''s Supabase Auth password, worked out from her login id and PIN with a key kept in Vault. Server only.';

-- Internal: a device's label, a keyed hash of its IP address ('' when unknown).
create function public.login_client(p_client text)
returns text
language sql stable
security definer
set search_path = ''
as $$
  select case when btrim(coalesce(p_client, '')) = '' then ''
              else left(encode(extensions.hmac(convert_to('ip:' || btrim(p_client), 'UTF8'),
                                               public.kid_login_key(), 'sha256'), 'hex'), 16) end;
$$;

-- 2. The lockout, per device and per username ----------------------------------------------------

alter table public.login_attempts
  add column client text not null default '',
  add column lock_scope text check (lock_scope in ('device', 'username'));
update public.login_attempts set lock_scope = 'username' where locked_until is not null;
alter table public.login_attempts
  add constraint login_attempts_lock_has_scope check ((locked_until is null) = (lock_scope is null));
comment on column public.login_attempts.client is
  'The device: a keyed hash of its IP address, never the address itself ('''' when unknown).';
comment on column public.login_attempts.lock_scope is
  'device: this device is locked out of this username. username: the username is locked for everyone.';
create index login_attempts_username_client_idx on public.login_attempts (username, client, id desc);
create index login_attempts_attempted_at_idx on public.login_attempts (attempted_at);

drop function public.login_precheck(text);
drop function public.record_login_attempt(text, boolean);
drop function public.login_locked_until(text);

-- The lock in force on this username for this device (already hashed), or null.
create function public.login_locked_until(p_username text, p_client text)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select max(x.until) from (
    (select la.locked_until as until from public.login_attempts la
      where la.username = p_username and la.lock_scope = 'username'
      order by la.id desc limit 1)
    union all
    (select la.locked_until from public.login_attempts la
      where la.username = p_username and la.client = p_client and la.lock_scope = 'device'
      order by la.id desc limit 1)) x;
$$;

-- Before trying a PIN: is this a kid's username, her login id and hidden email,
-- and is it locked for this device? Parents and unknown usernames get no email.
create function public.login_precheck(p_username text, p_client text default null)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_username text := public.login_username(p_username);
  v_user uuid;
  v_email text;
  v_locked timestamptz := public.login_locked_until(v_username, public.login_client(p_client));
begin
  select u.id, u.email into v_user, v_email
    from public.profiles p join auth.users u on u.id = p.user_id
   where p.username = v_username and p.role = 'investor';
  return jsonb_build_object(
    'is_kid', v_email is not null,
    'user_id', v_user,
    'email', v_email,
    'locked_until', case when v_locked > public.app_now() then v_locked end);
end;
$$;

-- After trying a PIN: record it and apply the lockout. Returns the lock (if any)
-- and how many tries this device has left before one. While locked, nothing is
-- recorded and the answer is always "locked", even for a right PIN.
create function public.record_login_attempt(p_username text, p_succeeded boolean, p_client text default null)
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
  v_fails int;
  v_all_fails int;
  v_scope text;
  v_until timestamptz;
  v_known boolean;
begin
  if v_username = '' then
    raise exception 'A username is needed.';
  end if;
  -- One at a time per username, so two quick tries can't both slip under the limit.
  perform pg_advisory_xact_lock(hashtext('login:' || v_username));

  -- Old attempts aren't needed: the counts only look back to the last success or lock.
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

  -- This device's failures in a row: after the last success, or this device's last lock, or the
  -- last lock for everyone.
  select coalesce(max(la.id), 0) into v_after
    from public.login_attempts la
   where la.username = v_username
     and (la.succeeded or la.lock_scope = 'username' or (la.lock_scope = 'device' and la.client = v_client));
  select count(*) + 1 into v_fails
    from public.login_attempts la
   where la.username = v_username and la.client = v_client and la.id > v_after and not la.succeeded;

  -- Every device's failures in a row: after the last success or the last lock for everyone.
  select coalesce(max(la.id), 0) into v_after
    from public.login_attempts la
   where la.username = v_username and (la.succeeded or la.lock_scope = 'username');
  select count(*) + 1 into v_all_fails
    from public.login_attempts la
   where la.username = v_username and la.id > v_after and not la.succeeded;

  if v_all_fails >= 20 then
    v_scope := 'username';
  elsif v_fails >= 5 then
    v_scope := 'device';
  end if;
  if v_scope is not null then
    v_until := v_now + interval '15 minutes';
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
              then format('%s''s login is locked for 15 minutes: 20 wrong PINs in a row, from more than one device.',
                          v_kid.display_name)
              else format('%s''s login is locked for 15 minutes on one device after 5 wrong PINs in a row.',
                          v_kid.display_name)
            end,
            jsonb_build_object('username', v_username, 'locked_until', v_until, 'scope', v_scope,
                               'not_a_kid', not v_known));
  end if;

  return jsonb_build_object('locked_until', v_until, 'tries_left', greatest(5 - v_fails, 0));
end;
$$;

-- 3. A kid's password and email change only through the server ------------------------------------

-- Supabase Auth would let a signed-in kid change her own password or email. Her
-- password is worked out from her PIN on the server, and her email is hidden, so
-- neither may change that way: whoever asks, the change is refused.
create function public.protect_kid_login()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.encrypted_password is distinct from old.encrypted_password or new.email is distinct from old.email)
     and exists (select 1 from public.profiles p where p.user_id = old.id and p.role = 'investor') then
    raise exception 'A kid''s PIN and login can''t be changed from the app.' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger protect_kid_login before update on auth.users
  for each row execute function public.protect_kid_login();

-- Who may call what: the server only. The helpers get no grant.
revoke all on function public.kid_login_key() from public, anon, authenticated, service_role;
revoke all on function public.login_client(text) from public, anon, authenticated, service_role;
revoke all on function public.login_locked_until(text, text) from public, anon, authenticated, service_role;
revoke all on function public.protect_kid_login() from public, anon, authenticated, service_role;
revoke all on function public.kid_auth_password(uuid, text) from public, anon, authenticated;
revoke all on function public.login_precheck(text, text) from public, anon, authenticated;
revoke all on function public.record_login_attempt(text, boolean, text) from public, anon, authenticated;
grant execute on function public.kid_auth_password(uuid, text) to service_role;
grant execute on function public.login_precheck(text, text) to service_role;
grant execute on function public.record_login_attempt(text, boolean, text) to service_role;
