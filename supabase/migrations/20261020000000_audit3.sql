-- Stage 4, step 1, third round (third audit, 2026-10-09; Dad's review).
--
-- 1. A session that was ended stops working at once: my_account_id(), is_parent() and
--    kid_account() check that the token's session still exists (session_alive). Before,
--    a PIN reset deleted her sessions but an already-issued token kept working until it
--    ran out (up to an hour).
-- 2. A PIN reset (app or setup script) clears her lockouts and resolves the lockout
--    alert, so the reset isn't held up by a lock she caused herself.
-- 4. set_kid_pin (the setup script) also signs her out everywhere.
-- Minor items:
--   * lockouts escalate over 7 days (a lock after a 24-hour lock is 24 hours again);
--     the open lockout alert always shows the latest lock;
--   * PIN-reset codes are hashed with their own prefix (pin_reset_code_hash);
--   * Settings → Logins shows a reset code that ran out (reset_expired);
--   * recording a closure or an early close takes the same per-fund, per-day lock as
--     settlement and price fixes; a closure keeps an official holiday row's source;
--   * private.kid_pin_resets has row-level security on (nothing reads it but the
--     server functions that own it);
--   * approving needs her signature; before Dad signs her first agreement, one first
--     deposit at a time;
--   * mark_production() dates its rows by the app clock.

create function public.session_alive()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- Tokens from Supabase Auth carry their session's id. If that session has been
  -- ended (a PIN reset signs her out everywhere), the token counts as nobody's, even
  -- before it runs out. Calls without a session id (the server, the tests) pass.
  select coalesce(auth.jwt() ->> 'session_id', '') = ''
      or exists (select 1 from auth.sessions s where s.id = (auth.jwt() ->> 'session_id')::uuid);
$$;

CREATE OR REPLACE FUNCTION public.my_account_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.account_id
    from public.profiles p
   where p.user_id = auth.uid() and public.session_alive();
$function$;

CREATE OR REPLACE FUNCTION public.is_parent()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select p.role = 'parent'
       from public.profiles p
      where p.user_id = auth.uid())
    and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
    and public.session_alive(),
    false);
$function$;

CREATE OR REPLACE FUNCTION public.kid_account()
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_account uuid := public.my_account_id();
begin
  if not public.session_alive() then
    raise exception 'You were signed out. Please sign in again.' using errcode = '42501';
  end if;
  if v_account is null then
    raise exception 'Only a kid''s account can do this.' using errcode = '42501';
  end if;
  perform 1 from public.accounts a where a.id = v_account for update;
  return v_account;
end;
$function$;

