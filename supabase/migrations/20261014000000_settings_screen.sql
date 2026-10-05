-- Stage 8 B2: the rest of the Settings screen.
--
-- 1. Two new parent actions, logged like the others: edit_note (reword a
--    market-move note already written) and edit_glossary (reword a ? explanation).
--    Notes and the glossary aren't money history, so they're edited in place; the
--    log keeps the wording before and after.
-- 2. parent_change_preview covers rates (add_rate) and the two new actions, and
--    says when each of the girls' notices would arrive: right away, on the day a
--    change goes live, and the day after a special ends. Each notice carries its
--    own "on" (null = right away); notices_on is gone.
-- 3. parent_settings returns everything the screen shows: every rate (in force,
--    scheduled, history), the cap, inflation, dividend yields, feature switches, the
--    standard market-move notes, the notes already written, the glossary and the
--    latest changes with who and when.
--
-- After Dad's B2 review (2026-10-04), money rules:
-- 4. Seven days' notice for a cut. Nothing Dad does may lower the rate the girls
--    expect on any of the next 7 days (today to today + 6): not a new rate, not a
--    special, not a dividend yield, not a deposit cap cut, not cancelling a raise. Checked day by day
--    against what's scheduled before the change, so stacked changes and specials
--    are covered. Raises can start right away. The check lives in the logged
--    add_rate and set_setting wrappers (the committed originals are unchanged).
-- 5. A dividend yield change tells the girls when Dad saves it, and again on the
--    day it starts, like a rate change.
-- 6. Cancel: a change that hasn't started can be cancelled by an appended row in
--    `cancellations` (nothing is edited). Every reader of rates and settings skips
--    cancelled rows. Kids who were told about the change get one notice that it's
--    cancelled; kids who weren't told get nothing. Logged.

-- 0. Cancellations, and every reader skipping them ------------------------------------------------------

create table public.cancellations (
  id           bigint generated always as identity primary key,
  rate_id      bigint unique references public.rates (id),
  setting_id   bigint unique references public.settings (id),
  note         text,
  cancelled_by uuid,
  cancelled_at timestamptz not null default public.app_now(),
  constraint cancellations_one_target check ((rate_id is null) <> (setting_id is null))
);
comment on table public.cancellations is
  'A scheduled rate or setting change that was cancelled before it started. Append-only; readers skip the cancelled row.';

create trigger cancellations_no_update_delete
  before update or delete on public.cancellations
  for each row execute function public.reject_append_only_change();
create trigger cancellations_no_truncate
  before truncate on public.cancellations
  for each statement execute function public.reject_append_only_change();

alter table public.cancellations enable row level security;
create policy cancellations_read on public.cancellations for select to authenticated using (true);
revoke all on public.cancellations from public, anon, authenticated, service_role;
grant select on public.cancellations to authenticated, service_role;

