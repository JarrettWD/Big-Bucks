-- Stage 7 (Dad's decision at the 2b review): selling a fund by typing what it's
-- shown to be worth sells all of it.
--
-- Her units' value is shown rounded to the nearest cent (Home, Buy / Sell and the
-- warnings). Before, typing that value could be refused by a fraction of a cent
-- ("worth about $57.29" while $57.30 was shown) and, when accepted, could leave a
-- sliver of units behind. Now:
--   - the shown value (or anything up to the exact value, when that is a fraction
--     of a cent higher) sells all
--     of her units: the request becomes "sell all";
--   - more than that is refused, quoting the shown value;
--   - Buy / Sell shows the shown value (trade_options.sellable_cents), and the
--     preview says when an amount sells everything (warning code sells_all).
-- Sell all pays units × the close, rounded up, so at the same price it pays at
-- least the shown value. If the price falls before the close, it pays less.
--
-- Recreated from their latest versions with only these changes: request_trade
-- (20261006000000_alberta_time.sql), trade_options and move_preview
-- (20261007000000_buy_sell.sql). create or replace keeps grants and comments.

-- Does typing this amount mean "sell all"? The shown value (nearest cent), or more
-- up to the exact value when that is a fraction of a cent higher.
create function public.sell_amount_is_all(p_units numeric, p_close numeric, p_amount_cents bigint)
returns boolean
language sql immutable
set search_path = ''
as $$
  select p_amount_cents is not null and p_units > 0 and p_close > 0
     and p_amount_cents >= round(p_units * p_close * 100)
     and p_amount_cents <= greatest(round(p_units * p_close * 100), p_units * p_close * 100);
$$;

comment on function public.sell_amount_is_all(numeric, numeric, bigint) is
  'True when a sale amount is her units'' shown value (nearest cent), or up to their exact value when that is higher: it sells all.';

revoke all on function public.sell_amount_is_all(numeric, numeric, bigint) from public, anon, authenticated, service_role;

-- request_trade: from 20261006000000_alberta_time.sql (2 changes, marked)
create or replace function public.request_trade(p_fund_id text, p_side text, p_amount_cents bigint default null,
                                     p_sell_all boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_fund public.funds;
  v_available bigint;
  v_units numeric;
  v_close numeric;
  v_hold numeric;
  v_id bigint;
  v_sell_all boolean := coalesce(p_sell_all, false);
  v_amount bigint := p_amount_cents;
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_side is null or p_side not in ('buy', 'sell') then
    raise exception 'Choose buy or sell.';
  end if;
  if coalesce(p_sell_all, false) then
    if p_side = 'buy' then
      raise exception '"Sell all" is only for selling.';
    end if;
    if p_amount_cents is not null then
      raise exception 'Choose an amount or "sell all", not both.';
    end if;
  elsif p_amount_cents is null or p_amount_cents < 1000 then
    raise exception 'The smallest trade is $10.00.';
  end if;

  if exists (select 1 from public.requests r
              where r.account_id = v_account and r.fund_id = p_fund_id and r.type = 'move'
                and r.status in ('pending', 'settled')
                and public.edmonton_local(r.created_at)::date = public.app_today()) then
    raise exception 'You''ve already traded the % fund today. You can trade it again tomorrow.', v_fund.name;
  end if;

  if p_side = 'buy' then
    v_available := public.vehicle_cents(v_account, 'savings') - public.held_cents(v_account);
    if p_amount_cents > v_available then
      raise exception 'You have % available.', public.fmt_money(v_available);
    end if;
    insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, held_cents)
    values (v_account, 'move', 'savings', 'stock', p_fund_id, p_amount_cents, p_amount_cents)
    returning id into v_id;
    return v_id;
  end if;

  v_units := public.fund_units(v_account, p_fund_id) - public.held_units(v_account, p_fund_id);
  if v_units <= 0 then
    raise exception 'You don''t have any % units to sell.', v_fund.name;
  end if;

  if coalesce(p_sell_all, false) then
    v_hold := v_units;
  else
    select fp.close into v_close from public.fund_prices fp
     where fp.fund_id = p_fund_id and fp.price_date <= public.app_today()
     order by fp.price_date desc limit 1;
    if v_close is null then
      raise exception 'There''s no price for the % fund yet, so it can''t be sold by amount.', v_fund.name;
    end if;
    -- Change 1 (2b review): the shown value (nearest cent), or up to the exact value
    -- if that is higher, sells all; above that is refused, quoting the shown value.
    if public.sell_amount_is_all(v_units, v_close, p_amount_cents) then
      v_sell_all := true;
      v_amount := null;
      v_hold := v_units;
    elsif p_amount_cents > v_units * v_close * 100 then
      raise exception 'Your % units are worth about %, so you can sell up to that (or choose "sell all").',
        v_fund.name, public.fmt_money(round(v_units * v_close * 100));
    else
      -- Hold the units the amount needs at the latest close. If the price falls by
      -- the close, settlement sells what she has (see settle_trades).
      v_hold := least(v_units, public.round_up_units(p_amount_cents / 100.0 / v_close));
    end if;
  end if;

  -- Change 2: the request records "sell all" when the amount meant it.
  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all, held_units)
  values (v_account, 'move', 'stock', 'savings', p_fund_id, v_amount, v_sell_all, v_hold)
  returning id into v_id;
  return v_id;
end;
$$;

-- trade_options: from 20261007000000_buy_sell.sql (1 change, marked)
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

-- move_preview: from 20261007000000_buy_sell.sql (1 change, marked)
create or replace function public.move_preview(p_kind text, p_amount_cents bigint default null, p_fund_id text default null,
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
      select fp.value_cents, fp.cost_cents, fp.gain_cents, fp.available_units, fp.latest_close into v_pos
        from public.fund_positions fp where fp.account_id = v_account and fp.fund_id = p_fund_id;
      if found and v_pos.gain_cents < 0 then
        v_warnings := v_warnings || jsonb_build_object('code', 'fund_below_cost',
          'value_cents', v_pos.value_cents, 'cost_cents', v_pos.cost_cents, 'loss_cents', -v_pos.gain_cents);
      end if;
      -- Change (2b review): an amount that means "all of it" says so.
      if found and not coalesce(p_sell_all, false)
         and public.sell_amount_is_all(v_pos.available_units, v_pos.latest_close, p_amount_cents) then
        v_warnings := v_warnings || jsonb_build_object('code', 'sells_all');
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
