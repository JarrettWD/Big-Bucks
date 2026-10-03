-- Stage 2: what the app reads. Balances are never stored: every figure here is
-- worked out from the ledger when it's asked for.
--
-- Views run with the caller's permissions (security_invoker), so row-level
-- security applies: a kid sees only her own rows, the parent sees everyone.

-- Each fund she has ever held: units, held and available units, average cost,
-- value at the latest close (to the nearest cent: a value shown, not money
-- posted, so it isn't rounded up the way sale proceeds are), gain and return since
-- first purchase. The fund rows' amounts add up to the cost of the units held.
create view public.fund_positions with (security_invoker = true) as
select u.account_id,
       u.fund_id,
       u.units,
       coalesce(h.held_units, 0) as held_units,
       u.units - coalesce(h.held_units, 0) as available_units,
       u.cost_cents,
       p.close as latest_close,
       p.price_date as latest_close_date,
       coalesce(round(u.units * p.close * 100), 0)::bigint as value_cents,
       (coalesce(round(u.units * p.close * 100), 0) - u.cost_cents)::bigint as gain_cents,
       case when u.cost_cents > 0
            then round((round(u.units * p.close * 100) - u.cost_cents) * 100.0 / u.cost_cents, 2) end as return_pct
  from (select t.account_id, t.fund_id, sum(t.units) as units, sum(t.amount_cents)::bigint as cost_cents
          from public.transactions t
         where t.vehicle = 'stock'
         group by t.account_id, t.fund_id) u
  left join lateral (
    select sum(r.held_units) as held_units
      from public.requests r
     where r.account_id = u.account_id and r.fund_id = u.fund_id
       and r.status = 'pending' and r.from_vehicle = 'stock') h on true
  left join lateral (
    select fp.close, fp.price_date
      from public.fund_prices fp
     where fp.fund_id = u.fund_id and fp.price_date <= public.app_today()
     order by fp.price_date desc
     limit 1) p on true;

comment on view public.fund_positions is
  'Fund holdings: units, average cost, value at the latest close, gain and % return since first purchase.';

-- Each GIC: what's in it now, interest at maturity, what breaking it today would
-- give up, and (when matured and waiting) the last day to choose.
create view public.gic_positions with (security_invoker = true) as
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
       case when g.status = 'matured' and g.maturity_choice is null then g.maturity_date + 6 end as choose_by
  from public.gic_holdings g
  left join lateral (
    select sum(t.amount_cents) as balance_cents
      from public.transactions t
     where t.gic_id = g.id and t.vehicle = 'gic') b on true;

comment on view public.gic_positions is
  'GIC holdings with balance, interest at maturity, interest given up if broken today, and the choose-by date.';

-- One row per account: savings, held and available money, GICs, funds, total
-- worth, net deposits and room under the cap.
create view public.account_balances with (security_invoker = true) as
select a.id as account_id,
       a.is_test,
       s.savings_cents,
       h.held_cents,
       (s.savings_cents - h.held_cents)::bigint as available_cents,
       g.gic_cents,
       coalesce(f.value_cents, 0)::bigint as stock_value_cents,
       coalesce(f.cost_cents, 0)::bigint as stock_cost_cents,
       (s.savings_cents + g.gic_cents + coalesce(f.value_cents, 0))::bigint as total_worth_cents,
       n.net_deposits_cents,
       pd.pending_deposits_cents,
       c.cap_cents,
       greatest(c.cap_cents - n.net_deposits_cents - pd.pending_deposits_cents, 0)::bigint as cap_room_cents
  from public.accounts a
  cross join lateral (
    select coalesce(sum(t.amount_cents), 0)::bigint as savings_cents
      from public.transactions t where t.account_id = a.id and t.vehicle = 'savings') s
  cross join lateral (
    select coalesce(sum(r.held_cents), 0)::bigint as held_cents
      from public.requests r where r.account_id = a.id and r.status = 'pending') h
  cross join lateral (
    select coalesce(sum(t.amount_cents), 0)::bigint as gic_cents
      from public.transactions t where t.account_id = a.id and t.vehicle = 'gic') g
  left join lateral (
    select sum(fp.value_cents) as value_cents, sum(fp.cost_cents) as cost_cents
      from public.fund_positions fp where fp.account_id = a.id) f on true
  cross join lateral (
    select coalesce(sum(t.amount_cents), 0)::bigint as net_deposits_cents
      from public.transactions t where t.account_id = a.id and t.type in ('deposit', 'withdraw')) n
  cross join lateral (
    select coalesce(sum(r.amount_cents), 0)::bigint as pending_deposits_cents
      from public.requests r where r.account_id = a.id and r.type = 'deposit' and r.status = 'pending') pd
  cross join lateral (
    select coalesce(public.setting_on('deposit_cap_cents', public.app_today()), '0')::bigint as cap_cents) c;

comment on view public.account_balances is
  'Per account: savings, held, available, GICs, funds, total worth, net deposits, pending deposits, cap and cap room.';

-- Who may read an account's figures: the kid herself, the parent, or the server.
create function public.can_read_account(p_account_id uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select auth.uid() is null or public.is_parent() or p_account_id = public.my_account_id();
$$;

-- A fund holding's value at the end of a day: units then × the latest close on or before it.
create function public.fund_value_at(p_account_id uuid, p_fund_id text, p_day date)
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(round(
           (select sum(t.units) from public.transactions t
             where t.account_id = p_account_id and t.fund_id = p_fund_id and t.vehicle = 'stock'
               and t.effective_at < public.edmonton_start(p_day + 1))
         * (select fp.close from public.fund_prices fp
             where fp.fund_id = p_fund_id and fp.price_date <= p_day
             order by fp.price_date desc limit 1)
         * 100), 0)::bigint;
$$;

-- Each day's end-of-day figures for the graphs: savings, GICs, each fund's value,
-- total, and money in or out that day (deposits minus withdrawals, for the dots).
create function public.daily_balances(p_account_id uuid, p_from date, p_to date)
returns table (balance_date date, savings_cents bigint, gic_cents bigint, stock_cents bigint,
               total_cents bigint, net_flow_cents bigint, fund_values jsonb)
language plpgsql stable
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.can_read_account(p_account_id) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  return query
  select dd.day,
         s.v,
         g.v,
         coalesce(fv.total, 0)::bigint,
         (s.v + g.v + coalesce(fv.total, 0))::bigint,
         nf.v,
         fv.obj
    from (select d::date as day from generate_series(p_from, p_to, interval '1 day') d) dd
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings'
         and t.effective_at < public.edmonton_start(dd.day + 1)) s
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'gic'
         and t.effective_at < public.edmonton_start(dd.day + 1)) g
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id and t.type in ('deposit', 'withdraw')
         and t.effective_at >= public.edmonton_start(dd.day)
         and t.effective_at < public.edmonton_start(dd.day + 1)) nf
    left join lateral (
      select sum(x.val)::bigint as total, jsonb_object_agg(x.fund_id, x.val) as obj
        from (select fu.id as fund_id, public.fund_value_at(p_account_id, fu.id, dd.day) as val
                from public.funds fu
               where exists (select 1 from public.transactions t
                              where t.account_id = p_account_id and t.fund_id = fu.id and t.vehicle = 'stock'
                                and t.effective_at < public.edmonton_start(dd.day + 1))) x) fv on true
   order by dd.day;