-- rate_on: from 20261002080000_engine_core.sql (1 change: cancelled rows don't count).
create or replace function public.rate_on(p_vehicle public.vehicle, p_gic_term integer, p_date date,
                                          out rate numeric, out rate_id bigint)
language sql stable
set search_path = ''
as $$
  select r.rate, r.id
    from public.rates r
   where r.vehicle = p_vehicle
     and r.gic_term is not distinct from p_gic_term
     and r.effective_date <= p_date
     and (not r.is_special or r.end_date >= p_date)
     and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
   order by r.is_special desc, r.effective_date desc, r.id desc
   limit 1;
$$;

-- setting_on: from 20261002080000_engine_core.sql (1 change: cancelled rows don't count).
create or replace function public.setting_on(p_key text, p_date date)
returns text
language sql stable
set search_path = ''
as $$
  select s.value
    from public.settings s
   where s.key = p_key and s.effective_date <= p_date
     and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
   order by s.effective_date desc, s.id desc
   limit 1;
$$;

-- feature_enabled: from 20261002030000_helpers.sql (1 change: cancelled rows don't count).
create or replace function public.feature_enabled(p_feature text, p_account_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_value text;
begin
  if auth.uid() is not null
     and not public.is_parent()
     and p_account_id is distinct from public.my_account_id() then
    raise exception 'You can only check features for your own account.'
      using errcode = '42501';
  end if;

  select btrim(s.value) into v_value
    from public.settings s
   where s.key = 'feature:' || p_feature
     and s.effective_date <= public.app_today()
     and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
   order by s.effective_date desc, s.id desc
   limit 1;

  return case v_value
    when 'everyone' then true
    when 'test' then coalesce(
      (select a.is_test from public.accounts a where a.id = p_account_id), false)
    else false
  end;
end;
$$;

-- current_rates: from 20261005000000_kid_home.sql (1 change: a cancelled change isn't "next").
create or replace function public.current_rates()
returns table (vehicle public.vehicle, gic_term integer, rate numeric, is_special boolean, special_ends date,
               next_rate numeric, next_effective date)
language sql stable
set search_path = ''
as $$
  select k.vehicle, k.term, ro.rate, coalesce(r.is_special, false), r.end_date, n.rate, n.effective_date
    from (values ('savings'::public.vehicle, null::integer, 0),
                 ('gic', 1, 1), ('gic', 3, 2), ('gic', 6, 3), ('gic', 9, 4), ('gic', 12, 5), ('gic', 24, 6)) k(vehicle, term, ord)
   cross join lateral public.rate_on(k.vehicle, k.term, public.app_today()) ro
    left join public.rates r on r.id = ro.rate_id
    left join lateral (
      select nr.rate, nr.effective_date from public.rates nr
       where nr.vehicle = k.vehicle and nr.gic_term is not distinct from k.term
         and not nr.is_special and nr.effective_date > public.app_today()
         and not exists (select 1 from public.cancellations c where c.rate_id = nr.id)
       order by nr.effective_date, nr.id desc
       limit 1) n on true
   order by k.ord;
$$;

-- send_expiry_notices: from 20261012000000_request_expiry_dashboard.sql (2 changes:
-- on the night a rule takes effect it uses the rule actually in force, and a
-- cancelled rule never counts as "the rule before").
create or replace function public.send_expiry_notices(p_setting_id bigint, p_force boolean default false)
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
  if p_force then
    select * into v_s from public.settings s
     where s.key = v_s.key and s.effective_date <= v_s.effective_date
       and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
     order by s.effective_date desc, s.id desc limit 1;
  else
    select s.value into v_before from public.settings s
     where s.key = v_s.key and s.id <> v_s.id
       and (s.effective_date < v_s.effective_date or (s.effective_date = v_s.effective_date and s.id < v_s.id))
       and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
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

-- send_rate_notices: from 20261006000000_alberta_time.sql (2 changes: cancelled
-- rates send nothing, and a dividend yield change announced earlier says it's
-- live on its day).
create or replace function public.send_rate_notices(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rate public.rates;
  v_s public.settings;
  v_what text;
  v_back numeric;
  v_account uuid;
  v_count integer := 0;
begin
  -- Going live today (skip a change saved today: its first notice already said "today").
  for v_rate in
    select * from public.rates r
     where r.effective_date = p_date and public.edmonton_local(r.created_at)::date < p_date
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id
  loop
    v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live',
        case when v_rate.is_special then 'The ' || v_what || ' special at ' || public.fmt_rate(v_rate.rate) || ' starts today'
             else 'The new ' || v_what || ' rate is now ' || public.fmt_rate(v_rate.rate) end,
        case when v_rate.is_special then 'It ends after ' || public.fmt_date(v_rate.end_date) || '.'
             else 'It applies from today.' end,
        'rate_live:' || v_rate.id || ':' || v_account, p_rate_id => v_rate.id);
      v_count := v_count + 1;
    end loop;
  end loop;

  -- Specials that ended yesterday.
  for v_rate in
    select * from public.rates r
     where r.is_special and r.end_date = p_date - 1
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id
  loop
    v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
    v_back := (public.rate_on(v_rate.vehicle, v_rate.gic_term, p_date)).rate;
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live', 'The ' || v_what || ' special has ended',
        case when v_rate.vehicle = 'savings'
             then 'Savings is back to ' || public.fmt_rate(v_back) || '.'
             else public.term_label(v_rate.gic_term) || ' GICs are back to ' || public.fmt_rate(v_back)
                  || '. GICs bought during the special keep ' || public.fmt_rate(v_rate.rate) || '.' end,
        'rate_end:' || v_rate.id || ':' || v_account, p_rate_id => v_rate.id);
      v_count := v_count + 1;
    end loop;
  end loop;

  -- A dividend yield change announced before today, starting today (the one in force).
  for v_s in
    select * from public.settings s
     where s.key like 'dividend_yield:%' and s.effective_date = p_date
       and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
       and s.id = (select s2.id from public.settings s2
                    where s2.key = s.key and s2.effective_date = s.effective_date
                      and not exists (select 1 from public.cancellations c2 where c2.setting_id = s2.id)
                    order by s2.id desc limit 1)
       and exists (select 1 from public.notifications n
                    where n.dedupe_key like 'yield_change:' || s.id || ':%'
                      and public.edmonton_local(n.created_at)::date < p_date)
     order by s.id
  loop
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live',
        'The ' || public.fund_label(substr(v_s.key, length('dividend_yield:') + 1)) || ' fund''s new dividend rate is now '
          || public.fmt_rate(v_s.value::numeric),
        'It applies from today.',
        'yield_live:' || v_s.id || ':' || v_account);
      v_count := v_count + 1;
    end loop;
  end loop;
  return jsonb_build_object('status', 'ok', 'notices', v_count);
end;
$$;

-- 1. Seven days' notice for a cut -----------------------------------------------------------------------

-- A fund's name for sentences: "Dow Jones", "Nasdaq-100", "TSX".
create function public.fund_label(p_fund_id text)
returns text
language sql stable
set search_path = ''
as $$
  select coalesce((select f.name from public.funds f where f.id = p_fund_id), p_fund_id);
$$;

-- What the girls would get on each of the 7 days from p_from (index 1 = p_from).
create function public.rate_week(p_vehicle public.vehicle, p_gic_term integer, p_from date)
returns numeric[]
language sql stable
set search_path = ''
as $$
  select array_agg((public.rate_on(p_vehicle, p_gic_term, p_from + i)).rate order by i)
    from generate_series(0, 6) i;
$$;
create function public.setting_week(p_key text, p_from date)
returns numeric[]
language sql stable
set search_path = ''
as $$
  select array_agg(public.setting_on(p_key, p_from + i)::numeric order by i)
    from generate_series(0, 6) i;
$$;

-- The first day in the week from p_from that is lower after than before, or null.
create function public.first_lower_day(p_before numeric[], p_after numeric[], p_from date)
returns date
language sql immutable
set search_path = ''
as $$
  select min(p_from + (i - 1))
    from generate_series(1, 7) i
   where p_before[i] is not null and p_after[i] is not null and p_after[i] < p_before[i];
$$;

-- The refusal, in Dad's words. p_what: "savings rate", "TSX fund's dividend rate".
create function public.cut_notice_message(p_what text, p_day date, p_cancelling boolean)
returns text
language sql stable
set search_path = ''
as $$
  select case when p_cancelling then
           'Cancelling this would lower the ' || p_what || ' on ' || public.fmt_date(p_day)
           || ', sooner than 7 days from today. The girls were promised it, so a raise can only be cancelled '
           || '7 or more days before it starts.'
         else
           'This would lower the ' || p_what || ' on ' || public.fmt_date(p_day)
           || ', sooner than 7 days from today. A cut needs 7 days'' notice so the girls have time to react: '
           || 'start it on ' || public.fmt_date(public.app_today() + 7) || ' or later. A raise can start right away.'
         end;
$$;

-- The rate and setting wrappers below keep their committed originals unchanged:
-- they look at the next 7 days before and after the original runs, and refuse
-- (rolling it all back) if any day would be lower.

create or replace function public.add_rate(
  p_vehicle public.vehicle, p_gic_term integer, p_rate numeric,
  p_effective_date date default null, p_note text default null, p_end_date date default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_before numeric[] := public.rate_week(p_vehicle, p_gic_term, public.app_today());
  v_lower date;
  v_id bigint;
  v_rate public.rates;
  v_what text;
begin
  v_id := public.add_rate_unlogged(p_vehicle, p_gic_term, p_rate, p_effective_date, p_note, p_end_date);

  v_lower := public.first_lower_day(v_before, public.rate_week(p_vehicle, p_gic_term, v_today), v_today);
  if v_lower is not null then
    raise exception '%', public.cut_notice_message(
      case when p_vehicle = 'savings' then 'savings rate' else public.term_label(p_gic_term) || ' GIC rate' end,
      v_lower, false);
  end if;

  select * into v_rate from public.rates r where r.id = v_id;
  v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
  perform public.log_parent_action('add_rate', null, v_id,
    case when v_rate.is_special then
           'Special: ' || v_what || ' at ' || public.fmt_rate(v_rate.rate) || ' from '
           || public.fmt_date(v_rate.effective_date) || ' to ' || public.fmt_date(v_rate.end_date) || '.'
         else
           initcap(left(v_what, 1)) || substr(v_what, 2) || ' rate set to ' || public.fmt_rate(v_rate.rate)
           || ' from ' || public.fmt_date(v_rate.effective_date) || '.'
    end,
    jsonb_build_object('vehicle', v_rate.vehicle, 'gic_term', v_rate.gic_term, 'rate', v_rate.rate,
                       'effective_date', v_rate.effective_date, 'end_date', v_rate.end_date,
                       'is_special', v_rate.is_special, 'note', v_rate.note));
  return v_id;
end;
$$;

-- A dividend yield change: both kids are told when Dad saves it (if the number
-- changes), like a rate change. send_rate_notices tells them again on the day.
create function public.send_yield_notices(p_setting_id bigint)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_s public.settings;
  v_old numeric;
  v_new numeric;
  v_fund text;
  v_account uuid;
begin
  select * into v_s from public.settings s where s.id = p_setting_id;
  if not found or v_s.key not like 'dividend_yield:%' then
    return;
  end if;
  v_old := public.setting_on(v_s.key, v_s.effective_date - 1)::numeric;
  v_new := v_s.value::numeric;
  if v_old is not distinct from v_new then
    return;
  end if;
  v_fund := public.fund_label(substr(v_s.key, length('dividend_yield:') + 1));
  for v_account in select a.id from public.accounts a order by a.id loop
    perform public.notify(v_account, 'rate_change',
      'The ' || v_fund || ' fund''s dividend rate '
        || case when v_old is null then 'is ' || public.fmt_rate(v_new)
                when v_new < v_old then 'drops from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(v_new)
                else 'goes up from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(v_new) end
        || case when v_s.effective_date = public.app_today() then ' today' else ' on ' || public.fmt_date(v_s.effective_date) end,
      concat_ws(' ', public.as_sentence(v_s.note),
        'Dividends go into your savings on the first market day of January, April, July and October, '
          || 'using the rate on that day.'),
      'yield_change:' || v_s.id || ':' || v_account);
  end loop;
end;
$$;

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
      when v_s.key = 'launched_at' then 'Launch time set to ' || v_s.value || '.'
      else 'Setting "' || v_s.key || '" changed' || v_from
    end,
    jsonb_build_object('key', v_s.key, 'value', v_s.value, 'effective_date', v_s.effective_date, 'note', v_s.note));
  return v_id;
end;
$$;

comment on function public.add_rate(public.vehicle, integer, numeric, date, text, date) is
  'Logged: add_rate_unlogged (unchanged from stage 2), then the 7-day notice rule for cuts, then one parent_actions row.';
comment on function public.set_setting(text, text, date, text) is
  'Logged: set_setting_unlogged, then the 7-day rule for yield and cap cuts, a yield''s notice, then one parent_actions row.';

-- 2. Cancelling a change that hasn't started --------------------------------------------------------------

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change'));

-- p_kind: 'rate' or 'setting'; p_id: that rate's or setting's id. p_note goes in
-- the girls' notice (if they were told about the change).
create function public.cancel_change(p_kind text, p_id bigint, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_r public.rates;
  v_s public.settings;
  v_before numeric[];
  v_lower date;
  v_on date;
  v_what text;
  v_now_text text;
  v_then_text text;
  v_title text;
  v_body text;
  v_prefix text;
  v_type public.notification_type;
  v_id bigint;
  v_told integer := 0;
  v_account uuid;
  v_summary text;
begin
  perform public.require_parent();

  if p_kind = 'rate' then
    select * into v_r from public.rates r where r.id = p_id for update;
    if not found then
      raise exception 'There''s no rate change #%.', p_id;
    end if;
    v_on := v_r.effective_date;
  elsif p_kind = 'setting' then
    select * into v_s from public.settings s where s.id = p_id for update;
    if not found then
      raise exception 'There''s no setting change #%.', p_id;
    end if;
    if v_s.key in ('is_local_dev', 'clock_override', 'launched_at') then
      raise exception 'This setting can''t be cancelled.';
    end if;
    v_on := v_s.effective_date;
  else
    raise exception 'Only a rate or a setting change can be cancelled.';
  end if;
  if exists (select 1 from public.cancellations c where c.rate_id = v_r.id or c.setting_id = v_s.id) then
    raise exception 'That change is already cancelled.';
  end if;
  if v_on <= v_today then
    raise exception 'This change has already started, so it can''t be cancelled. Save a new one instead.';
  end if;

  -- The 7-day rule: cancelling mustn't lower anything the girls expect this week.
  if p_kind = 'rate' then
    v_before := public.rate_week(v_r.vehicle, v_r.gic_term, v_today);
  elsif v_s.key like 'dividend_yield:%' or v_s.key = 'deposit_cap_cents' then
    v_before := public.setting_week(v_s.key, v_today);
  end if;

  insert into public.cancellations (rate_id, setting_id, note, cancelled_by)
  values (v_r.id, v_s.id, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  if p_kind = 'rate' then
    v_what := case when v_r.vehicle = 'savings' then 'savings rate' else public.term_label(v_r.gic_term) || ' GIC rate' end;
    v_lower := public.first_lower_day(v_before, public.rate_week(v_r.vehicle, v_r.gic_term, v_today), v_today);
    v_now_text := public.fmt_rate((public.rate_on(v_r.vehicle, v_r.gic_term, v_today)).rate);
    v_then_text := public.fmt_rate((public.rate_on(v_r.vehicle, v_r.gic_term, v_on)).rate);
    v_title := case when v_r.is_special
                    then 'The ' || case when v_r.vehicle = 'savings' then 'savings' else public.term_label(v_r.gic_term) || ' GIC' end
                         || ' special from ' || public.fmt_date(v_r.effective_date) || ' to ' || public.fmt_date(v_r.end_date)
                         || ' is cancelled'
                    else 'The ' || v_what || ' change on ' || public.fmt_date(v_on) || ' is cancelled' end;
    v_type := 'rate_change';
  else
    v_what := case when v_s.key = 'deposit_cap_cents' then 'deposit limit'
                   when v_s.key like 'dividend_yield:%'
                     then public.fund_label(substr(v_s.key, length('dividend_yield:') + 1)) || ' fund''s dividend rate'
                   else v_s.key end;
    if v_s.key like 'dividend_yield:%' or v_s.key = 'deposit_cap_cents' then
      v_lower := public.first_lower_day(v_before, public.setting_week(v_s.key, v_today), v_today);
    end if;
    v_now_text := public.setting_text(v_s.key, public.setting_on(v_s.key, v_today));
    v_then_text := public.setting_text(v_s.key, public.setting_on(v_s.key, v_on));
    v_title := 'The ' || v_what || ' change on ' || public.fmt_date(v_on) || ' is cancelled';
    v_type := case when v_s.key = 'deposit_cap_cents' then 'cap_change' else 'rate_change' end::public.notification_type;
    v_prefix := case when v_s.key = 'deposit_cap_cents' then 'cap_change:'
                     when v_s.key like 'dividend_yield:%' then 'yield_change:' end;
  end if;
  if v_lower is not null then
    raise exception '%', public.cut_notice_message(v_what, v_lower, true);
  end if;

  -- One notice to each kid who was told about the change, and nobody else.
  v_body := concat_ws(' ', public.as_sentence(p_note),
    case when v_then_text is not distinct from v_now_text
         then 'The ' || v_what || ' stays at ' || v_now_text || '.'
         else 'On ' || public.fmt_date(v_on) || ' the ' || v_what || ' will be ' || v_then_text || '.' end);
  for v_account in
    select distinct n.account_id from public.notifications n
     where (p_kind = 'rate' and n.related_rate_id = v_r.id and n.type = 'rate_change'
            and n.dedupe_key like 'rate_change:%')
        or (p_kind = 'setting' and v_prefix is not null and n.dedupe_key like v_prefix || v_s.id || ':%')
     order by 1
  loop
    perform public.notify(v_account, v_type, v_title, v_body,
      'cancel:' || p_kind || ':' || p_id || ':' || v_account,
      p_rate_id => case when p_kind = 'rate' then v_r.id end);
    v_told := v_told + 1;
  end loop;

  select pa.summary into v_summary from public.parent_actions pa
   where pa.action = case when p_kind = 'rate' then 'add_rate' else 'set_setting' end and pa.target_id = p_id
   order by pa.id desc limit 1;
  perform public.log_parent_action('cancel_change', null, p_id,
    'Cancelled: ' || coalesce(v_summary, p_kind || ' change #' || p_id || '.'),
    jsonb_build_object('kind', p_kind, 'id', p_id, 'note', nullif(btrim(coalesce(p_note, '')), ''),
                       'kids_told', v_told));
  return v_id;
end;
$$;

-- 3. Rewording notes and glossary explanations -------------------------------------------------------

-- Reword a market-move note that's already written (the girls see it on the fund's
-- graph). The standard wording for future notes is a setting (set_setting).
create function public.edit_note(p_note_id bigint, p_body text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_note public.notes;
  v_body text := btrim(coalesce(p_body, ''));
begin
  perform public.require_parent();
  select * into v_note from public.notes n where n.id = p_note_id for update;
  if not found then
    raise exception 'There''s no note #%.', p_note_id;
  end if;
  if v_body = '' or length(v_body) > 300 then
    raise exception 'The note needs some words, and at most 300 letters.';
  end if;
  if v_body = v_note.body then
    raise exception 'That''s the same wording as now.';
  end if;

  update public.notes set body = v_body where id = v_note.id;
  perform public.log_parent_action('edit_note', null, v_note.id,
    'Reworded the '
      || coalesce((select f.name from public.funds f where f.id = v_note.fund_id) || ' ', '')
      || 'note for ' || public.fmt_date(v_note.note_date) || '.',
    jsonb_build_object('fund_id', v_note.fund_id, 'note_date', v_note.note_date,
                       'before', v_note.body, 'after', v_body));
  return v_note.id;
end;
$$;

-- Reword a ? explanation. Terms are fixed (the app asks for them by name); only
-- the wording changes.
create function public.edit_glossary(p_term text, p_text text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_g public.glossary;
  v_text text := btrim(coalesce(p_text, ''));
begin
  perform public.require_parent();
  select * into v_g from public.glossary g where g.term = p_term for update;
  if not found then
    raise exception 'There''s no "%" in the glossary.', p_term;
  end if;
  if v_text = '' or length(v_text) > 400 then
    raise exception 'The explanation needs some words, and at most 400 letters.';
  end if;
  if v_text = v_g.kid_text then
    raise exception 'That''s the same wording as now.';
  end if;

  update public.glossary set kid_text = v_text where term = v_g.term;
  perform public.log_parent_action('edit_glossary', null, null,
    'Reworded the explanation of "' || v_g.term || '".',
    jsonb_build_object('term', v_g.term, 'before', v_g.kid_text, 'after', v_text));
  return v_g.term;
end;
$$;

-- 2. Previews ---------------------------------------------------------------------------------------

-- A setting's value in words: "$1,000.00", "2.0%", "7 days", "Test accounts only".
create function public.setting_text(p_key text, p_value text)
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
    else p_value
  end;
$$;

-- The girls' notices written since p_after, grouped by wording, each saying when
-- it arrives (p_on; null = right away). p_rate_id keeps only that rate's notices;
-- p_key_like only notices whose dedupe key matches.
create function public.preview_notices(p_after bigint, p_on text, p_rate_id bigint default null,
                                       p_key_like text default null)
returns jsonb
language sql stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('title', x.title, 'body', x.body, 'kids', x.kids, 'on', p_on)
                            order by x.first), '[]'::jsonb)
    from (select n.title, n.body, count(*) as kids, min(n.id) as first
            from public.notifications n
           where n.id > p_after and (p_rate_id is null or n.related_rate_id = p_rate_id)
             and (p_key_like is null or n.dedupe_key like p_key_like)
           group by n.title, n.body) x;
$$;

drop function public.parent_change_preview(text, jsonb);

-- What a Settings change would do, without doing it: runs the real (logged) action
-- with in_preview() on, captures the girls' notices and the log line, then always
-- rolls it all back. A change that starts on a later day also dry-runs that day's
-- notice (and, for a special, the one the day after it ends).
--   set_setting   {key, value, effective_date, note}
--   add_rate      {vehicle, gic_term, rate, effective_date, end_date, note}
--   edit_note     {note_id, body}
--   edit_glossary {term, text}
--   cancel_change {kind: rate | setting, id, note}
-- Returns {problem, summary, notices: [{title, body, kids, on}], facts}.
create function public.parent_change_preview(p_action text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was text := coalesce(current_setting('bigbucks.preview', true), '');
  v_today date := public.app_today();
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_last_notice bigint;
  v_last_action bigint;
  v_mark bigint;
  v_id bigint;
  v_key text;
  v_effective date;
  v_end date;
  v_before text;
  v_vehicle public.vehicle;
  v_term integer;
  v_old numeric;
  v_s public.settings;
  v_r public.rates;
  v_problem text;
  v_notices jsonb := '[]'::jsonb;
  v_facts jsonb;
  v_summary text;
begin
  perform public.require_parent();
  if p_action is null or p_action not in ('set_setting', 'add_rate', 'edit_note', 'edit_glossary', 'cancel_change') then
    raise exception 'There''s no preview for "%".', p_action;
  end if;

  select coalesce(max(n.id), 0) into v_last_notice from public.notifications n;
  select coalesce(max(pa.id), 0) into v_last_action from public.parent_actions pa;

  begin
    perform set_config('bigbucks.preview', 'on', true);

    if p_action = 'set_setting' then
      v_key := btrim(coalesce(v_args ->> 'key', ''));
      v_effective := nullif(v_args ->> 'effective_date', '')::date;
      v_before := coalesce(public.setting_on(v_key, coalesce(v_effective, v_today)),
                           case when v_key like 'feature:%' then 'off' end);  -- no switch yet means off
      v_id := public.set_setting(v_args ->> 'key', v_args ->> 'value', v_effective, v_args ->> 'note');
      select * into v_s from public.settings s where s.id = v_id;
      v_notices := public.preview_notices(v_last_notice, null);
      if v_s.key = 'request_expiry_days' and v_s.effective_date > v_today then
        select coalesce(max(n.id), 0) into v_mark from public.notifications n;
        perform public.send_expiry_notices(v_id);
        v_notices := v_notices || public.preview_notices(v_mark, public.fmt_date(v_s.effective_date));
      end if;
      if v_s.key like 'dividend_yield:%' and v_s.effective_date > v_today then
        select coalesce(max(n.id), 0) into v_mark from public.notifications n;
        perform public.send_rate_notices(v_s.effective_date);
        v_notices := v_notices || public.preview_notices(v_mark, public.fmt_date(v_s.effective_date), null,
                                                         'yield_live:' || v_id || ':%');
      end if;
      v_facts := jsonb_build_object('before', public.setting_text(v_s.key, v_before),
                                    'after', public.setting_text(v_s.key, v_s.value),
                                    'from', public.fmt_date(v_s.effective_date));

    elsif p_action = 'add_rate' then
      if coalesce(v_args ->> 'vehicle', '') not in ('savings', 'gic') then
        raise exception 'Rates are only for savings and GICs.';
      end if;
      if coalesce(v_args ->> 'rate', '') !~ '^\d{1,2}(\.\d+)?$' then
        raise exception 'Type the rate as a percent, like 2.5.';
      end if;
      v_vehicle := (v_args ->> 'vehicle')::public.vehicle;
      v_term := nullif(v_args ->> 'gic_term', '')::integer;
      v_effective := coalesce(nullif(v_args ->> 'effective_date', '')::date, v_today + 7);
      v_end := nullif(v_args ->> 'end_date', '')::date;
      -- The rate before the change, as her notice words it.
      v_old := (public.rate_on(v_vehicle, v_term, v_effective - 1)).rate;
      v_id := public.add_rate(v_vehicle, v_term, (v_args ->> 'rate')::numeric, v_effective,
                              v_args ->> 'note', v_end);
      select * into v_r from public.rates r where r.id = v_id;
      v_notices := public.preview_notices(v_last_notice, null);
      if v_r.effective_date > v_today then
        select coalesce(max(n.id), 0) into v_mark from public.notifications n;
        perform public.send_rate_notices(v_r.effective_date);
        v_notices := v_notices || public.preview_notices(v_mark, public.fmt_date(v_r.effective_date), v_id);
      end if;
      if v_r.is_special then
        select coalesce(max(n.id), 0) into v_mark from public.notifications n;
        perform public.send_rate_notices(v_r.end_date + 1);
        v_notices := v_notices || public.preview_notices(v_mark, public.fmt_date(v_r.end_date + 1), v_id);
      end if;
      v_facts := jsonb_build_object(
        'what', case when v_r.vehicle = 'savings' then 'Savings' else public.term_label(v_r.gic_term) || ' GIC' end,
        'before', case when v_old is not null then public.fmt_rate(v_old) end,
        'after', public.fmt_rate(v_r.rate),
        'from', public.fmt_date(v_r.effective_date),
        'special', v_r.is_special,
        'to', case when v_r.is_special then public.fmt_date(v_r.end_date) end,
        'back_to', case when v_r.is_special
                        then public.fmt_rate((public.rate_on(v_r.vehicle, v_r.gic_term, v_r.end_date + 1)).rate) end);

    elsif p_action = 'cancel_change' then
      v_id := public.cancel_change(v_args ->> 'kind', nullif(v_args ->> 'id', '')::bigint, v_args ->> 'note');
      v_notices := public.preview_notices(v_last_notice, null);

    elsif p_action = 'edit_note' then
      select n.body into v_before from public.notes n where n.id = nullif(v_args ->> 'note_id', '')::bigint;
      perform public.edit_note(nullif(v_args ->> 'note_id', '')::bigint, v_args ->> 'body');
      v_facts := jsonb_build_object('before', v_before, 'after', btrim(v_args ->> 'body'));

    else
      select g.kid_text into v_before from public.glossary g where g.term = v_args ->> 'term';
      perform public.edit_glossary(v_args ->> 'term', v_args ->> 'text');
      v_facts := jsonb_build_object('before', v_before, 'after', btrim(v_args ->> 'text'));
    end if;

    select pa.summary into v_summary from public.parent_actions pa
     where pa.id > v_last_action order by pa.id desc limit 1;
    raise exception 'preview only' using errcode = 'BB000';
  exception
    when sqlstate 'BB000' then v_problem := null;
    when others then
      v_problem := sqlerrm;
      v_notices := '[]'::jsonb;
      v_facts := null;
      v_summary := null;
  end;
  perform set_config('bigbucks.preview', v_was, true);

  return jsonb_build_object('problem', v_problem, 'summary', v_summary, 'notices', v_notices, 'facts', v_facts);
end;
$$;
comment on function public.parent_change_preview(text, jsonb) is
  'Settings: what a change would do (the real action, rolled back, in_preview on). Parent with MFA only.';

-- 3. What the Settings screen shows ---------------------------------------------------------------------

create function public.is_cancelled_setting(p_id bigint)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.cancellations c where c.setting_id = p_id);
$$;
create function public.is_cancelled_rate(p_id bigint)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.cancellations c where c.rate_id = p_id);
$$;

-- One dated setting: the value in force today, changes scheduled for later (the
-- newest row for each day that isn't cancelled, with its id for Cancel), and every
-- row with who saved it and when (from the log), cancelled ones marked.
create function public.setting_card(p_key text, p_today date, p_default text default null)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'key', p_key,
    'value', coalesce(public.setting_on(p_key, p_today), p_default),
    'text', public.setting_text(p_key, coalesce(public.setting_on(p_key, p_today), p_default)),
    'scheduled', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'value', s.value, 'text', public.setting_text(p_key, s.value),
                                          'from', public.fmt_date(s.effective_date))
                       order by s.effective_date, s.id)
        from public.settings s
       where s.key = p_key and s.effective_date > p_today
         and s.id = (select s2.id from public.settings s2 where s2.key = s.key and s2.effective_date = s.effective_date
                        and not public.is_cancelled_setting(s2.id)
                      order by s2.id desc limit 1)), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'value', s.value, 'text', public.setting_text(p_key, s.value),
               'from', public.fmt_date(s.effective_date), 'note', s.note,
               'cancelled', public.is_cancelled_setting(s.id),
               'who', coalesce(p.display_name, case when pa.id is null then 'Starting rule' end),
               'when', public.fmt_moment(pa.done_at))
             order by s.id desc)
        from public.settings s
        left join public.parent_actions pa on pa.action = 'set_setting' and pa.target_id = s.id
        left join public.profiles p on p.user_id = pa.done_by
       where s.key = p_key), '[]'::jsonb));
