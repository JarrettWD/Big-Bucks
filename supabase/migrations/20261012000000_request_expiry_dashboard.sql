-- Stage 8 B1: request expiry is a parent setting, and the parent dashboard.
--
-- 1. request_expiry_days: Dad sets how long a deposit or withdrawal waits for him
--    (7 days to start, 3 to 30). Each request's expiry (requests.expires_at) is
--    fixed when she asks, from the setting in force that day; a change applies only
--    to new requests. The girls are told when a change takes effect.
-- 2. Two of Part A's originals change, on purpose and only in these lines (a test
--    swaps the old lines back and gets the committed fingerprint):
--      approve_request_unlogged: the expiry check uses the request's own expiry;
--      set_setting_unlogged: the new key, and the notice when it starts today.
-- 3. expire_requests uses each request's own expiry, and tells the girls when a
--    change takes effect on a later date.
-- 4. The nightly check adds one rule: nothing waits past its expiry once the
--    expiry job has run. reconcile_account is wrapped (renamed, body unchanged).
-- 5. parent_dashboard(), with the 48-hour expiry warning.

alter type public.notification_type add value if not exists 'rule_change';

-- 1. The setting and each request's expiry ----------------------------------------------------------

insert into public.settings (key, value, effective_date, note) values
  ('request_expiry_days', '7', date '2026-01-01', 'Starting rule: Dad has 7 days to answer a deposit or withdrawal.');

alter table public.requests add column expires_at timestamptz;
comment on column public.requests.expires_at is
  'Deposits and withdrawals: when the request runs out of time if Dad hasn''t answered. Fixed when she asks.';

-- Requests made before this rule had 7 days (7 × 24 hours).
update public.requests set expires_at = created_at + interval '168 hours' where type in ('deposit', 'withdraw');

alter table public.requests add constraint requests_expiry_iff_cash
  check ((type in ('deposit', 'withdraw')) = (expires_at is not null));

-- How long a request had to wait for Dad, in whole days.
create function public.request_days(r public.requests)
returns integer
language sql immutable
set search_path = ''
as $$
  select round(extract(epoch from (r.expires_at - r.created_at)) / 86400)::integer;
$$;

-- Every new deposit or withdrawal gets its expiry from the setting in force on the
-- day she asks (Alberta date), as whole 24-hour days. Whatever an insert says is
-- replaced by the rule.
create function public.requests_set_expiry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.type in ('deposit', 'withdraw') then
    new.expires_at := new.created_at
      + coalesce(public.setting_on('request_expiry_days', public.edmonton_local(new.created_at)::date)::integer, 7)
        * interval '24 hours';
  else
    new.expires_at := null;
  end if;
  return new;
end;
$$;

create function public.requests_keep_expiry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.expires_at is distinct from old.expires_at then
    raise exception 'A request''s expiry is set when she asks and can''t be changed.';
  end if;
  return new;
end;
$$;

create trigger requests_set_expiry before insert on public.requests
  for each row execute function public.requests_set_expiry();
create trigger requests_keep_expiry before update on public.requests
  for each row execute function public.requests_keep_expiry();

