-- Block 1, item 4 (Dad, approved 2026-11-24; wording 2026-11-27): a passed deadline shows straight
-- away, not only after the evening run. Read-only: nothing here posts, moves or holds money.
--
-- The two deadlines the evening run acts on, each already refused by the database from the deadline
-- itself (not from the run):
--   a matured GIC's choice: choose_maturity refuses from the start of choice_ends;
--   a deposit or withdrawal's days: approve_request refuses from expires_at.
-- (The sweep found one more, a late Decline, which isn't refused yet: on the Jan 2 list, since
--  Decline releases a hold. The app greys it out now.)
--
-- 1. gic_positions gains choice_over (last column). Grants restated.
-- 2. expire_ran_today(): has tonight's request expiry already run? The run expires requests once per
--    evening, so one that runs out after it is cancelled the next evening, not "tonight".
-- 3. trade_options (from 20261113020000_price_fix_words.sql) gains expired and cancels_tonight on
--    each waiting request.
-- 4. parent_inbox (from 20261012000000_request_expiry_dashboard.sql) gains the same two.
-- Time comes from app_today() / app_now(), never the phone. Known answers:
-- supabase/tests/passed_deadlines_test.sql.

-- 1. gic_positions ---------------------------------------------------------------------------------

create or replace view public.gic_positions with (security_invoker = true) as
select g.id as gic_id,
       g.account_id,
       g.principal_cents,
       g.rate,
       g.rate_id,
       g.term_months,
       g.start_date,
       g.maturity_date,
       g.status,
       g.maturity_choice,
       g.renewed_from_id,
       coalesce(b.balance_cents, 0)::bigint as balance_cents,
       public.gic_interest_cents(g.principal_cents, g.rate, g.term_months) as interest_at_maturity_cents,
       case when g.status = 'active'
            then public.gic_interest_so_far_cents(g.principal_cents, g.rate, g.term_months,
                                                  g.start_date, g.maturity_date, public.app_today()) end
         as interest_so_far_cents,
       case when g.status = 'matured' and g.maturity_choice is null then g.choice_ends - 1 end as choose_by,
       -- Block 1, item 4: her days to choose are over (from the midnight that starts choice_ends,
       -- when choose_maturity starts refusing); the evening run moves it to savings.
       coalesce(g.status = 'matured' and g.maturity_choice is null
                and public.app_today() >= g.choice_ends, false) as choice_over
  from public.gic_holdings g
  left join lateral (
    select sum(t.amount_cents) as balance_cents
      from public.transactions t
     where t.gic_id = g.id and t.vehicle = 'gic') b on true;


revoke all on table public.gic_positions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.gic_positions to authenticated, service_role, backup_reader;

-- 2. Has today's request expiry already run? -------------------------------------------------------

create function public.expire_ran_today()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.job_runs jr
                  where jr.job = 'expire' and jr.run_for_date = public.app_today() and jr.status = 'ok');
$$;
comment on function public.expire_ran_today() is
  'Block 1, item 4: true once tonight''s request expiry has run, so a request that ran out of time after it is cancelled tomorrow evening. Read-only.';
revoke all on function public.expire_ran_today() from public, anon, authenticated, service_role;
grant execute on function public.expire_ran_today() to authenticated, service_role;

-- 3. trade_options ---------------------------------------------------------------------------------

