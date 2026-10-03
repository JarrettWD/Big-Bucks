-- Stage 6: logins.
--
-- Server-only functions (the service role) for:
--   * the setup script and the demo: create_kid_account, create_parent_profile;
--   * the kid-login Edge Function: login_precheck, record_login_attempt.
-- Nothing here is callable from the app itself.
--
-- The PIN lockout (Build decisions → Writes, security and logins): 5 wrong PINs
-- in a row lock that username for 15 minutes and alert Dad. A right PIN resets
-- the count; so does the end of a lockout. While locked, nothing is checked or
-- recorded, so a locked username can't be brute-forced. Unknown usernames and
-- the parent's username count and lock exactly like a kid's, so the PIN door
-- never reveals which usernames exist.

-- Usernames are compared lowercase, trimmed and at most 40 characters.
create function public.login_username(p_username text)
returns text
language sql immutable
set search_path = ''
as $$
  select left(lower(btrim(coalesce(p_username, ''))), 40);
$$;

-- The lock in force on a username right now, or null.
create function public.login_locked_until(p_username text)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select la.locked_until
    from public.login_attempts la
   where la.username = p_username and la.locked_until is not null
   order by la.id desc
   limit 1;
$$;

-- Creating accounts -----------------------------------------------------------------------------

-- A kid: her account (named with her display name) and her profile, linked to an
-- Auth login the setup script has just created. Returns her account id.
create function public.create_kid_account(p_user_id uuid, p_username text, p_display_name text, p_is_test boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text := btrim(coalesce(p_username, ''));
  v_name text := btrim(coalesce(p_display_name, ''));
  v_account uuid;
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'There''s no login with that id.';
  end if;
  if exists (select 1 from public.profiles p where p.user_id = p_user_id) then
    raise exception 'That login already has a profile.';
  end if;
  if v_username !~ '^[a-z0-9_]{3,30}$' then
    raise exception 'A username is 3 to 30 lowercase letters, numbers or _.';
  end if;
  if exists (select 1 from public.profiles p where p.username = v_username) then
    raise exception 'The username "%" is already taken.', v_username;
  end if;
  if v_name = '' then
    raise exception 'A display name can''t be empty.';
  end if;

  insert into public.accounts (name, is_test) values (v_name, coalesce(p_is_test, false))
    returning id into v_account;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (p_user_id, 'investor', v_account, v_username, v_name);
  return v_account;
end;
$$;

-- A parent: a profile with no account (the parent sees every account).
create function public.create_parent_profile(p_user_id uuid, p_username text, p_display_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text := btrim(coalesce(p_username, ''));
  v_name text := btrim(coalesce(p_display_name, ''));
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'There''s no login with that id.';
  end if;
  if exists (select 1 from public.profiles p where p.user_id = p_user_id) then
    raise exception 'That login already has a profile.';
  end if;
  if v_username !~ '^[a-z0-9_]{3,30}$' then
    raise exception 'A username is 3 to 30 lowercase letters, numbers or _.';
  end if;
  if exists (select 1 from public.profiles p where p.username = v_username) then
    raise exception 'The username "%" is already taken.', v_username;
  end if;
  if v_name = '' then
    raise exception 'A display name can''t be empty.';
  end if;

  insert into public.profiles (user_id, role, username, display_name)
    values (p_user_id, 'parent', v_username, v_name);
end;
$$;

-- The kid-login door ------------------------------------------------------------------------------

-- Before trying a PIN: is this a kid's username, what is her hidden email, and
-- is it locked? Parents and unknown usernames get no email.
create function public.login_precheck(p_username text)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_username text := public.login_username(p_username);
  v_email text;
  v_locked timestamptz := public.login_locked_until(v_username);
begin
  select u.email into v_email
    from public.profiles p join auth.users u on u.id = p.user_id
   where p.username = v_username and p.role = 'investor';
  return jsonb_build_object(
    'is_kid', v_email is not null,
    'email', v_email,
    'locked_until', case when v_locked > public.app_now() then v_locked end);
end;
$$;

-- After trying a PIN: record it and apply the lockout. Returns the lock (if any)
-- and how many tries are left before one. While locked, nothing is recorded and
-- the answer is always "locked", even for a right PIN.
create function public.record_login_attempt(p_username text, p_succeeded boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text := public.login_username(p_username);
  v_now timestamptz := public.app_now();
  v_locked timestamptz;
  v_kid record;
  v_after bigint;
  v_fails int;
  v_until timestamptz;
begin
  if v_username = '' then
    raise exception 'A username is needed.';
  end if;
  -- One at a time per username, so two quick tries can't both slip under the limit.
  perform pg_advisory_xact_lock(hashtext('login:' || v_username));

  v_locked := public.login_locked_until(v_username);
  if v_locked > v_now then
    return jsonb_build_object('locked_until', v_locked, 'tries_left', 0);
  end if;

  select p.user_id, p.account_id, p.display_name, a.is_test into v_kid
    from public.profiles p join public.accounts a on a.id = p.account_id
   where p.username = v_username and p.role = 'investor';

  if p_succeeded then
    insert into public.login_attempts (username, user_id, succeeded) values (v_username, v_kid.user_id, true);
    return jsonb_build_object('locked_until', null, 'tries_left', 5);
  end if;

  -- Failures in a row: those after the last success or the last lockout.
  select coalesce(max(la.id), 0) into v_after
    from public.login_attempts la
   where la.username = v_username and (la.succeeded or la.locked_until is not null);
  select count(*) + 1 into v_fails
    from public.login_attempts la
   where la.username = v_username and la.id > v_after and not la.succeeded;

  if v_fails >= 5 then
    v_until := v_now + interval '15 minutes';
  end if;
  insert into public.login_attempts (username, user_id, succeeded, locked_until)
    values (v_username, v_kid.user_id, false, v_until);

  if v_until is not null then
    insert into public.alerts (kind, account_id, is_quiet, message, details)
    values ('lockout', v_kid.account_id, coalesce(v_kid.is_test, false),
            case when v_kid.account_id is not null
              then format('%s''s login is locked for 15 minutes after 5 wrong PINs in a row.', v_kid.display_name)
              else format('Someone typed 5 wrong PINs in a row for the username "%s", which isn''t a kid''s login. It''s locked for 15 minutes.', v_username)
            end,
            jsonb_build_object('username', v_username, 'locked_until', v_until));
  end if;

  return jsonb_build_object('locked_until', v_until, 'tries_left', greatest(5 - v_fails, 0));
end;
$$;

-- Who may call them: the server only. The two internal helpers get no grant.
revoke all on function public.login_username(text) from public, anon, authenticated, service_role;
revoke all on function public.login_locked_until(text) from public, anon, authenticated, service_role;
revoke all on function public.create_kid_account(uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.create_parent_profile(uuid, text, text) from public, anon, authenticated;
revoke all on function public.login_precheck(text) from public, anon, authenticated;
revoke all on function public.record_login_attempt(text, boolean) from public, anon, authenticated;
grant execute on function public.create_kid_account(uuid, text, text, boolean) to service_role;
grant execute on function public.create_parent_profile(uuid, text, text) to service_role;
grant execute on function public.login_precheck(text) to service_role;
grant execute on function public.record_login_attempt(text, boolean) to service_role;