-- The girls' notice when the rule changes. p_force: the nightly job has already
-- checked that the day's rule changed. Otherwise (Dad saving a change that starts
-- today) it's sent only when the number differs from the rule in force before this
-- change. Either way, a kid is never told the same thing twice in a row.
create function public.send_expiry_notices(p_setting_id bigint, p_force boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_s public.settings;
  v_before text;
  v_title text;
  v_account uuid;
begin
  select * into v_s from public.settings s where s.id = p_setting_id;
  if not found or v_s.key <> 'request_expiry_days' then
    return;
  end if;
  if not p_force then
    select s.value into v_before from public.settings s
     where s.key = v_s.key and s.id <> v_s.id
       and (s.effective_date < v_s.effective_date or (s.effective_date = v_s.effective_date and s.id < v_s.id))
     order by s.effective_date desc, s.id desc limit 1;
    if v_before is not distinct from v_s.value then
      return;
    end if;
  end if;

  v_title := 'Dad now has up to ' || v_s.value || ' days to answer your requests';
  for v_account in select a.id from public.accounts a order by a.id loop
    continue when v_title is not distinct from (
      select n.title from public.notifications n
       where n.account_id = v_account and n.type = 'rule_change' order by n.id desc limit 1);
    perform public.notify(v_account, 'rule_change', v_title,
      'If he hasn''t said yes or no to a deposit or withdrawal by then, it''s cancelled and you can ask again. '
        || 'Requests you''ve already made keep the time they had.',
      'rule_change:' || v_s.id || ':' || v_account);
  end loop;
end;
$$;

-- 2. The two Part A originals, changed only where shown --------------------------------------------

create or replace function public.approve_request_unlogged(p_request_id bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_now timestamptz := public.app_now();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.require_parent();

  select * into v_req from public.requests r where r.id = p_request_id for update;
  if not found then
    raise exception 'There''s no request %.', p_request_id;
  end if;
  perform 1 from public.accounts a where a.id = v_req.account_id for update;

  if v_req.status <> 'pending' then
    raise exception 'This request isn''t waiting for an answer (it''s %).', v_req.status;
  end if;
  if v_req.type = 'move' then
    raise exception 'Moves go through on their own: only deposits and withdrawals need your approval.';
  end if;
  if v_now >= v_req.expires_at then
    raise exception 'This request ran out of time on % (after % days), so it has expired. She can make a new one.',
      public.fmt_moment(v_req.expires_at), public.request_days(v_req);
  end if;
  if v_req.type = 'withdraw' and v_now < v_req.created_at + interval '24 hours' then
    raise exception 'Withdrawals wait 24 hours before they can be approved. This one can be approved from %.',
      public.fmt_moment(v_req.created_at + interval '24 hours');
  end if;

  if v_req.type = 'deposit' then
    insert into public.transactions (account_id, vehicle, type, amount_cents, request_id, posting_key, note)
    values (v_req.account_id, 'savings', 'deposit', v_req.amount_cents, v_req.id, 'request:' || v_req.id, v_note);
    perform public.notify(v_req.account_id, 'request',
      'Your ' || public.fmt_money(v_req.amount_cents) || ' deposit is in!',
      concat_ws(' ', 'Dad approved it, so it''s in your savings now.', public.as_sentence(v_note)),
      'approved:' || v_req.id, p_request_id => v_req.id);
  else
    if public.vehicle_cents(v_req.account_id, 'savings') < v_req.amount_cents then
      raise exception 'Savings has less than the % this withdrawal needs. Please check the account.',
        public.fmt_money(v_req.amount_cents);
    end if;
    insert into public.transactions (account_id, vehicle, type, amount_cents, request_id, posting_key, note)
    values (v_req.account_id, 'savings', 'withdraw', -v_req.amount_cents, v_req.id, 'request:' || v_req.id, v_note);
    perform public.notify(v_req.account_id, 'request',
      'Your ' || public.fmt_money(v_req.amount_cents) || ' withdrawal is approved',
      concat_ws(' ', 'Dad approved taking it out of your savings.', public.as_sentence(v_note)),
      'approved:' || v_req.id, p_request_id => v_req.id);
  end if;

  update public.requests
     set status = 'approved', decided_at = v_now, parent_note = v_note
   where id = v_req.id;
end;
$$;

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

-- The log line for the new setting (the wrapper may change; it only adds the log).
create or replace function public.set_setting(p_key text, p_value text, p_effective_date date default null, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_s public.settings;
  v_from text;
begin
  v_id := public.set_setting_unlogged(p_key, p_value, p_effective_date, p_note);

  select * into v_s from public.settings s where s.id = v_id;
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
      when v_s.key = 'launched_at' then 'Launch time set to ' || v_s.value || '.'
      else 'Setting "' || v_s.key || '" changed' || v_from
    end,
    jsonb_build_object('key', v_s.key, 'value', v_s.value, 'effective_date', v_s.effective_date, 'note', v_s.note));
  return v_id;
end;
$$;

-- 3. The nightly expiry job -----------------------------------------------------------------------

-- Deposits and withdrawals Dad hasn't answered expire at their own expiry time,
-- releasing any hold, with a kind notice saying how long they waited. On the day a
-- new expiry rule takes effect, the girls are told (once).
create or replace function public.expire_requests(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff timestamptz := least(public.app_now(), public.edmonton_start(p_date + 1));
  v_req public.requests;
  v_count integer := 0;
  v_rule bigint;
begin
  for v_req in
    select * from public.requests r
     where r.status = 'pending' and r.type in ('deposit', 'withdraw')
       and r.expires_at <= v_cutoff
     order by r.id
       for update
  loop
    update public.requests
       set status = 'expired', decided_at = v_req.expires_at
     where id = v_req.id;
    perform public.notify(v_req.account_id, 'request_expired', 'Your request ran out of time',
      'Your request to ' || case v_req.type when 'deposit' then 'put in ' else 'take out ' end
        || public.fmt_money(v_req.amount_cents) || ' waited ' || public.request_days(v_req)
        || ' days without an answer, so it was cancelled. '
        || case v_req.type when 'withdraw' then 'The money is free to use again, and you can ask again any time.'
                else 'You can ask again any time.' end,
      'expired:' || v_req.id, p_request_id => v_req.id);
    v_count := v_count + 1;
  end loop;

  -- A new expiry rule that starts today.
  if public.setting_on('request_expiry_days', p_date - 1) is not null
     and public.setting_on('request_expiry_days', p_date) is distinct from public.setting_on('request_expiry_days', p_date - 1) then
    select s.id into v_rule from public.settings s
     where s.key = 'request_expiry_days' and s.effective_date <= p_date
     order by s.effective_date desc, s.id desc limit 1;
    perform public.send_expiry_notices(v_rule, true);
  end if;

  return jsonb_build_object('status', 'ok', 'expired', v_count);
end;
$$;

-- 4. The nightly check: nothing waits past its expiry -----------------------------------------------

alter function public.reconcile_account(uuid, date, date, date) rename to reconcile_account_core;

create function public.reconcile_account(p_account uuid, p_date date, p_jobs_done date, p_interest_done date)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_found jsonb := public.reconcile_account_core(p_account, p_date, p_jobs_done, p_interest_done);
  v_cutoff timestamptz := least(public.app_now(), public.edmonton_start(p_date + 1));
  v_r record;
begin
  -- Only once the expiry job has done this date, like every other "should have happened" check.
  if p_date <= p_jobs_done then
    for v_r in
      select r.id, r.status, r.expires_at, r.decided_at from public.requests r
       where r.account_id = p_account and r.type in ('deposit', 'withdraw')
         and ((r.status = 'pending' and r.expires_at <= v_cutoff)
              or (r.status = 'approved' and r.decided_at >= r.expires_at)
              or (r.status = 'expired' and r.decided_at is distinct from r.expires_at))
       order by r.id
    loop
      v_found := v_found || public.recon_problem('expiry',
        case v_r.status
          when 'pending' then 'A request is still waiting after it ran out of time.'
          when 'approved' then 'A request was approved after it ran out of time.'
          else 'An expired request has the wrong expiry time.' end,
        jsonb_build_object('request_id', v_r.id, 'status', v_r.status, 'expires_at', v_r.expires_at,
                           'decided_at', v_r.decided_at));
    end loop;
  end if;
  return v_found;
end;
$$;

create or replace function public.recon_alert_message(p_code text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_code
    when 'negative'    then 'A balance went below zero.'
    when 'fund_cost'   then 'A fund''s cost doesn''t add up.'
    when 'posting'     then 'A ledger line doesn''t match the rule that should have made it.'
    when 'worth'       then 'Total worth doesn''t equal money in, minus money out, plus earnings.'
    when 'app_figures' then 'A figure the app shows doesn''t match the ledger.'
    when 'held'        then 'Money or units held by a pending request don''t add up.'
    when 'gic'         then 'A GIC doesn''t add up.'
    when 'accrual'     then 'A day''s savings interest is missing or wrong.'
    when 'missed'      then 'Something that should have been posted wasn''t.'
    when 'duplicate'   then 'Something was posted twice.'
    when 'expiry'      then 'A request was still waiting after it ran out of time.'
    else 'The nightly check found a problem.' end
    || ' Her figures show "Updating…" until a later check finds them right.';
$$;

-- 5. The Approvals screen uses each request's own expiry ---------------------------------------------

create or replace function public.parent_inbox()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.app_now();
  v_requests jsonb;
  v_questions jsonb;
  v_recent jsonb;
begin
  perform public.require_parent();

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'account_id', r.account_id, 'kid', a.name, 'is_test', a.is_test,
           'type', r.type, 'amount_cents', r.amount_cents,
           'asked', public.fmt_moment(r.created_at),
           'approve_from', case when r.type = 'withdraw' then public.fmt_moment(r.created_at + interval '24 hours') end,
           'wait_seconds', greatest(0, ceil(extract(epoch from
                             (r.created_at + case when r.type = 'withdraw' then interval '24 hours' else interval '0' end)
                             - v_now)))::bigint,
           'expires', public.fmt_moment(r.expires_at),
           'expires_seconds', greatest(0, ceil(extract(epoch from r.expires_at - v_now)))::bigint,
           'savings_cents', b.savings_cents, 'held_cents', b.held_cents, 'available_cents', b.available_cents,
           'savings_after_cents', b.savings_cents + case when r.type = 'deposit' then r.amount_cents else -r.amount_cents end,
           'cap_cents', b.cap_cents, 'net_deposits_cents', b.net_deposits_cents,
           'pending_deposits_cents', b.pending_deposits_cents, 'cap_room_cents', b.cap_room_cents)
         order by a.is_test, r.created_at, r.id), '[]'::jsonb)
    into v_requests
    from public.requests r
    join public.accounts a on a.id = r.account_id
    join public.account_balances b on b.account_id = r.account_id
   where r.status = 'pending' and r.type in ('deposit', 'withdraw');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'account_id', q.account_id, 'kid', a.name, 'is_test', a.is_test,
           'message', q.message, 'asked', public.fmt_moment(q.created_at),
           'transaction_id', q.transaction_id,
           'line', (select to_jsonb(l) from public.my_activity(q.account_id, 100000) l
                     where q.transaction_id = any (l.transaction_ids) limit 1))
         order by a.is_test, q.created_at, q.id), '[]'::jsonb)
    into v_questions
    from public.questions q
    join public.accounts a on a.id = q.account_id
   where q.status = 'open';

  select coalesce(jsonb_agg(x.item order by x.done_at desc, x.id desc), '[]'::jsonb)
    into v_recent
    from (select pa.id, pa.done_at, jsonb_build_object(
                   'id', pa.id, 'action', pa.action, 'summary', pa.summary,
                   'who', coalesce(p.display_name, 'Someone'), 'when', public.fmt_moment(pa.done_at),
                   'kid', a.name, 'is_test', coalesce(a.is_test, false), 'details', pa.details) as item
            from public.parent_actions pa
            left join public.profiles p on p.user_id = pa.done_by
            left join public.accounts a on a.id = pa.account_id
           where pa.action in ('approve_request', 'decline_request', 'answer_question')
           order by pa.done_at desc, pa.id desc
           limit 20) x;

  return jsonb_build_object('now', public.fmt_moment(v_now), 'requests', v_requests,
                            'questions', v_questions, 'recent', v_recent);