create or replace function public.trade_options(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_now timestamptz := public.app_now();
  v_bal record;
  v_funds jsonb;
  v_gics jsonb;
  v_rates jsonb;
  v_waiting jsonb;
  v_expire_ran boolean := public.expire_ran_today();
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  select b.savings_cents, b.held_cents, b.available_cents, b.cap_cents, b.cap_room_cents
    into v_bal from public.account_balances b where b.account_id = p_account_id;

  -- Each fund, held or not. "Sellable" matches request_trade's own limit (whole cents, rounded down).
  select jsonb_agg(jsonb_build_object(
           'fund_id', fu.id,
           'name', fu.name,
           'colour', fu.colour,
           'units', coalesce(fp.units, 0),
           'available_units', coalesce(fp.available_units, 0),
           'value_cents', coalesce(fp.value_cents, 0),
           'cost_cents', coalesce(fp.cost_cents, 0),
           'gain_cents', coalesce(fp.gain_cents, 0),
           -- Change (2b review): her free units' value to the nearest cent, as shown
           -- everywhere; typing it sells them all (sell_amount_is_all).
           'sellable_cents', coalesce(round(fp.available_units * fp.latest_close * 100), 0)::bigint,
           'traded_today', exists (
              select 1 from public.requests r
               where r.account_id = p_account_id and r.fund_id = fu.id and r.type = 'move'
                 and r.status in ('pending', 'settled')
                 and public.edmonton_local(r.created_at)::date = v_today),
           'settles', public.fmt_close(public.next_settlement(fu.id)))
         order by fu.sort_order)
    into v_funds
    from public.funds fu
    left join public.fund_positions fp on fp.fund_id = fu.id and fp.account_id = p_account_id;

  -- Active GICs, with what breaking each today would give up.
  select jsonb_agg(jsonb_build_object(
           'gic_id', g.gic_id,
           'term_months', g.term_months,
           'rate', g.rate,
           'principal_cents', g.principal_cents,
           'balance_cents', g.balance_cents,
           'start_date', g.start_date,
           'maturity_date', g.maturity_date,
           'interest_so_far_cents', g.interest_so_far_cents,
           'interest_at_maturity_cents', g.interest_at_maturity_cents,
           'can_break', g.maturity_date > v_today)
         order by g.maturity_date, g.gic_id)
    into v_gics
    from public.gic_positions g
   where g.account_id = p_account_id and g.status = 'active';

  select jsonb_agg(jsonb_build_object(
           'term_months', cr.gic_term, 'rate', cr.rate, 'is_special', cr.is_special,
           'special_ends', cr.special_ends) order by cr.gic_term)
    into v_rates
    from public.current_rates() cr
   where cr.vehicle = 'gic' and cr.rate is not null;

  -- Her waiting requests, oldest first.
  select jsonb_agg(jsonb_build_object(
           'request_id', r.id,
           'type', r.type,
           'from_vehicle', r.from_vehicle,
           'to_vehicle', r.to_vehicle,
           'fund_id', r.fund_id,
           'amount_cents', r.amount_cents,
           'sell_all', r.sell_all,
           'on_day', public.edmonton_local(r.created_at)::date,
           'approve_from', case when r.type = 'withdraw' and v_now < r.created_at + interval '24 hours'
                                then public.fmt_moment(r.created_at + interval '24 hours') end,
           'settles', case when r.fund_id is not null
                           then public.fmt_close(public.next_settlement(r.fund_id, r.created_at)) end,
           'waiting_words', case when r.fund_id is not null then public.waiting_words(r.fund_id, r.created_at) end,
           -- Block 1, item 4: past its days (approve_request refuses from expires_at). The run
           -- cancels it tonight, or tomorrow evening if tonight's expiry has already run.
           'expired', r.type in ('deposit', 'withdraw') and v_now >= r.expires_at,
           'cancels_tonight', not v_expire_ran)
         order by r.created_at, r.id)
    into v_waiting
    from public.requests r
   where r.account_id = p_account_id and r.status = 'pending';

  return jsonb_build_object(
    'today', v_today,
    'updating', public.figures_updating(p_account_id),
    'savings_cents', v_bal.savings_cents,
    'held_cents', v_bal.held_cents,
    'available_cents', v_bal.available_cents,
    'cap_cents', v_bal.cap_cents,
    'cap_room_cents', v_bal.cap_room_cents,
    'funds', coalesce(v_funds, '[]'::jsonb),
    'gics', coalesce(v_gics, '[]'::jsonb),
    'gic_rates', coalesce(v_rates, '[]'::jsonb),
    'waiting', coalesce(v_waiting, '[]'::jsonb));
end;
$$;


-- 4. parent_inbox ----------------------------------------------------------------------------------

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
  v_expire_ran boolean := public.expire_ran_today();
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
           'expired', v_now >= r.expires_at,
           'cancels_tonight', not v_expire_ran,
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


-- create or replace keeps grants; restated so this file says who may call them.
revoke all on function public.trade_options(uuid) from public, anon, authenticated, service_role;
grant execute on function public.trade_options(uuid) to authenticated, service_role;
revoke all on function public.parent_inbox() from public, anon, authenticated, service_role;
grant execute on function public.parent_inbox() to authenticated;