$$;

-- A rate row in words: "1.5%", or "6.0% special, Nov 1 to Nov 7".
create function public.rate_row_text(r public.rates)
returns text
language sql immutable
set search_path = ''
as $$
  select public.fmt_rate(r.rate)
         || case when r.is_special then ' special, ' || public.fmt_date(r.effective_date) || ' to ' || public.fmt_date(r.end_date)
                 else ' from ' || public.fmt_date(r.effective_date) end;
$$;

-- The features that have a switch. A stage that adds a feature adds it here.
create function public.feature_list()
returns table (name text, sort_order integer)
language sql immutable
set search_path = ''
as $$
  values ('wishlist', 1), ('personalisation', 2), ('badges', 3);
$$;

drop function public.parent_settings();

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

    -- B1's request-expiry block, plus ids for Cancel and cancelled rows marked.
    'expiry', jsonb_build_object(
      'days', public.setting_on('request_expiry_days', v_today)::integer,
      'min', 3, 'max', 30,
      'scheduled', coalesce((
        select jsonb_agg(jsonb_build_object('id', s.id, 'days', s.value::integer, 'from', public.fmt_date(s.effective_date))
                         order by s.effective_date, s.id)
          from public.settings s
         where s.key = 'request_expiry_days' and s.effective_date > v_today
           and s.id = (select s2.id from public.settings s2 where s2.key = s.key and s2.effective_date = s.effective_date
                          and not public.is_cancelled_setting(s2.id)
                        order by s2.id desc limit 1)), '[]'::jsonb),
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'days', s.value::integer, 'from', public.fmt_date(s.effective_date), 'note', s.note,
                 'cancelled', public.is_cancelled_setting(s.id),
                 'who', coalesce(p.display_name, case when pa.id is null then 'Starting rule' end),
                 'when', public.fmt_moment(pa.done_at))
               order by s.id desc)
          from public.settings s
          left join public.parent_actions pa on pa.action = 'set_setting' and pa.target_id = s.id
          left join public.profiles p on p.user_id = pa.done_by
         where s.key = 'request_expiry_days'), '[]'::jsonb)),

    -- Rates: a new change starts 7 days from today unless Dad picks another day; a
    -- special runs a week (to 13 days from today) unless he picks another end.
    'rate_from', v_today + 7,
    -- A cut can't start before this day (7 days' notice); a raise can start today.
    'cut_from_text', public.fmt_date(v_today + 7),
    'rate_to', v_today + 13,
    'rates', (
      select jsonb_agg(jsonb_build_object(
               'vehicle', o.vehicle, 'gic_term', o.term,
               'what', case when o.vehicle = 'savings' then 'Savings' else public.term_label(o.term) || ' GIC' end,
               'rate', trim_scale(now_r.rate)::text,
               'text', public.fmt_rate(now_r.rate),
               'special_to', case when now_r.is_special then public.fmt_date(now_r.end_date) end,
               'regular', case when now_r.is_special then (
                   select public.fmt_rate(r.rate) from public.rates r
                    where r.vehicle = o.vehicle and r.gic_term is not distinct from o.term
                      and not r.is_special and r.effective_date <= v_today
                      and not public.is_cancelled_rate(r.id)
                    order by r.effective_date desc, r.id desc limit 1) end,
               'scheduled', coalesce((
                 select jsonb_agg(jsonb_build_object('id', r.id, 'text', public.rate_row_text(r), 'special', r.is_special,
                                                    'from', public.fmt_date(r.effective_date))
                                  order by r.effective_date, r.id)
                   from public.rates r
                  where r.vehicle = o.vehicle and r.gic_term is not distinct from o.term and r.effective_date > v_today
                    and not public.is_cancelled_rate(r.id)
                    and (r.is_special or r.id = (
                      select r2.id from public.rates r2
                       where r2.vehicle = r.vehicle and r2.gic_term is not distinct from r.gic_term
                         and not r2.is_special and r2.effective_date = r.effective_date
                         and not public.is_cancelled_rate(r2.id)
                       order by r2.id desc limit 1))), '[]'::jsonb))
             order by o.ord)
        from (values ('savings'::public.vehicle, null::integer, 0), ('gic', 1, 1), ('gic', 3, 2), ('gic', 6, 3),
                     ('gic', 9, 4), ('gic', 12, 5), ('gic', 24, 6)) o (vehicle, term, ord)
        cross join lateral (
          select r.* from public.rates r where r.id = (public.rate_on(o.vehicle, o.term, v_today)).rate_id) now_r),
    'rate_history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'what', case when r.vehicle = 'savings' then 'Savings' else public.term_label(r.gic_term) || ' GIC' end,
               'text', public.rate_row_text(r), 'special', r.is_special, 'note', r.note,
               'cancelled', public.is_cancelled_rate(r.id),
               'who', coalesce(p.display_name, case when pa.id is null then 'Starting rate' end),
               'when', public.fmt_moment(pa.done_at))
             order by r.id desc)
        from public.rates r
        left join public.parent_actions pa on pa.action = 'add_rate' and pa.target_id = r.id
        left join public.profiles p on p.user_id = pa.done_by), '[]'::jsonb),

    'cap', public.setting_card('deposit_cap_cents', v_today),
    'inflation', public.setting_card('inflation_rate', v_today),
    'yields', (
      select jsonb_agg(jsonb_build_object('fund_id', f.id, 'name', f.name,
                                          'card', public.setting_card('dividend_yield:' || f.id, v_today))
                       order by f.sort_order)
        from public.funds f),
    'features', (
      select jsonb_agg(jsonb_build_object('name', x.name, 'card', public.setting_card('feature:' || x.name, v_today, 'off'))
                       order by x.sort_order, x.name)
        from (select fl.name, fl.sort_order from public.feature_list() fl
              union
              select distinct substr(s.key, length('feature:') + 1), 99 from public.settings s
               where s.key like 'feature:%'
                 and substr(s.key, length('feature:') + 1) not in (select fl2.name from public.feature_list() fl2)) x),
    'note_up', public.setting_card('market_move_note_up', v_today),
    'note_down', public.setting_card('market_move_note_down', v_today),
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object('id', n.id, 'date', public.fmt_date(n.note_date),
                                          'fund', f.name, 'body', n.body, 'for_kids', n.audience = 'kids')
                       order by n.note_date desc, n.id desc)
        from (select * from public.notes order by note_date desc, id desc limit 30) n
        left join public.funds f on f.id = n.fund_id), '[]'::jsonb),
    'notes_total', (select count(*) from public.notes),
    'glossary', coalesce((
      select jsonb_agg(jsonb_build_object('term', g.term, 'text', g.kid_text) order by lower(g.term))
        from public.glossary g), '[]'::jsonb),
    -- The latest Settings changes, newest first, with who and when.
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('summary', x.summary, 'who', coalesce(p.display_name, 'Parent'),
                                          'when', public.fmt_moment(x.done_at))
                       order by x.id desc)
        from (select * from public.parent_actions pa
               where pa.action in ('add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change')
               order by pa.id desc limit 10) x
        left join public.profiles p on p.user_id = x.done_by), '[]'::jsonb));
