-- The price fix, part 3: what she sees (Dad, 2026-11-09; docs/plans/price-fix-plan.md, 2c).
--
-- 1. Her waiting line names its close, the same in Recent activity and on Buy / Sell:
--      before the close   "Waiting for today's 3:00 pm close (Nov 9) · asked Nov 6"
--                         ("Monday's 3:00 pm close (Nov 9)" when it's a later day);
--      after the close    "Waiting for today's close to be confirmed (Nov 9) · asked Nov 6",
--                         until the confirmed close (9:00 pm Alberta time) settles it.
--    my_activity gives it as a waiting trade's note; trade_options as waiting_words.
-- 2. The funds switch to a new day together. A fund whose close for the newest market day is still
--    missing says so on its card ("Today's TSX close comes in later"), and "Last market day" names
--    the day all her funds have (kid_close_days). A fund whose market was closed that day isn't late.

-- 1. Her waiting line -----------------------------------------------------------------------------------

create function public.waiting_words(p_fund_id text, p_created_at timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select 'Waiting for '
         || case l::date - public.app_today()
              when 0 then 'today''s '
              when 1 then 'tomorrow''s '
              when -1 then 'yesterday''s '
              else to_char(l, 'FMDay') || '''s '
            end
         || case when public.app_now() < x.close_at then to_char(l, 'FMHH12:MI am') || ' close'
                 else 'close to be confirmed' end
         || ' (' || public.fmt_date(l::date) || ') · asked '
         || public.fmt_date(public.edmonton_local(p_created_at)::date)
    from (select public.next_settlement(p_fund_id, p_created_at) as close_at) x
    cross join lateral (select public.edmonton_local(x.close_at) as l) y;
$$;
comment on function public.waiting_words(text, timestamptz) is
  'A waiting trade in her words: "Waiting for today''s 3:00 pm close (Nov 9) · asked Nov 6", then "Waiting for today''s close to be confirmed (Nov 9) · asked Nov 6".';

-- 2. The funds' newest market day ------------------------------------------------------------------------

-- {last_market_day, later: {fund_id: words}}. Market data only, nothing personal.
create function public.kid_close_days()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_d date;
  v_f record;
  v_missing date;
  v_later jsonb := '{}'::jsonb;
  v_last date;
begin
  select max(fp.price_date) into v_d from public.fund_prices fp where fp.price_date <= public.app_today();
  if v_d is null then
    return jsonb_build_object('last_market_day', null, 'later', v_later);
  end if;
  v_last := v_d;
  for v_f in
    select f.id, f.name, f.market,
           (select max(fp.price_date) from public.fund_prices fp
             where fp.fund_id = f.id and fp.price_date <= public.app_today()) as latest
      from public.funds f order by f.sort_order
  loop
    -- The first day after its newest close that its market traded, up to the newest market day.
    select min(d::date) into v_missing
      from generate_series(coalesce(v_f.latest + 1, v_d), v_d, interval '1 day') d
     where public.is_trading_day(v_f.market, d::date);
    continue when v_f.latest = v_d or v_missing is null;
    v_later := v_later || jsonb_build_object(v_f.id,
      case when v_missing = public.app_today() then 'Today''s ' || v_f.name || ' close comes in later'
           else 'The ' || v_f.name || ' close for ' || public.fmt_date(v_missing) || ' comes in later' end);
    v_last := least(v_last, coalesce(v_f.latest, v_last));
  end loop;
  return jsonb_build_object('last_market_day', v_last, 'later', v_later);
end;
$$;
comment on function public.kid_close_days() is
  'Home: the newest market day all her funds have, and which fund''s close for a newer day comes in later (the price fix, 2c).';

-- 3. trade_options: from 20261009000000_sell_shown_value.sql (1 change: waiting_words).
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
                           then public.fmt_close(public.next_settlement(r.fund_id, r.created_at)) end,
           'waiting_words', case when r.fund_id is not null then public.waiting_words(r.fund_id, r.created_at) end)
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

-- 4. my_activity: from 20261018060000_audit_minor.sql (1 change: a waiting trade's note is its line).
create or replace function public.my_activity(p_account_id uuid, p_limit integer default 20,
                                   p_before_at timestamptz default null, p_before_key text default null)
returns table (
  item_key text, at timestamptz, on_day date, kind text, request_type text, amount_cents bigint,
  fund_id text, gic_id bigint, gic_term integer, rate numeric, units numeric, unit_price numeric,
  note text, transaction_ids bigint[], request_id bigint, fixes text)
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
           max(tx.request_id) as request_id,
           max(tx.corrects_id) as corrects_id,
           max(tx.corrects_request_id) as corrects_request_id,
           max(tx.question_id) as question_id
      from tx
     group by tx.gkey
  ),
  lines as (
    select g.gkey as item_key, g.at, g.kind, null::text as request_type,
           (case when g.kind = 'correction' then g.net_cents
                 else coalesce(g.savings_cents, g.biggest_cents) end)::bigint as amount_cents,
           g.fund_id, g.gic_id, gh.term_months::integer as gic_term, gh.rate,
           g.units, g.unit_price, g.note, g.ids as transaction_ids, g.request_id,
           g.corrects_id, g.corrects_request_id, g.question_id
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
           nullif(r.held_units, 0), null::numeric,
           -- A waiting trade's note is its line in her words (the price fix, 2c).
           case when r.status = 'pending' and r.fund_id is not null then public.waiting_words(r.fund_id, r.created_at)
                else r.parent_note end,
           null::bigint[], r.id,
           null::bigint, null::bigint, null::bigint
      from public.requests r
     where r.account_id = p_account_id and r.status in ('pending', 'declined', 'expired')
  )
  select l.item_key, l.at, public.edmonton_local(l.at)::date, l.kind, l.request_type, l.amount_cents,
         l.fund_id, l.gic_id, l.gic_term, l.rate, l.units, l.unit_price, l.note, l.transaction_ids, l.request_id,
         case when l.kind = 'correction' then coalesce(
           (select public.line_words(c.kind, c.request_type, c.fund_id, c.gic_term, c.rate, c.note)
                   || ' on ' || public.fmt_date(public.edmonton_local(c.at)::date)
              from lines c
             where (l.corrects_id is not null and l.corrects_id = any (c.transaction_ids))
                or (l.corrects_request_id is not null and c.item_key = 'req:' || l.corrects_request_id)
             limit 1),
           (select 'your question from ' || public.fmt_date(public.edmonton_local(q.created_at)::date)
              from public.questions q where q.id = l.question_id))
         end
    from lines l
   where p_before_at is null or (l.at, l.item_key) < (p_before_at, coalesce(p_before_key, ''))
   order by l.at desc, l.item_key desc
   -- The app shows her history 200 lines at a time at most; Dad's screens (and the server) may ask
   -- for more, so Approvals can always find the line a question is about (pre-launch audit).
   limit least(greatest(coalesce(p_limit, 20), 1),
               case when public.is_parent() or auth.uid() is null then 100000 else 200 end);
end;
$$;

revoke all on function public.waiting_words(text, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.kid_close_days() from public, anon, authenticated, service_role;
grant execute on function public.waiting_words(text, timestamptz) to authenticated, service_role;
grant execute on function public.kid_close_days() to authenticated, service_role;
