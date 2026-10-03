-- Stage 7: what the kid Home screen reads, and marking notices as read.
--
--   fund_overview(account)       each fund: her holding, the fund's daily change,
--                                her mix in whole percents, and a 30-close sparkline
--   my_activity(account, …)      her history, newest first: one line per event
--                                (a move's two ledger rows become one line), plus
--                                pending, declined and expired requests
--   current_rates()              today's savings and GIC rates, specials and
--                                announced changes (for the GIC choice screen)
--   mark_notices_read(ids)       a kid marks her own notices as read
--
-- The percentages here are figures for display, not money, but they're worked
-- out here like everything else so the app only shows results.

-- Each fund ------------------------------------------------------------------------------------

create function public.fund_overview(p_account_id uuid)
returns table (
  fund_id text, name text, colour text, sort_order smallint,
  owned boolean, units numeric, value_cents bigint, cost_cents bigint, gain_cents bigint, return_pct numeric,
  latest_close numeric, previous_close numeric, latest_close_date date, day_change_pct numeric,
  mix_pct integer, spark jsonb)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  return query
  with f as (
    select fu.id, fu.name, fu.colour, fu.sort_order,
           coalesce(fp.units, 0) as units,
           coalesce(fp.value_cents, 0)::bigint as value_cents,
           coalesce(fp.cost_cents, 0)::bigint as cost_cents,
           coalesce(fp.gain_cents, 0)::bigint as gain_cents,
           fp.return_pct,
           c.closes
      from public.funds fu
      left join public.fund_positions fp on fp.fund_id = fu.id and fp.account_id = p_account_id
      cross join lateral (
        select jsonb_agg(jsonb_build_object('d', x.price_date, 'c', trim_scale(x.close)) order by x.price_date) as closes
          from (select p.price_date, p.close from public.fund_prices p
                 where p.fund_id = fu.id and p.price_date <= public.app_today()
                 order by p.price_date desc limit 30) x) c
  ),
  latest as (
    select fu.id,
           (select p.close from public.fund_prices p where p.fund_id = fu.id and p.price_date <= public.app_today()
             order by p.price_date desc limit 1) as latest_close,
           (select p.close from public.fund_prices p where p.fund_id = fu.id and p.price_date <= public.app_today()
             order by p.price_date desc limit 1 offset 1) as previous_close,
           (select p.price_date from public.fund_prices p where p.fund_id = fu.id and p.price_date <= public.app_today()
             order by p.price_date desc limit 1) as latest_close_date
      from public.funds fu
  ),
  -- Her mix in whole percents that add up to exactly 100 (largest remainder).
  total as (select sum(f.value_cents) as t from f),
  shares as (
    select f.id,
           floor(f.value_cents * 100.0 / total.t)::integer as base,
           f.value_cents * 100.0 / total.t - floor(f.value_cents * 100.0 / total.t) as rem
      from f, total
     where total.t > 0 and f.value_cents > 0
  ),
  ranked as (
    select s.id, s.base,
           row_number() over (order by s.rem desc, (select f.sort_order from f where f.id = s.id)) as rnk,
           100 - sum(s.base) over () as spare
      from shares s
  )
  select f.id, f.name, f.colour, f.sort_order,
         f.units > 0, f.units, f.value_cents, f.cost_cents, f.gain_cents, f.return_pct,
         l.latest_close, l.previous_close, l.latest_close_date,
         case when l.previous_close > 0
              then round((l.latest_close - l.previous_close) * 100 / l.previous_close, 2) end,
         case when r.id is not null then r.base + (case when r.rnk <= r.spare then 1 else 0 end) end,
         coalesce(f.closes, '[]'::jsonb)
    from f
    join latest l on l.id = f.id
    left join ranked r on r.id = f.id
   order by f.sort_order;
end;
$$;

-- Her history ----------------------------------------------------------------------------------

-- Newest first. Pass the `at` and `item_key` of the last line shown to get the
-- lines after it (the "See all" page loads more as she scrolls).
create function public.my_activity(p_account_id uuid, p_limit integer default 20,
                                   p_before_at timestamptz default null, p_before_key text default null)
returns table (
  item_key text, at timestamptz, on_day date, kind text, request_type text, amount_cents bigint,
  fund_id text, gic_id bigint, gic_term integer, rate numeric, units numeric, unit_price numeric,
  note text, transaction_ids bigint[], request_id bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  return query
  with tx as (
    -- The two sides of a move share a posting key apart from the last part
    -- (gic_buy:7:savings and gic_buy:7:gic), so they group into one line.
    select t.*,
           coalesce(regexp_replace(t.posting_key, ':(gic|savings|in|out|fund)$', ''), 'tx:' || t.id) as gkey
      from public.transactions t
     where t.account_id = p_account_id
  ),
  grouped as (
    select tx.gkey,
           max(tx.effective_at) as at,
           case
             when bool_or(tx.type = 'correction') then 'correction'
             when bool_or(tx.type = 'penalty') then 'penalty'
             when bool_or(tx.type = 'deposit') then 'deposit'
             when bool_or(tx.type = 'withdraw') then 'withdraw'
             when bool_or(tx.type = 'dividend') then 'dividend'
             when bool_or(tx.type = 'split_adjust') then 'split'
             when bool_or(tx.type = 'interest' and tx.vehicle = 'gic') then 'gic_interest'
             when bool_or(tx.type = 'interest') then 'interest'
             when tx.gkey like 'gic\_buy:%' then 'gic_buy'
             when tx.gkey like 'gic\_break:%' then 'gic_break'
             when tx.gkey like 'gic\_release:%' then 'gic_to_savings'
             when tx.gkey like 'gic\_renew:%' then 'gic_renew'
             when tx.gkey like 'trade:%' then
               case when bool_or(tx.vehicle = 'stock' and tx.units > 0) then 'fund_buy' else 'fund_sell' end
             else 'other'
           end as kind,
           sum(tx.amount_cents) as net_cents,
           max(abs(tx.amount_cents)) filter (where tx.vehicle = 'savings') as savings_cents,
           max(abs(tx.amount_cents)) as biggest_cents,
           max(tx.fund_id) as fund_id,
           max(tx.gic_id) as gic_id,
           max(abs(tx.units)) filter (where tx.vehicle = 'stock') as units,
           max(tx.unit_price) filter (where tx.vehicle = 'stock') as unit_price,
           (array_agg(tx.note order by (tx.vehicle = 'savings') desc, tx.id) filter (where tx.note is not null))[1] as note,
           array_agg(tx.id order by tx.id) as ids,
           max(tx.request_id) as request_id
      from tx
     group by tx.gkey
  ),
  lines as (
    select g.gkey as item_key, g.at, g.kind, null::text as request_type,
           (case when g.kind = 'correction' then g.net_cents
                 else coalesce(g.savings_cents, g.biggest_cents) end)::bigint as amount_cents,
           g.fund_id, g.gic_id, gh.term_months::integer as gic_term, gh.rate,
           g.units, g.unit_price, g.note, g.ids as transaction_ids, g.request_id
      from grouped g
      left join public.gic_holdings gh on gh.id = g.gic_id
    union all
    select 'req:' || r.id, case when r.status = 'pending' then r.created_at else coalesce(r.decided_at, r.created_at) end,
           'request_' || r.status::text,
           case r.type
             when 'move' then case when r.from_vehicle = 'stock' then 'sell' when r.to_vehicle = 'stock' then 'buy' else 'move' end
             else r.type::text
           end,
           r.amount_cents, r.fund_id, r.gic_id, r.gic_term::integer, null::numeric,
           nullif(r.held_units, 0), null::numeric, r.parent_note, null::bigint[], r.id
      from public.requests r
     where r.account_id = p_account_id and r.status in ('pending', 'declined', 'expired')
  )
  select l.item_key, l.at, (l.at at time zone 'America/Edmonton')::date, l.kind, l.request_type, l.amount_cents,
         l.fund_id, l.gic_id, l.gic_term, l.rate, l.units, l.unit_price, l.note, l.transaction_ids, l.request_id
    from lines l
   where p_before_at is null or (l.at, l.item_key) < (p_before_at, coalesce(p_before_key, ''))
   order by l.at desc, l.item_key desc
   limit least(greatest(coalesce(p_limit, 20), 1), 200);
end;
$$;

-- Today's rates ----------------------------------------------------------------------------------

-- Savings and each GIC term: the rate today (a special wins inside its dates),
-- and the next announced regular rate, if any.
create function public.current_rates()
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
       order by nr.effective_date, nr.id desc
       limit 1) n on true
   order by k.ord;
$$;

-- Notices ----------------------------------------------------------------------------------------------

-- A kid marks her own notices as read. Others' notices, and ones already read,
-- are left alone (the first time she read it is kept). Returns how many changed.
create function public.mark_notices_read(p_ids bigint[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.my_account_id();
  v_count integer;
begin
  if v_account is null then
    raise exception 'Only a kid can mark her notices as read.' using errcode = '42501';
  end if;
  update public.notifications n set read_at = public.app_now()
   where n.id = any (coalesce(p_ids, '{}')) and n.account_id = v_account and n.read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- The "?" on the daily change (Dad's wording, stage 7) -------------------------------------------

update public.glossary
   set kid_text = 'How much a fund went up or down since the market''s last day, as a percent. Markets go up and down all the time, and one day doesn''t matter much. What counts is how it does over months and years.'
 where term = 'Daily change';

-- Who may call them -------------------------------------------------------------------------------

revoke all on function public.fund_overview(uuid) from public, anon, authenticated, service_role;
revoke all on function public.my_activity(uuid, integer, timestamptz, text) from public, anon, authenticated, service_role;
revoke all on function public.current_rates() from public, anon, authenticated, service_role;
revoke all on function public.mark_notices_read(bigint[]) from public, anon, authenticated, service_role;
grant execute on function public.fund_overview(uuid) to authenticated, service_role;
grant execute on function public.my_activity(uuid, integer, timestamptz, text) to authenticated, service_role;
grant execute on function public.current_rates() to authenticated, service_role;
grant execute on function public.mark_notices_read(bigint[]) to authenticated;