end;
$$;
comment on function public.parent_settings() is 'Settings screen: current values, scheduled changes and history. Parent with MFA only.';

-- Who may call them ---------------------------------------------------------------------------------

revoke all on function public.edit_note(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.cancel_change(text, bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.fund_label(text) from public, anon, authenticated, service_role;
revoke all on function public.rate_week(public.vehicle, integer, date) from public, anon, authenticated, service_role;
revoke all on function public.setting_week(text, date) from public, anon, authenticated, service_role;
revoke all on function public.first_lower_day(numeric[], numeric[], date) from public, anon, authenticated, service_role;
revoke all on function public.cut_notice_message(text, date, boolean) from public, anon, authenticated, service_role;
revoke all on function public.send_yield_notices(bigint) from public, anon, authenticated, service_role;
revoke all on function public.is_cancelled_setting(bigint) from public, anon, authenticated, service_role;
revoke all on function public.is_cancelled_rate(bigint) from public, anon, authenticated, service_role;
grant execute on function public.cancel_change(text, bigint, text) to authenticated;
revoke all on function public.edit_glossary(text, text) from public, anon, authenticated, service_role;
revoke all on function public.setting_text(text, text) from public, anon, authenticated, service_role;
revoke all on function public.preview_notices(bigint, text, bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.setting_card(text, date, text) from public, anon, authenticated, service_role;
revoke all on function public.rate_row_text(public.rates) from public, anon, authenticated, service_role;
revoke all on function public.feature_list() from public, anon, authenticated, service_role;
revoke all on function public.parent_change_preview(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.parent_settings() from public, anon, authenticated, service_role;
grant execute on function public.edit_note(bigint, text) to authenticated;
grant execute on function public.edit_glossary(text, text) to authenticated;
grant execute on function public.parent_change_preview(text, jsonb) to authenticated;
grant execute on function public.parent_settings() to authenticated;
