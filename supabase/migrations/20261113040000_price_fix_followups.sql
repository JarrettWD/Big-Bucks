-- The price fix, part 5: two follow-ups found while testing the build.
--
-- 1. The evening timer's wait counts only the nightly run's own jobs.
-- 2. Dad can turn the price check (price_mismatch_check) on and off in Settings: set_setting
--    accepts it (on or off), Settings shows it as "On" / "Off", and parent_price_check gives its
--    card. It starts off (20261113000000_price_confirm.sql).
--
-- 1. nightly_waiting_for_confirm (20261113000000_price_confirm.sql) let the timer call again before
-- 9:00 pm when any job had failed, including GitHub's backup and health check, which the nightly
-- function can't fix. Now only a failed run_daily job (expire, splits, settle, dividends, notes,
-- gic_maturity, auto_move, monthly, rate_notices, interest) makes it call; a failed backup or
-- health check still raises its own alert (check_outside_jobs), as before.

-- nightly_waiting_for_confirm: from 20261113000000_price_confirm.sql (1 change: only run_daily's jobs).
create or replace function public.nightly_waiting_for_confirm()
returns boolean
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_status jsonb := public.nightly_status(v_today);
begin
  if public.app_now() >= public.confirm_time('nyse', v_today) then
    return false;
  end if;
  -- An earlier day's close is still missing, or one of the nightly run's jobs failed: call.
  if exists (select 1 from public.missing_closes(v_today)) then
    return false;
  end if;
  if exists (select 1 from public.job_runs jr
              where jr.status = 'failed'
                and jr.job::text in ('expire', 'splits', 'settle', 'dividends', 'notes', 'gic_maturity',
                                     'auto_move', 'monthly', 'rate_notices', 'interest')
                and not exists (select 1 from public.job_runs ok
                                 where ok.job = jr.job and ok.run_for_date = jr.run_for_date and ok.status = 'ok')) then
    return false;
  end if;
  -- Every job still waiting for today is fund work, which needs today's close.
  if exists (select 1 from jsonb_array_elements_text(v_status -> 'jobs_waiting') j
              where j not in ('splits', 'settle', 'dividends', 'notes')) then
    return false;
  end if;
  -- Yesterday has been checked (today's check waits for tonight's work).
  return coalesce((select max(jr.run_for_date) from public.job_runs jr where jr.job = 'reconcile'), date '-infinity')
         >= v_today - 1;
end;
$$;

-- 2. The price check in Settings ----------------------------------------------------------------------

-- set_setting_unlogged: from 20261012000000_request_expiry_dashboard.sql (1 change: price_mismatch_check, on or off).
create or replace function public.set_setting_unlogged(p_key text, p_value text, p_effective_date date default null, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_effective date := coalesce(p_effective_date, public.app_today());
  v_value text := btrim(coalesce(p_value, ''));
  v_key text := btrim(coalesce(p_key, ''));
  v_old_cap bigint;
  v_new_cap bigint;
  v_id bigint;
  v_account uuid;
begin
  perform public.require_parent();

  if v_key in ('is_local_dev', 'clock_override') then
    raise exception '"%" describes the computer the app runs on, so the app can never change it.', v_key
      using errcode = '42501';
  end if;
  if v_effective < v_today then
    raise exception 'A setting can''t start in the past.';
  end if;

  if v_key = 'deposit_cap_cents' then
    if v_value !~ '^\d{1,10}$' then
      raise exception 'The deposit cap must be a whole number of cents, like 100000 for $1,000.00.';
    end if;
    v_value := v_value::bigint::text;
  elsif v_key = 'inflation_rate' or v_key like 'dividend_yield:%' then
    if v_key like 'dividend_yield:%'
       and not exists (select 1 from public.funds f where f.id = substr(v_key, length('dividend_yield:') + 1)) then
      raise exception 'There''s no fund called "%".', substr(v_key, length('dividend_yield:') + 1);
    end if;
    if v_value !~ '^\d{1,2}(\.\d{1,3})?$' then
      raise exception 'Use a percent between 0 and 99.999, like 2.0.';
    end if;
  elsif v_key like 'feature:%' then
    if substr(v_key, length('feature:') + 1) !~ '^[a-z0-9_]+$' then
      raise exception 'Feature names use lowercase letters, numbers and _.';
    end if;
    if v_value not in ('off', 'test', 'everyone') then
      raise exception 'A feature switch is off, test or everyone.';
    end if;
  elsif v_key in ('market_move_note_up', 'market_move_note_down') then
    if v_value = '' or length(v_value) > 300 then
      raise exception 'The note needs some words, and at most 300 letters.';
    end if;
  elsif v_key = 'request_expiry_days' then
    if v_value !~ '^[1-9]\d?$' or v_value::integer not between 3 and 30 then
      raise exception 'Request expiry is a whole number of days from 3 to 30.';
    end if;
  elsif v_key = 'price_mismatch_check' then
    if v_value not in ('on', 'off') then
      raise exception 'The price check is on or off.';
    end if;
  elsif v_key = 'launched_at' then
    if exists (select 1 from public.settings s where s.key = 'launched_at') then
      raise exception 'Big Bucks has already launched; the launch time can''t change.';
    end if;
    begin
      perform v_value::timestamptz;
    exception when others then
      raise exception 'Use a date and time, like 2027-01-01 09:00.';
    end;
  else
    raise exception '"%" isn''t a setting Big Bucks knows about.', v_key;
  end if;

  if v_key = 'deposit_cap_cents' then
    v_old_cap := public.setting_on('deposit_cap_cents', v_effective - 1)::bigint;
    v_new_cap := v_value::bigint;
  end if;

  insert into public.settings (key, value, effective_date, note, changed_by)
  values (v_key, v_value, v_effective, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  if v_key = 'deposit_cap_cents' and v_new_cap is distinct from v_old_cap then
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'cap_change',
        'The deposit limit '
          || case when v_new_cap > coalesce(v_old_cap, 0) then 'goes up' else 'goes down' end
          || coalesce(' from ' || public.fmt_money(v_old_cap), '') || ' to ' || public.fmt_money(v_new_cap)
          || case when v_effective = v_today then ' today' else ' on ' || public.fmt_date(v_effective) end,
        concat_ws(' ', public.as_sentence(p_note),
          'This is the most you can put in, minus what you take out. Interest and gains don''t count.',
          case when v_new_cap < coalesce(v_old_cap, 0) then
            'If you''ve already put in more than that, nothing is taken away. You just can''t add more for now.' end),
        'cap_change:' || v_id || ':' || v_account);
    end loop;
  end if;
  if v_key = 'request_expiry_days' and v_effective = v_today then
    perform public.send_expiry_notices(v_id);
  end if;
  return v_id;
end;
$$;

-- set_setting: from 20261014000000_settings_screen.sql (1 change: Dad's log says "Price check turned on").
create or replace function public.set_setting(p_key text, p_value text, p_effective_date date default null, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_key text := btrim(coalesce(p_key, ''));
  v_before numeric[];
  v_lower date;
  v_id bigint;
  v_s public.settings;
  v_from text;
begin
  if v_key like 'dividend_yield:%' or v_key = 'deposit_cap_cents' then
    v_before := public.setting_week(v_key, v_today);
  end if;
  v_id := public.set_setting_unlogged(p_key, p_value, p_effective_date, p_note);

  select * into v_s from public.settings s where s.id = v_id;
  if v_s.key like 'dividend_yield:%' or v_s.key = 'deposit_cap_cents' then
    v_lower := public.first_lower_day(v_before, public.setting_week(v_s.key, v_today), v_today);
    if v_lower is not null then
      raise exception '%', public.cut_notice_message(
        case when v_s.key = 'deposit_cap_cents' then 'deposit limit'
             else public.fund_label(substr(v_s.key, length('dividend_yield:') + 1)) || ' fund''s dividend rate' end,
        v_lower, false);
    end if;
  end if;
  if v_s.key like 'dividend_yield:%' then
    perform public.send_yield_notices(v_id);
  end if;

  v_from := ' from ' || public.fmt_date(v_s.effective_date) || '.';
  perform public.log_parent_action('set_setting', null, v_id,
    case
      when v_s.key = 'deposit_cap_cents' then 'Deposit cap set to ' || public.fmt_money(v_s.value::bigint) || v_from
      when v_s.key = 'inflation_rate' then 'Inflation rate set to ' || public.fmt_rate(v_s.value::numeric) || v_from
      when v_s.key = 'request_expiry_days' then 'Request expiry set to ' || v_s.value || ' days' || v_from
      when v_s.key like 'dividend_yield:%' then
        coalesce((select f.name from public.funds f where f.id = substr(v_s.key, length('dividend_yield:') + 1)), v_s.key)
        || ' dividend yield set to ' || public.fmt_rate(v_s.value::numeric) || v_from
      when v_s.key like 'feature:%' then
        'Feature "' || substr(v_s.key, length('feature:') + 1) || '" switched to '
        || case v_s.value when 'off' then 'off' when 'test' then 'test accounts only' else 'everyone' end || v_from
      when v_s.key = 'market_move_note_up' then 'Standard note for big up days changed' || v_from
      when v_s.key = 'market_move_note_down' then 'Standard note for big down days changed' || v_from
      when v_s.key = 'price_mismatch_check' then
        'Price check turned ' || case v_s.value when 'on' then 'on' else 'off' end || v_from
      when v_s.key = 'launched_at' then 'Launch time set to ' || v_s.value || '.'
      else 'Setting "' || v_s.key || '" changed' || v_from
    end,
    jsonb_build_object('key', v_s.key, 'value', v_s.value, 'effective_date', v_s.effective_date, 'note', v_s.note));
  return v_id;
end;
$$;

-- setting_text: from 20261014000000_settings_screen.sql (1 change: the price check reads On / Off).
create or replace function public.setting_text(p_key text, p_value text)
returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p_value is null then null
    when p_key = 'deposit_cap_cents' then public.fmt_money(p_value::bigint)
    when p_key = 'inflation_rate' or p_key like 'dividend_yield:%' then public.fmt_rate(p_value::numeric)
    when p_key = 'request_expiry_days' then p_value || ' days'
    when p_key like 'feature:%' then
      case p_value when 'off' then 'Off' when 'test' then 'Test accounts only' when 'everyone' then 'Everyone' else p_value end
    when p_key = 'price_mismatch_check' then case p_value when 'on' then 'On' when 'off' then 'Off' else p_value end
    else p_value
  end;
$$;

-- The price check's card for Settings (its value, any planned change and its history).
create function public.parent_price_check()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return public.setting_card('price_mismatch_check', public.app_today(), 'off');
end;
$$;
comment on function public.parent_price_check() is
  'Settings: the price check''s card (on or off, planned changes, history). Parent with MFA only.';
revoke all on function public.parent_price_check() from public, anon, authenticated, service_role;
grant execute on function public.parent_price_check() to authenticated;