end;
$$;

-- 6. The parent dashboard -------------------------------------------------------------------------

-- A moment in words, from today's point of view: "today at 3:30 pm", "tomorrow at
-- 9:00 am", "yesterday at …", or the weekday ("Monday at 11:00 am"). Alberta time.
create function public.fmt_relative(p timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select case public.edmonton_local(p)::date - public.app_today()
           when 0 then 'today'
           when 1 then 'tomorrow'
           when -1 then 'yesterday'
           else to_char(public.edmonton_local(p), 'FMDay') end
         || ' at ' || to_char(public.edmonton_local(p), 'FMHH12:MI am');
$$;

-- How long until a moment, rounded down: "30 minutes", "1 hour", "28 hours".
create function public.fmt_time_left(p_seconds bigint)
returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p_seconds < 60 then 'under a minute'
    when p_seconds < 3600 then (p_seconds / 60) || case when p_seconds / 60 = 1 then ' minute' else ' minutes' end
    else (p_seconds / 3600) || case when p_seconds / 3600 = 1 then ' hour' else ' hours' end
  end;
$$;

-- Everything the dashboard shows, for a parent with the authenticator code:
--   kids            each kid's figures (real kids first)
--   liability_cents what Dad owes the real kids (test accounts left out)
--   waiting         deposits and withdrawals, and questions, waiting for Dad
--   expiring        real kids' requests with 48 hours or less left (or already run out
--                   but not yet cancelled by the nightly run), soonest first
--   expiring_test   the same for test accounts, to be folded away
--   moves           the last 14 days of automatic moves (GICs and fund trades)
--   maturities      GICs waiting for her choice, then GICs maturing in the next 30 days
--   alerts          open alerts; alerts_quiet: test accounts' (folded away)
--   notices         rate, cap and rule notices from the last 30 days, and who has read them
--   holidays        markets whose confirmed holiday dates run out within 60 days
create function public.parent_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.app_now();
  v_today date := public.app_today();
  v_kids jsonb;
  v_expiring jsonb;
  v_moves jsonb;
  v_maturities jsonb;
  v_alerts jsonb;
  v_notices jsonb;
  v_holidays jsonb;
