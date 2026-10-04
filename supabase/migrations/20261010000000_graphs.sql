-- Stage 7 part 2c: what the Graphs tab reads. Reads only: no money moves, and no
-- engine function or money rule changes. Every figure and every date is worked out
-- here, so the app only draws what it's given.
--
--   graph_ranges(account)                 today, and where each time range starts
--   growth_by_option(account, from, to)   each day's time-weighted % growth (and $ earned)
--                                         for savings, GICs and each fund
--   money_in_vs_earned(account)           each day's net deposits and total worth
--   my_mix(account)                       her mix today, whole percents adding to 100
--   gic_ladder(account)                   each GIC, from its start to its ready date
--   fund_chart(account, fund, from)       a fund's closes, her buys and sells, the
--                                         market-move notes, and her return
--
-- Total worth over time reads the existing daily_balances.
--
-- Growth is time-weighted (Dad's decision, 2026-10-03): each day's change leaves
-- out money moved in or out, so a deposit, a buy or a GIC bought from savings is
-- never growth. What counts as growth:
--   * savings and GICs: interest (and a penalty, as a loss);
--   * a fund: its value's change, plus the dividends it paid into savings.
-- Each day's growth is measured against the value at the end of the day before
-- (interest and dividends post at the start of a day, and trades settle at the
-- close, after the day's price change). On the first day there's money in an
-- option, it's measured against the money that came in.

-- Ranges ------------------------------------------------------------------------------------------

create function public.graph_ranges(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_first date;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  -- Her first day in Big Bucks: the day of her first ledger line (today if none yet).
  select least(coalesce(min(public.edmonton_local(t.effective_at))::date, v_today), v_today) into v_first
    from public.transactions t where t.account_id = p_account_id;

  return jsonb_build_object(
    'today', v_today,
    'first_day', v_first,
    -- Total worth and growth: never before her first day.
    'worth', jsonb_build_object(
      '1M', greatest((v_today - interval '1 month')::date, v_first),
      '3M', greatest((v_today - interval '3 months')::date, v_first),
      '1Y', greatest((v_today - interval '1 year')::date, v_first),
      'All', greatest(v_first, v_today - 3650)),
    -- A fund's own price goes back before she bought it.
    'fund', jsonb_build_object(
      '1M', (v_today - interval '1 month')::date,
      '3M', (v_today - interval '3 months')::date,
      '6M', (v_today - interval '6 months')::date),
    'first_purchase', (
      select coalesce(jsonb_object_agg(x.fund_id, x.d), '{}'::jsonb)
        from (select t.fund_id, min(public.edmonton_local(t.effective_at))::date as d
                from public.transactions t
               where t.account_id = p_account_id and t.vehicle = 'stock' and t.type = 'transfer_in'
                 and t.effective_at < public.edmonton_start(v_today + 1)
               group by t.fund_id) x),
    'ladder_until', (v_today + interval '24 months')::date);
end;
$$;

comment on function public.graph_ranges(uuid) is
  'Today, her first day, where each graph range starts (1M, 3M, 6M, 1Y, All), each fund''s first purchase, and the GIC ladder''s end.';

-- Growth by option ----------------------------------------------------------------------------------

create function public.growth_by_option(p_account_id uuid, p_from date, p_to date)
returns table (day date, option text, growth_pct numeric, earned_cents bigint, flow_cents bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  r record;
  v_option text := null;
  v_prev bigint;
  v_factor numeric;
  v_earned bigint;
  v_started boolean;
  v_earn bigint;
  v_base bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  for r in
    with db as (
      select * from public.daily_balances(p_account_id, p_from, p_to)
    ),
    opts as (
      select 'savings'::text as option, null::text as fund_id, 0 as ord
      union all select 'gic', null, 1
      union all select fu.id, fu.id, 2 + fu.sort_order from public.funds fu
    ),
    -- Money moved in (+) or out (−) of each option, per day. Not growth.
    flows as (
      select public.edmonton_local(t.effective_at)::date as day,
             case when t.vehicle = 'savings' and t.fund_id is not null
                       and t.type in ('transfer_in', 'transfer_out') then t.fund_id
                  else t.vehicle::text end as option,
             sum(case when t.vehicle = 'savings' and t.fund_id is not null
                           and t.type in ('transfer_in', 'transfer_out') then -t.amount_cents
                      else t.amount_cents end) as flow
        from public.transactions t
       where t.account_id = p_account_id
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
         and (t.vehicle in ('savings', 'gic') and t.type not in ('interest', 'penalty')
              or t.vehicle = 'savings' and t.fund_id is not null and t.type in ('transfer_in', 'transfer_out'))
       group by 1, 2
      union all
      -- A fund buy or sale also moves money out of or into savings (the same row,
      -- seen from the savings side). Dividends are money into savings too.
      select public.edmonton_local(t.effective_at)::date, 'savings', sum(t.amount_cents)
        from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings' and t.fund_id is not null
         and t.type in ('transfer_in', 'transfer_out')
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
       group by 1
    ),
    -- Dividends: growth for the fund that paid them.
    dividends as (
      select public.edmonton_local(t.effective_at)::date as day, t.fund_id as option, sum(t.amount_cents) as amount
        from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings' and t.type = 'dividend'
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
       group by 1, 2
    )
    select db.balance_date as day, o.option, o.ord,
           case o.option when 'savings' then db.savings_cents
                         when 'gic' then db.gic_cents
                         else coalesce((db.fund_values ->> o.fund_id)::bigint, 0) end as v,
           coalesce((select sum(f.flow) from flows f where f.day = db.balance_date and f.option = o.option), 0)::bigint as flow,
           coalesce((select d.amount from dividends d where d.day = db.balance_date and d.option = o.option), 0)::bigint as extra
      from db cross join opts o
     order by o.ord, db.balance_date
  loop
    if v_option is distinct from r.option then
      v_option := r.option;
      v_prev := null;
      v_factor := 1;
      v_earned := 0;
      v_started := false;
    end if;

    if v_prev is null then
      -- The range's first day is where the line starts: 0%, nothing earned yet.
      v_earn := 0;
    else
      v_earn := r.v - v_prev - r.flow + r.extra;
      v_base := case when v_prev > 0 then v_prev when r.flow > 0 then r.flow else 0 end;
      if v_base > 0 then
        v_factor := round(v_factor * (1 + v_earn::numeric / v_base), 20);
      end if;
      v_earned := v_earned + v_earn;
    end if;

    -- A line starts the first day there's money in the option (or money moving).
    v_started := v_started or r.v <> 0 or r.flow <> 0 or coalesce(v_prev, 0) <> 0;
    if v_started then
      day := r.day;
      option := r.option;
      growth_pct := round((v_factor - 1) * 100, 2);
      earned_cents := v_earned;
      flow_cents := case when v_prev is null then 0 else r.flow end;
      return next;
    end if;
    v_prev := r.v;
  end loop;
end;
$$;

comment on function public.growth_by_option(uuid, date, date) is
  'Each day''s time-weighted % growth since the range''s first day, and the dollars earned, for savings, GICs and each fund. Money moved in or out is never growth.';

-- Money in vs money earned --------------------------------------------------------------------------

create function public.money_in_vs_earned(p_account_id uuid)
returns table (day date, net_deposits_cents bigint, total_cents bigint, earned_cents bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_from date;
  v_before bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  select min(public.edmonton_local(t.effective_at))::date into v_from
    from public.transactions t where t.account_id = p_account_id;
  if v_from is null or v_from > v_today then
    return;
  end if;
  v_from := greatest(v_from, v_today - 3650);

  -- Deposits minus withdrawals before the first day shown (none, unless she's been here 10 years).
  select coalesce(sum(t.amount_cents), 0)::bigint into v_before
    from public.transactions t
   where t.account_id = p_account_id and t.type in ('deposit', 'withdraw')
     and t.effective_at < public.edmonton_start(v_from);

  return query
  select b.balance_date,
         (v_before + sum(b.net_flow_cents) over (order by b.balance_date))::bigint,
         b.total_cents,
         (b.total_cents - v_before - sum(b.net_flow_cents) over (order by b.balance_date))::bigint
    from public.daily_balances(p_account_id, v_from, v_today) b
   order by b.balance_date;
end;
$$;

comment on function public.money_in_vs_earned(uuid) is
  'Each day since her first: net deposits (deposits minus withdrawals so far), total worth, and the gap between them (what her money earned).';

-- My mix today -------------------------------------------------------------------------------------

create function public.my_mix(p_account_id uuid)
returns table (option text, name text, value_cents bigint, mix_pct integer)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  return query
  with parts as (
    select 'savings'::text as option, 'Savings'::text as name, b.savings_cents as v, 0 as ord
      from public.account_balances b where b.account_id = p_account_id
    union all
    select 'gic', 'GICs', b.gic_cents, 1
      from public.account_balances b where b.account_id = p_account_id
    union all
    select fu.id, fu.name, coalesce(fp.value_cents, 0)::bigint, 2 + fu.sort_order
      from public.funds fu
      left join public.fund_positions fp on fp.fund_id = fu.id and fp.account_id = p_account_id
  ),
  held as (select * from parts where parts.v > 0),
  total as (select sum(held.v) as t from held),
  -- Whole percents that add up to exactly 100 (largest remainder, ties in screen order).
  shares as (
    select h.option, h.name, h.v, h.ord,
           floor(h.v * 100.0 / total.t)::integer as base,
           h.v * 100.0 / total.t - floor(h.v * 100.0 / total.t) as rem
      from held h, total
  ),
  ranked as (
    select s.*, row_number() over (order by s.rem desc, s.ord) as rnk, 100 - sum(s.base) over () as spare
      from shares s
  )
  select r.option, r.name, r.v::bigint, r.base + (case when r.rnk <= r.spare then 1 else 0 end)
    from ranked r
   order by r.ord;
end;
$$;

comment on function public.my_mix(uuid) is
  'Her mix today: savings, GICs and each fund she holds, in whole percents that add up to exactly 100.';

-- The GIC ladder -----------------------------------------------------------------------------------

create function public.gic_ladder(p_account_id uuid)
returns table (gic_id bigint, principal_cents bigint, rate numeric, term_months smallint, start_date date,
               maturity_date date, interest_cents bigint, at_maturity_cents bigint, ready boolean)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  return query
  select g.gic_id, g.principal_cents, g.rate, g.term_months, g.start_date, g.maturity_date,
         g.interest_at_maturity_cents,
         (g.principal_cents + g.interest_at_maturity_cents)::bigint,
         g.status = 'matured'
    from public.gic_positions g
   where g.account_id = p_account_id
     and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null))
     and g.maturity_date <= (public.app_today() + interval '24 months')::date
   order by g.maturity_date, g.gic_id;
end;
$$;

comment on function public.gic_ladder(uuid) is
  'Her GICs (active, or matured and waiting for her choice) from start to ready date, soonest first, for the next 24 months.';

-- Stock fund detail --------------------------------------------------------------------------------

create function public.fund_chart(p_account_id uuid, p_fund_id text, p_from date)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_first numeric;
  v_last numeric;
  v_growth record;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.funds f where f.id = p_fund_id) then
    raise exception 'There''s no fund called %.', coalesce(p_fund_id, 'that');
  end if;
  if p_from is null or p_from > v_today or v_today - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  select fp.close into v_first from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today order by fp.price_date limit 1;
  select fp.close into v_last from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today order by fp.price_date desc limit 1;

  -- Her growth in this fund over the range: the same time-weighted measure as the growth graph.
  select g.growth_pct, g.earned_cents into v_growth
    from public.growth_by_option(p_account_id, p_from, v_today) g
   where g.option = p_fund_id
   order by g.day desc limit 1;

  return jsonb_build_object(
    'fund_id', p_fund_id,
    'from', p_from,
    'today', v_today,
    -- Each close in the range, with its change since the range's first close.
    'closes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'd', fp.price_date,
               'c', trim_scale(fp.close),
               'pct', round((fp.close - v_first) * 100 / v_first, 2)) order by fp.price_date), '[]'::jsonb)
        from public.fund_prices fp
       where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today),
    'change_pct', case when v_first > 0 then round((v_last - v_first) * 100 / v_first, 2) end,
    -- Her buys and sells: the day, the price she got, units, and the money (paid, or received).
    'trades', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'd', public.edmonton_local(s.effective_at)::date,
               'side', case when s.type = 'transfer_in' then 'buy' else 'sell' end,
               'price', trim_scale(s.unit_price),
               'units', trim_scale(abs(s.units)),
               'amount_cents', abs(sv.amount_cents)) order by s.effective_at, s.id), '[]'::jsonb)
        from public.transactions s
        join public.transactions sv
          on sv.request_id = s.request_id and sv.vehicle = 'savings' and sv.account_id = s.account_id
       where s.account_id = p_account_id and s.fund_id = p_fund_id and s.vehicle = 'stock'
         and s.type in ('transfer_in', 'transfer_out')
         and s.effective_at >= public.edmonton_start(p_from)
         and s.effective_at < public.edmonton_start(v_today + 1)),
    -- The market-move notes for this fund in the range.
    'notes', (
      select coalesce(jsonb_agg(jsonb_build_object('d', n.note_date, 'body', n.body) order by n.note_date, n.id),
                      '[]'::jsonb)
        from public.notes n
       where n.audience = 'kids' and n.fund_id = p_fund_id and n.note_date between p_from and v_today),
    -- Her return in the range (time-weighted, with dividends), or null if she held none of it.
    'range_growth_pct', v_growth.growth_pct,
    'range_earned_cents', v_growth.earned_cents,
    -- What she holds now: gain against what she paid for the units she holds (the
    -- "since first purchase" figure, the same as Home's).
    'holding', (
      select jsonb_build_object('units', trim_scale(fp.units), 'value_cents', fp.value_cents,
                                'cost_cents', fp.cost_cents, 'gain_cents', fp.gain_cents,
                                'return_pct', fp.return_pct)
        from public.fund_positions fp
       where fp.account_id = p_account_id and fp.fund_id = p_fund_id and fp.units > 0));
