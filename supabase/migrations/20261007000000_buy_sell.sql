-- Stage 7 part 2a: what the Buy / Sell screen reads. Nothing here posts money or
-- changes an engine rule.
--
--   fmt_close(close)          "today's 2:00 pm close", "Monday's 3:00 pm close (Nov 2)"
--   trade_options(account)    everything the screen needs before she types: what's
--                             free to use, deposit room, each fund and GIC, today's
--                             GIC rates, and her waiting requests
--   move_preview(...)         checks one proposed move as she types: the problem she'd
--                             hit (if any), the spec's warnings, when a trade settles,
--                             and what each GIC term would earn
--
-- move_preview runs the real action function (request_deposit, buy_gic, …) inside
-- a sub-transaction and always rolls it back, so the preview and the real action
-- can never disagree about the rules. The one trace it leaves: identity numbers
-- (request and GIC ids) used by the rolled-back insert are skipped. No money, hold,
-- notice or ledger row survives.

-- When a close happens, in words, from today's point of view (Alberta time).
create function public.fmt_close(p_close timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select case l::date - public.app_today()
           when 0 then 'today''s '
           when 1 then 'tomorrow''s '
           when -1 then 'yesterday''s '
           else to_char(l, 'FMDay') || '''s '
         end
         || to_char(l, 'FMHH12:MI am') || ' close'
         || case when abs(l::date - public.app_today()) > 1 then ' (' || public.fmt_date(l::date) || ')' else '' end
    from (select public.edmonton_local(p_close) as l) x;
$$;

comment on function public.fmt_close(timestamptz) is
  'A market close in words, relative to today: "today''s 2:00 pm close", "Monday''s 3:00 pm close (Nov 2)".';

-- Everything the Buy / Sell screen shows before she types ---------------------------------

create function public.trade_options(p_account_id uuid)
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
           'sellable_cents', coalesce(floor(fp.available_units * fp.latest_close * 100), 0)::bigint,
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
                           then public.fmt_close(public.next_settlement(r.fund_id, r.created_at)) end)
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

comment on function public.trade_options(uuid) is
  'Buy / Sell: free to use, deposit room, funds, active GICs, today''s GIC rates and waiting requests.';

-- One proposed move, checked by the real rules ----------------------------------------------
--
-- p_kind: deposit · withdraw · buy_gic · break_gic · buy_fund · sell_fund
-- Returns {kind, problem, warnings, settles, gic_quotes}:
--   problem     the exact message the real action would give, or null when it would go ahead
--   warnings    [{code, …}]: early_break, fund_below_cost, deposit_wait, withdraw_wait, market_price
--   settles     when a fund trade would settle, in words (fmt_close)
--   gic_quotes  (buy_gic) each term: rate, interest on this amount, maturity date
create function public.move_preview(p_kind text, p_amount_cents bigint default null, p_fund_id text default null,
                                    p_gic_id bigint default null, p_term integer default null,
                                    p_sell_all boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.my_account_id();
  v_today date := public.app_today();
  v_problem text;
  v_warnings jsonb := '[]'::jsonb;
  v_settles text;
  v_quotes jsonb;
  v_term integer := p_term;
  v_gic record;
  v_pos record;
begin
  if v_account is null then
    raise exception 'Only a kid''s account can do this.' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('deposit', 'withdraw', 'buy_gic', 'break_gic', 'buy_fund', 'sell_fund') then
    raise exception 'Choose what to do first.';
  end if;

  -- Before she has picked a term, check everything else with any term that has a
  -- rate (only the "no rate for that term" check depends on the term).
  if p_kind = 'buy_gic' and v_term is null then
    select cr.gic_term into v_term from public.current_rates() cr
     where cr.vehicle = 'gic' and cr.rate is not null order by cr.gic_term limit 1;
  end if;

  -- The dry run: the real function, always rolled back.
  begin
    case p_kind
      when 'deposit' then perform public.request_deposit(p_amount_cents);
      when 'withdraw' then perform public.request_withdrawal(p_amount_cents);
      when 'buy_gic' then perform public.buy_gic(p_amount_cents, v_term);
      when 'break_gic' then perform public.break_gic(p_gic_id);
      when 'buy_fund' then perform public.request_trade(p_fund_id, 'buy', p_amount_cents, false);
      when 'sell_fund' then
        perform public.request_trade(p_fund_id, 'sell',
                                     case when coalesce(p_sell_all, false) then null else p_amount_cents end,
                                     coalesce(p_sell_all, false));
    end case;
    raise exception 'preview only' using errcode = 'BB000';
  exception
    when sqlstate 'BB000' then v_problem := null;
    when others then v_problem := sqlerrm;
  end;

  -- The spec's warnings. Facts for the screen to put into words (docs/MESSAGES.md §8).
  if p_kind = 'deposit' then
    v_warnings := v_warnings || jsonb_build_object('code', 'deposit_wait');
  elsif p_kind = 'withdraw' then
    v_warnings := v_warnings || jsonb_build_object('code', 'withdraw_wait',
      'approve_from', public.fmt_moment(public.app_now() + interval '24 hours'));
  elsif p_kind = 'break_gic' then
    select g.interest_so_far_cents, g.interest_at_maturity_cents, g.balance_cents, g.maturity_date
      into v_gic from public.gic_positions g
     where g.gic_id = p_gic_id and g.account_id = v_account and g.status = 'active';
    if found then
      v_warnings := v_warnings || jsonb_build_object('code', 'early_break',
        'lost_cents', v_gic.interest_so_far_cents,
        'at_maturity_cents', v_gic.interest_at_maturity_cents,
        'back_cents', v_gic.balance_cents,
        'maturity_date', v_gic.maturity_date);
    end if;
  elsif p_kind in ('buy_fund', 'sell_fund') and exists (select 1 from public.funds f where f.id = p_fund_id) then
    v_settles := public.fmt_close(public.next_settlement(p_fund_id));
    v_warnings := v_warnings || jsonb_build_object('code', 'market_price', 'settles', v_settles);
    if p_kind = 'sell_fund' then
      select fp.value_cents, fp.cost_cents, fp.gain_cents into v_pos
        from public.fund_positions fp where fp.account_id = v_account and fp.fund_id = p_fund_id;
      if found and v_pos.gain_cents < 0 then
        v_warnings := v_warnings || jsonb_build_object('code', 'fund_below_cost',
          'value_cents', v_pos.value_cents, 'cost_cents', v_pos.cost_cents, 'loss_cents', -v_pos.gain_cents);
      end if;
    end if;
  end if;

  -- What each term would earn on this amount (the same sums buy_gic and maturity use).
  if p_kind = 'buy_gic' and p_amount_cents is not null and p_amount_cents > 0 then
    select jsonb_agg(jsonb_build_object(
             'term_months', cr.gic_term, 'rate', cr.rate, 'is_special', cr.is_special,
             'interest_cents', public.gic_interest_cents(p_amount_cents, cr.rate, cr.gic_term),
             'maturity_date', (v_today + make_interval(months => cr.gic_term))::date)
           order by cr.gic_term)
      into v_quotes
      from public.current_rates() cr
     where cr.vehicle = 'gic' and cr.rate is not null;
  end if;

  return jsonb_build_object('kind', p_kind, 'problem', v_problem, 'warnings', v_warnings,
                            'settles', v_settles, 'gic_quotes', coalesce(v_quotes, '[]'::jsonb));
end;
$$;

comment on function public.move_preview(text, bigint, text, bigint, integer, boolean) is
  'Buy / Sell: checks a proposed move with the real action function (rolled back), plus the spec''s warnings.';

-- Who may call them -------------------------------------------------------------------------------

revoke all on function public.fmt_close(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.trade_options(uuid) from public, anon, authenticated, service_role;
revoke all on function public.move_preview(text, bigint, text, bigint, integer, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.trade_options(uuid) to authenticated, service_role;
grant execute on function public.move_preview(text, bigint, text, bigint, integer, boolean) to authenticated;