begin
  perform public.require_parent();

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', a.id, 'kid', a.name, 'is_test', a.is_test,
           'total_worth_cents', b.total_worth_cents, 'savings_cents', b.savings_cents,
           'gic_cents', b.gic_cents, 'stock_value_cents', b.stock_value_cents,
           'net_deposits_cents', b.net_deposits_cents)
         order by a.is_test, a.name), '[]'::jsonb)
    into v_kids
    from public.accounts a join public.account_balances b on b.account_id = a.id;

  -- Requests running out of time.
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', x.id, 'kid', x.name, 'is_test', x.is_test, 'type', x.type,
           'amount_cents', x.amount_cents, 'expires', public.fmt_moment(x.expires_at),
           'seconds_left', x.secs,
           'text', x.name || '''s ' || public.fmt_money(x.amount_cents) || ' '
                   || case x.type when 'deposit' then 'deposit' else 'withdrawal' end
                   || case when x.secs <= 0
                        then ' ran out of time ' || public.fmt_relative(x.expires_at) || '. Tonight''s run cancels it.'
                        else ' expires ' || public.fmt_relative(x.expires_at)
                             || ' (in ' || public.fmt_time_left(x.secs) || ').' end)
         order by x.expires_at, x.id), '[]'::jsonb)
    into v_expiring
    from (select r.id, r.type, r.amount_cents, r.expires_at, a.name, a.is_test,
                 floor(extract(epoch from r.expires_at - v_now))::bigint as secs
            from public.requests r join public.accounts a on a.id = r.account_id
           where r.status = 'pending' and r.type in ('deposit', 'withdraw')
             and r.expires_at <= v_now + interval '48 hours') x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id, 'kid', a.name, 'is_test', a.is_test, 'when', public.fmt_moment(r.created_at),
           'from_vehicle', r.from_vehicle, 'to_vehicle', r.to_vehicle, 'fund_id', r.fund_id,
           'gic_term', r.gic_term, 'amount_cents', r.amount_cents, 'sell_all', r.sell_all, 'status', r.status)
         order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_moves
    from public.requests r join public.accounts a on a.id = r.account_id
   where r.type = 'move' and r.created_at >= v_now - interval '14 days';

  select coalesce(jsonb_agg(jsonb_build_object(
           'gic_id', g.gic_id, 'kid', a.name, 'is_test', a.is_test,
           'amount_cents', h.principal_cents, 'interest_cents', g.interest_at_maturity_cents,
           'term_months', h.term_months, 'rate', h.rate,
           'matures', public.fmt_date(h.maturity_date), 'days_left', h.maturity_date - v_today,
           'waiting', g.choose_by is not null, 'choose_by', public.fmt_date(g.choose_by))
         order by (g.choose_by is null), h.maturity_date, g.gic_id), '[]'::jsonb)
    into v_maturities
    from public.gic_positions g
    join public.gic_holdings h on h.id = g.gic_id
    join public.accounts a on a.id = h.account_id
   where g.choose_by is not null
      or (h.status = 'active' and h.maturity_date <= v_today + 30);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', al.id, 'kind', al.kind, 'kid', a.name, 'message', al.message,
           'since', public.fmt_moment(al.created_at), 'is_quiet', al.is_quiet)
         order by al.created_at desc, al.id desc), '[]'::jsonb)
    into v_alerts
    from public.alerts al left join public.accounts a on a.id = al.account_id
   where al.resolved_at is null;

  -- Notices grouped by what was announced (their keys end with the kid's account id).
  select coalesce(jsonb_agg(jsonb_build_object('title', g.title, 'sent', public.fmt_moment(g.sent), 'kids', g.kids)
                            order by g.sent desc), '[]'::jsonb)
    into v_notices
    from (select regexp_replace(n.dedupe_key, ':[^:]+$', '') as k, min(n.title) as title, min(n.created_at) as sent,
                 jsonb_agg(jsonb_build_object('kid', a.name, 'is_test', a.is_test,
                                              'read', public.fmt_moment(n.read_at))
                           order by a.is_test, a.name) as kids
            from public.notifications n join public.accounts a on a.id = n.account_id
           where n.type in ('rate_change', 'rate_live', 'cap_change', 'rule_change')
             and n.created_at >= v_now - interval '30 days'
           group by 1) g;

  -- Each market's holiday dates are covered through the end of its last year in an
  -- unbroken run of confirmed years from this year on.
  select coalesce(jsonb_agg(jsonb_build_object(
           'market', m.market, 'through', to_char(m.through, 'Mon FMDD, YYYY'),
           'text', upper(m.market::text) || ' holiday dates are confirmed only through '
                   || to_char(m.through, 'Mon FMDD, YYYY') || '. When the ' || upper(m.market::text)
                   || ' publishes its ' || (extract(year from m.through)::int + 1)
                   || ' calendar, ask Claude Code to add it.')
         order by m.market), '[]'::jsonb)
    into v_holidays
    from (select mk.market,
                 make_date(coalesce((select min(y.y) - 1
                                       from generate_series(extract(year from v_today)::int,
                                                            extract(year from v_today)::int + 10) y(y)
                                      where not exists (select 1 from public.market_holidays h
                                                         where h.market = mk.market
                                                           and extract(year from h.holiday_date) = y.y)
                                         or exists (select 1 from public.market_holidays h
                                                     where h.market = mk.market and not h.confirmed
                                                       and extract(year from h.holiday_date) = y.y)),
                                     extract(year from v_today)::int + 10), 12, 31) as through
            from (select distinct h.market from public.market_holidays h) mk) m
   where m.through <= v_today + 60;

  return jsonb_build_object(
    'now', public.fmt_moment(v_now),
    'kids', v_kids,
    'liability_cents', public.liability_total(),
    'waiting', jsonb_build_object(
      'requests', (select count(*) from public.requests r where r.status = 'pending' and r.type in ('deposit', 'withdraw')),
      'questions', (select count(*) from public.questions q where q.status = 'open')),
    'expiring', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_expiring) e where not (e ->> 'is_test')::boolean), '[]'::jsonb),
    'expiring_test', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_expiring) e where (e ->> 'is_test')::boolean), '[]'::jsonb),
    'moves', v_moves,
    'maturities', v_maturities,
    'alerts', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_alerts) e where not (e ->> 'is_quiet')::boolean), '[]'::jsonb),
    'alerts_quiet', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_alerts) e where (e ->> 'is_quiet')::boolean), '[]'::jsonb),
    'notices', v_notices,
    'holidays', v_holidays);
end;
$$;
comment on function public.parent_dashboard() is
  'Parent dashboard: kids, liability, waiting, 48-hour expiry warnings, moves, maturities, alerts, notices read, holidays.';

-- 7. Settings: what's set, and what a change would do --------------------------------------------------

-- The Settings screen's figures (B1: request expiry; B2 adds the rest). History
-- comes from the parent action log, so "when" is the app's clock and "who" a name.
create function public.parent_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
begin
  perform public.require_parent();
  return jsonb_build_object(
    'today', v_today,
    'today_text', public.fmt_date(v_today),
    'expiry', jsonb_build_object(
      'days', public.setting_on('request_expiry_days', v_today)::integer,
      'min', 3, 'max', 30,
      'scheduled', coalesce((
        select jsonb_agg(jsonb_build_object('days', s.value::integer, 'from', public.fmt_date(s.effective_date))
                         order by s.effective_date, s.id)
          from public.settings s
         where s.key = 'request_expiry_days' and s.effective_date > v_today
           and s.id = (select s2.id from public.settings s2 where s2.key = s.key and s2.effective_date = s.effective_date
                        order by s2.id desc limit 1)), '[]'::jsonb),
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'days', s.value::integer, 'from', public.fmt_date(s.effective_date), 'note', s.note,
                 'who', coalesce(p.display_name, case when pa.id is null then 'Starting rule' end),
                 'when', public.fmt_moment(pa.done_at))
               order by s.id desc)
          from public.settings s
          left join public.parent_actions pa on pa.action = 'set_setting' and pa.target_id = s.id
          left join public.profiles p on p.user_id = pa.done_by
         where s.key = 'request_expiry_days'), '[]'::jsonb)));
end;
$$;
comment on function public.parent_settings() is 'Settings screen: current values, scheduled changes and history. Parent with MFA only.';

-- What a settings change would do, without doing it: runs the real (logged)
-- action with in_preview() on, captures the girls' notices and the log line, then
-- always rolls it all back. A request-expiry change that starts on a later day
-- also dry-runs the notice they'd get that day (notices_on says when).
-- p_action: set_setting, with p_args {key, value, effective_date, note}.
-- Returns {problem, notices: [{title, body, kids}], notices_on, summary}.
create function public.parent_change_preview(p_action text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was text := coalesce(current_setting('bigbucks.preview', true), '');
  v_today date := public.app_today();
  v_last_notice bigint;
  v_last_action bigint;
  v_id bigint;
  v_effective date;
  v_problem text;
  v_notices jsonb;
  v_summary text;
  v_on text;
begin
  perform public.require_parent();
  if p_action is null or p_action not in ('set_setting') then
    raise exception 'There''s no preview for "%".', p_action;
  end if;

  select coalesce(max(n.id), 0) into v_last_notice from public.notifications n;
  select coalesce(max(pa.id), 0) into v_last_action from public.parent_actions pa;

  begin
    perform set_config('bigbucks.preview', 'on', true);
    v_effective := nullif(p_args ->> 'effective_date', '')::date;
    v_id := public.set_setting(p_args ->> 'key', p_args ->> 'value', v_effective, p_args ->> 'note');
    if p_args ->> 'key' = 'request_expiry_days' and coalesce(v_effective, v_today) > v_today then
      perform public.send_expiry_notices(v_id);
      v_on := public.fmt_date(v_effective);
    end if;
    select jsonb_agg(jsonb_build_object('title', x.title, 'body', x.body, 'kids', x.kids) order by x.first)
      into v_notices
      from (select n.title, n.body, count(*) as kids, min(n.id) as first from public.notifications n
             where n.id > v_last_notice group by n.title, n.body) x;
    select pa.summary into v_summary from public.parent_actions pa
     where pa.id > v_last_action order by pa.id desc limit 1;
    raise exception 'preview only' using errcode = 'BB000';
  exception
    when sqlstate 'BB000' then v_problem := null;
    when others then
      v_problem := sqlerrm;
      v_notices := null;
      v_summary := null;
      v_on := null;
  end;
  perform set_config('bigbucks.preview', v_was, true);

  return jsonb_build_object('problem', v_problem, 'notices', coalesce(v_notices, '[]'::jsonb),
                            'notices_on', v_on, 'summary', v_summary);
end;
$$;
comment on function public.parent_change_preview(text, jsonb) is
  'Settings: what a change would do (the real action, rolled back, in_preview on). Parent with MFA only.';

-- 8. Glossary ----------------------------------------------------------------------------------------

insert into public.glossary (term, kid_text) values
  ('Request expiry', 'When you ask to put money in or take it out, Dad has a set number of days to say yes or no. '
                     || 'If he hasn''t answered by then, the request is cancelled and any money on hold is free to use '
                     || 'again. You can always ask again.');

-- Who may call them ---------------------------------------------------------------------------------

revoke all on function public.request_days(public.requests) from public, anon, authenticated, service_role;
revoke all on function public.requests_set_expiry() from public, anon, authenticated, service_role;
revoke all on function public.requests_keep_expiry() from public, anon, authenticated, service_role;
revoke all on function public.send_expiry_notices(bigint, boolean) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_account_core(uuid, date, date, date) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_account(uuid, date, date, date) from public, anon, authenticated, service_role;
revoke all on function public.fmt_relative(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.fmt_time_left(bigint) from public, anon, authenticated, service_role;
revoke all on function public.parent_dashboard() from public, anon, authenticated, service_role;
grant execute on function public.parent_dashboard() to authenticated;
revoke all on function public.parent_settings() from public, anon, authenticated, service_role;
revoke all on function public.parent_change_preview(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.parent_settings() to authenticated;
grant execute on function public.parent_change_preview(text, jsonb) to authenticated;