-- The stored form of a PIN-reset code: keyed like her password, but with its own
-- prefix, so a code's hash can never be mistaken for a password (third audit).
create function public.pin_reset_code_hash(p_user_id uuid, p_code text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(extensions.hmac(convert_to('reset:' || p_user_id || ':' || p_code, 'UTF8'),
                                public.kid_login_key(), 'sha256'), 'hex');
$$;

-- Clears every lock and wrong-PIN count for her username, so the reset isn't held up by
-- a lockout she caused while trying to remember her PIN.
create function public.clear_kid_lockouts(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.login_attempts la
   where la.username = (select p.username from public.profiles p where p.user_id = p_user_id);
  update public.alerts al set resolved_at = public.app_now()
   where al.kind = 'lockout' and al.resolved_at is null
     and al.details ->> 'username' = (select p.username from public.profiles p where p.user_id = p_user_id);
$$;

CREATE OR REPLACE FUNCTION public.reset_kid_pin(p_account_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  values (p_account_id, public.pin_reset_code_hash(v_kid.user_id, v_code), public.app_now() + interval '7 days', auth.uid())
  on conflict (account_id) do update
    set code_hash = excluded.code_hash, created_at = excluded.created_at, expires_at = excluded.expires_at,
        created_by = excluded.created_by;
  -- Her old PIN stops working, and she is signed out everywhere.
  perform public.write_kid_password(v_kid.user_id, encode(extensions.gen_random_bytes(32), 'hex'));
  delete from auth.sessions s where s.user_id = v_kid.user_id;
  perform public.clear_kid_lockouts(v_kid.user_id);

  perform public.notify(p_account_id, 'request', 'Dad reset your PIN',
    'Next time you sign in, type the code Dad gives you instead of your PIN. Then you''ll choose a new PIN.',
    'pin_reset:' || p_account_id || ':' || extract(epoch from public.app_now())::bigint);
  perform public.log_parent_action('reset_kid_pin', p_account_id, null,
    'Reset ' || v_kid.name || '''s PIN. She chooses a new one at her next sign-in.', '{}'::jsonb);
  return v_code;
end;
$function$;

CREATE OR REPLACE FUNCTION public.check_pin_reset_code(p_user_id uuid, p_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if coalesce(p_code, '') !~ '^\d{6}$' then
    return false;
  end if;
  return exists (select 1 from private.kid_pin_resets r join public.profiles p on p.account_id = r.account_id
                  where p.user_id = p_user_id and r.expires_at > public.app_now()
                    and r.code_hash = public.pin_reset_code_hash(p_user_id, p_code));
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_kid_pin(p_username text, p_pin text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- Like a reset in the app: signed out everywhere, and no lockout left over.
  delete from auth.sessions s where s.user_id = v_kid.user_id;
  perform public.clear_kid_lockouts(v_kid.user_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.parent_logins()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_parent();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'account_id', a.id, 'name', a.name, 'is_test', a.is_test, 'username', p.username,
             'reset_pending', r.account_id is not null and r.expires_at > public.app_now(),
             'reset_expires', case when r.expires_at > public.app_now() then public.fmt_date(public.edmonton_local(r.expires_at)::date) end,
             -- A code that ran out: her old PIN no longer works, so she needs another reset.
             'reset_expired', r.account_id is not null and r.expires_at <= public.app_now())
           order by a.is_test, a.name)
      from public.accounts a
      join public.profiles p on p.account_id = a.id and p.role = 'investor'
      left join private.kid_pin_resets r on r.account_id = a.id), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.login_lock_length(p_username text, p_client text, p_scope text)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case count(*) when 0 then interval '15 minutes' when 1 then interval '1 hour' else interval '24 hours' end
    from public.login_attempts la
   where la.username = p_username and la.lock_scope = p_scope
     and (p_scope = 'username' or la.client = p_client)
     and la.attempted_at > public.app_now() - interval '7 days';
$function$;

CREATE OR REPLACE FUNCTION public.record_login_attempt(p_username text, p_succeeded boolean, p_client text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- A new lock while it's open updates it, so it always says how long the latest lasts.
  if v_scope is not null and v_known then
    update public.alerts al
       set message = case when v_scope = 'username'
                        then format('%s''s login is locked for %s: 20 wrong PINs in a day, from more than one device.',
                                    v_kid.display_name, public.lock_length_words(v_length))
                        else format('%s''s login is locked for %s on one device after 5 wrong PINs in a row.',
                                    v_kid.display_name, public.lock_length_words(v_length)) end,
           details = al.details || jsonb_build_object('locked_until', v_until, 'scope', v_scope)
     where al.kind = 'lockout' and al.resolved_at is null and al.details ->> 'username' = v_username;
  end if;
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
$function$;

CREATE OR REPLACE FUNCTION public.record_market_closure(p_market market, p_date date, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_name text := case p_market when 'nyse' then 'New York Stock Exchange' else 'Toronto Stock Exchange' end;
  v_req record;
  v_n integer := 0;
  v_ids bigint[];
begin
  perform public.require_parent();
  -- Take turns with settlement and price fixes for this market's closes that day.
  perform pg_advisory_xact_lock(hashtext('close:' || f.id || ':' || p_date))
     from public.funds f where f.market = p_market order by f.id;
  if p_market is null or p_date is null then
    raise exception 'Choose the market and the day it was closed.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say why the market was closed (for example "National day of mourning").';
  end if;
  if p_date > public.app_today() + 366 then
    raise exception 'That''s more than a year away.';
  end if;
  if not public.is_trading_day(p_market, p_date) then
    raise exception 'The % already doesn''t trade on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.fund_prices fp join public.funds f on f.id = fp.fund_id
              where f.market = p_market and fp.price_date = p_date) then
    raise exception 'There''s already a close for % on %, so the market was open that day.',
      v_name, public.fmt_date(p_date);
  end if;

  -- A quarter's first trading day whose dividends are already paid can't become a
  -- closed day: those dividends would look misdated.
  if p_date = public.first_trading_day_from(p_market, date_trunc('quarter', p_date)::date)
     and exists (select 1 from public.transactions t join public.funds f on f.id = t.fund_id
                  where t.type = 'dividend' and f.market = p_market
                    and t.posting_key like 'dividend:' || to_char(p_date, 'YYYY') || 'Q'
                                           || extract(quarter from p_date) || ':%') then
    raise exception 'Dividends were already paid on %, so it can''t be marked closed.', public.fmt_date(p_date);
  end if;

  -- The trades that were waiting for that day's close, before it's marked closed.
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from public.requests r join public.funds f on f.id = r.fund_id
   where r.status = 'pending' and r.type = 'move' and f.market = p_market
     and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date = p_date;

  insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url)
  values (p_market, p_date, btrim(p_note), 'closed', null, true, 'Recorded by Dad in Big Bucks')
  on conflict (market, holiday_date) do update
    set name = excluded.name, kind = 'closed', closes_at = null;  -- an official row keeps its source

  -- They now wait for the next close. Each girl with one is told.
  for v_req in
    select r.id, r.account_id, r.from_vehicle, f.name as fund_name,
           public.next_close(f.market, r.created_at) as next_at
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.id = any (v_ids)
     order by r.id
  loop
    perform public.notify(v_req.account_id, 'request', 'The market was closed',
      'The ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ', so your ' || v_req.fund_name || ' '
        || case when v_req.from_vehicle = 'stock' then 'sale' else 'buy' end
        || ' will happen at the next close, on ' || public.fmt_date(public.edmonton_local(v_req.next_at)::date) || '.',
      'closure:' || p_market || ':' || p_date || ':' || v_req.id, p_request_id => v_req.id);
    v_n := v_n + 1;
  end loop;

  perform public.log_parent_action('record_market_closure', null, null,
    'Recorded that the ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ': ' || btrim(p_note) || '.',
    jsonb_build_object('market', p_market, 'date', p_date, 'note', btrim(p_note), 'trades_told', v_n));
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_early_close(p_market market, p_date date, p_closes_at time without time zone, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_name text := case p_market when 'nyse' then 'New York Stock Exchange' else 'Toronto Stock Exchange' end;
  v_req record;
  v_ids bigint[];
  v_n integer := 0;
begin
  perform public.require_parent();
  perform pg_advisory_xact_lock(hashtext('close:' || f.id || ':' || p_date))
     from public.funds f where f.market = p_market order by f.id;
  if p_market is null or p_date is null or p_closes_at is null then
    raise exception 'Choose the market, the day and the time it closed (Toronto time).';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say why the market closed early (for example "Systems outage").';
  end if;
  if p_closes_at <= time '09:30' or p_closes_at >= time '16:00' then
    raise exception 'An early close is between 9:30 am and 4:00 pm, Toronto time.';
  end if;
  if p_date > public.app_today() + 366 then
    raise exception 'That''s more than a year away.';
  end if;
  if not public.is_trading_day(p_market, p_date) then
    raise exception 'The % doesn''t trade on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.market_holidays h where h.market = p_market and h.holiday_date = p_date) then
    raise exception 'The % already has an early close on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.transactions t join public.funds f on f.id = t.fund_id
              where f.market = p_market and t.vehicle = 'stock' and t.unit_price is not null
                and t.effective_at = public.close_time(p_market, p_date)) then
    raise exception 'A trade already settled at that day''s usual close, so its close time can''t change.';
  end if;

  -- The trades waiting for that day's close, before the change.
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from public.requests r join public.funds f on f.id = r.fund_id
   where r.status = 'pending' and r.type = 'move' and f.market = p_market
     and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date = p_date;

  insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url)
  values (p_market, p_date, btrim(p_note), 'early_close', p_closes_at, true, 'Recorded by Dad in Big Bucks');

  -- Those asked for after the early close now wait for the next close. Each girl is told.
  for v_req in
    select r.id, r.account_id, r.from_vehicle, f.name as fund_name,
           public.next_close(f.market, r.created_at) as next_at
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.id = any (v_ids)
       and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date <> p_date
     order by r.id
  loop
    perform public.notify(v_req.account_id, 'request', 'The market closed early',
      'The ' || v_name || ' closed early on ' || public.fmt_date(p_date) || ', before your '
        || v_req.fund_name || ' ' || case when v_req.from_vehicle = 'stock' then 'sale' else 'buy' end
        || ' could happen. It will happen at the next close, on '
        || public.fmt_date(public.edmonton_local(v_req.next_at)::date) || '.',
      'early_close:' || p_market || ':' || p_date || ':' || v_req.id, p_request_id => v_req.id);
    v_n := v_n + 1;
  end loop;

  perform public.log_parent_action('record_early_close', null, null,
    'Recorded that the ' || v_name || ' closed early on ' || public.fmt_date(p_date) || ' at '
      || to_char(p_closes_at, 'FMHH12:MI am') || ' Toronto time: ' || btrim(p_note) || '.',
    jsonb_build_object('market', p_market, 'date', p_date, 'closes_at', p_closes_at, 'note', btrim(p_note),
                       'trades_told', v_n));
end;
$function$;

CREATE OR REPLACE FUNCTION public.approve_request(p_request_id bigint, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_req public.requests;
  v_name text;
  v_signed integer;
begin
  perform public.require_parent();
  select * into v_req from public.requests r where r.id = p_request_id;
  if found then
    select max(s.version) into v_signed from public.agreement_signatures s
     where s.account_id = v_req.account_id and s.signer = 'kid';
    if v_signed is null then
      select a.name into v_name from public.accounts a where a.id = v_req.account_id;
      raise exception '% hasn''t signed her Big Bucks agreement yet, so nothing can be approved.', v_name;
    end if;
    if not exists (
         select 1 from public.agreement_signatures p
          where p.account_id = v_req.account_id and p.version = v_signed and p.signer = 'parent') then
      select a.name into v_name from public.accounts a where a.id = v_req.account_id;
      raise exception '% signed her agreement and is waiting for you to sign it too. Sign it first (it''s at the top of Approvals), then approve this.',
        v_name;
    end if;
  end if;

  perform public.approve_request_unlogged(p_request_id, p_note);

  select * into v_req from public.requests r where r.id = p_request_id;
  perform public.log_parent_action('approve_request', v_req.account_id, v_req.id,
    'Approved ' || (select a.name from public.accounts a where a.id = v_req.account_id) || '''s '
      || public.fmt_money(v_req.amount_cents) || ' '
      || case v_req.type when 'deposit' then 'deposit' else 'withdrawal' end || '.',
    jsonb_build_object('type', v_req.type, 'amount_cents', v_req.amount_cents, 'note', v_req.parent_note));
end;
$function$;

CREATE OR REPLACE FUNCTION public.require_agreement(p_account uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_latest integer := (select max(v.version) from public.agreement_versions v);
  v_signed integer := (select max(s.version) from public.agreement_signatures s
                        where s.account_id = p_account and s.signer = 'kid');
  v_first boolean;
begin
  if v_latest is null then
    raise exception 'The Big Bucks agreement isn''t set up yet, so nothing can move.';
  end if;
  if v_signed is null then
    raise exception '%', case when p_kind = 'deposit'
                              then 'Before you can put money in, sign your Big Bucks agreement with Dad.'
                              else 'Sign your Big Bucks agreement with Dad first.' end;
  end if;
  -- Her first agreement: the only version she has signed, and no earlier one.
  v_first := not exists (select 1 from public.agreement_signatures s
                          where s.account_id = p_account and s.signer = 'kid' and s.version < v_signed);

  if p_kind = 'deposit' then
    if v_signed < v_latest then
      raise exception 'Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed.';
    end if;
    if not v_first and not exists (select 1 from public.agreement_signatures s
                                    where s.account_id = p_account and s.version = v_latest and s.signer = 'parent') then
      raise exception 'You signed the new agreement! New deposits wait until Dad signs it too.';
    end if;
    -- Her first agreement, before Dad signs: one first deposit at a time.
    if v_first and not exists (select 1 from public.agreement_signatures s
                                where s.account_id = p_account and s.version = v_signed and s.signer = 'parent')
       and exists (select 1 from public.requests r
                    where r.account_id = p_account and r.type = 'deposit' and r.status = 'pending') then
      raise exception 'Your first deposit is already waiting for Dad.';
    end if;
    return;
  end if;

  if not exists (select 1 from public.agreement_signatures k
                  join public.agreement_signatures p
                    on p.account_id = k.account_id and p.version = k.version and p.signer = 'parent'
                 where k.account_id = p_account and k.signer = 'kid') then
    raise exception 'Dad hasn''t signed your agreement yet. As soon as he does, this will work.';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.mark_production()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if exists (select 1 from public.settings s where s.key = 'is_production') then
    return 'Already marked as production.';
  end if;
  insert into public.settings (key, value, effective_date, note)
  values ('is_production', 'true', public.app_today(),
          'Production: the time machine is off for good, and the local seed can''t run here.');
  if (select s.value from public.settings s where s.key = 'is_local_dev' order by s.id desc limit 1)
     is distinct from 'false' then
    insert into public.settings (key, value, effective_date, note)
    values ('is_local_dev', 'false', public.app_today(), 'Production.');
  end if;
  return 'Marked as production: the time machine is off for good.';
end;
$function$;

-- A reset code made before this migration was hashed the old way: it no longer matches.
delete from private.kid_pin_resets;

alter table private.kid_pin_resets enable row level security;

revoke all on function public.session_alive() from public, anon, authenticated, service_role;
revoke all on function public.pin_reset_code_hash(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.clear_kid_lockouts(uuid) from public, anon, authenticated, service_role;