end;
$$;

-- A fund holding's return from the end of p_from to today, excluding money moved
-- in or out (simple Modified Dietz: flows weighted by how long they were in).
-- Returns a percent rounded to 2 places, or null when there's nothing to measure.
create function public.fund_return(p_account_id uuid, p_fund_id text, p_from date)
returns numeric
language plpgsql stable
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_days integer := public.app_today() - p_from;
  v_start bigint;
  v_end bigint;
  v_flows numeric := 0;
  v_weighted numeric := 0;
  v_flow record;
begin
  if not public.can_read_account(p_account_id) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if v_days <= 0 then
    return null;
  end if;

  v_start := public.fund_value_at(p_account_id, p_fund_id, p_from);
  v_end := public.fund_value_at(p_account_id, p_fund_id, v_today);

  -- Money into the fund (a buy) shows as savings going out, and the reverse for a sale.
  for v_flow in
    select (t.effective_at at time zone 'America/Edmonton')::date as day, -sum(t.amount_cents) as amount
      from public.transactions t
     where t.account_id = p_account_id and t.fund_id = p_fund_id and t.vehicle = 'savings'
       and t.type in ('transfer_in', 'transfer_out')
       and t.effective_at >= public.edmonton_start(p_from + 1)
       and t.effective_at < public.edmonton_start(v_today + 1)
     group by 1
  loop
    v_flows := v_flows + v_flow.amount;
    v_weighted := v_weighted + v_flow.amount * (v_days - (v_flow.day - p_from))::numeric / v_days;
  end loop;

  if v_start + v_weighted <= 0 then
    return null;
  end if;
  return round((v_end - v_start - v_flows) * 100 / (v_start + v_weighted), 2);
end;
$$;

-- The total real cash Dad owes: every non-test account's total worth.
create function public.liability_total()
returns bigint
language plpgsql stable
set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_parent() then
    raise exception 'Only a parent signed in with the second step (the authenticator code) can see this.'
      using errcode = '42501';
  end if;
  return (select coalesce(sum(b.total_worth_cents), 0)::bigint
            from public.account_balances b where not b.is_test);
end;
$$;

-- When a trade in this fund, asked for at p_at (default: now), would settle.
create function public.next_settlement(p_fund_id text, p_at timestamptz default null)
returns timestamptz
language sql stable
security definer
set search_path = ''
as $$
  select public.next_close(f.market, coalesce(p_at, public.app_now()))
    from public.funds f where f.id = p_fund_id;
$$;

grant select on public.fund_positions, public.gic_positions, public.account_balances to authenticated, service_role;