end;
$$;

comment on function public.fund_chart(uuid, text, date) is
  'A fund''s closes since a date (each with its % change), her buys and sells, its market-move notes, her growth in the range and what she holds now.';

-- The glossary: two words the Graphs tab explains ------------------------------------------------------

insert into public.glossary (term, kid_text) values
  ('Growth',
   'How much an option grew by itself, as a percent. Money you put in or take out doesn''t count, only what your money earned.'),
  ('Money earned',
   'Your total worth minus your net deposits. It''s the part of your money that your money made for you.');

-- Who may call them ---------------------------------------------------------------------------------

revoke all on function public.graph_ranges(uuid) from public, anon, authenticated, service_role;
revoke all on function public.growth_by_option(uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function public.money_in_vs_earned(uuid) from public, anon, authenticated, service_role;
revoke all on function public.my_mix(uuid) from public, anon, authenticated, service_role;
revoke all on function public.gic_ladder(uuid) from public, anon, authenticated, service_role;
revoke all on function public.fund_chart(uuid, text, date) from public, anon, authenticated, service_role;
grant execute on function public.graph_ranges(uuid) to authenticated, service_role;
grant execute on function public.growth_by_option(uuid, date, date) to authenticated, service_role;
grant execute on function public.money_in_vs_earned(uuid) to authenticated, service_role;
grant execute on function public.my_mix(uuid) to authenticated, service_role;
grant execute on function public.gic_ladder(uuid) to authenticated, service_role;
grant execute on function public.fund_chart(uuid, text, date) to authenticated, service_role;
