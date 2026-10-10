-- Stage 4, step 1, second round (second audit, 2026-10-08; Dad's review). Prices.
--
-- 1. A close that isn't final can be confirmed: correct_fund_price with the same value
--    re-stamps it as fetched now (Dad, authenticator code, logged "Confirmed ...").
--    Before, it refused "the close already stored", so an early-fetched close could
--    hold up the fund work for good.
-- 2. record_early_close (Dad, authenticator code, logged): a market closed early
--    without warning. That day's close time moves earlier, so a close fetched after
--    the real early close counts as final; trades asked for after the early close
--    move to the next close, and each girl with one is told.
-- 3. record_market_closure refuses a quarter's first trading day whose dividends are
--    already paid (they would look misdated to the nightly check).
-- 4. Dad's closure and early-close rows don't count as a confirmed holiday calendar
--    for the "holiday dates running out" warning (parent_dashboard).
-- 5. A price fix and settlement (or dividends) take turns: an advisory lock per fund
--    and day in settle_trades, pay_quarterly_dividends and correct_fund_price.
-- The price fetcher (later in stage 4) never stores a close before its market's
-- close time.

-- 1 and 5. Confirming a close; taking turns with settlement.
CREATE OR REPLACE FUNCTION public.correct_fund_price(p_fund_id text, p_date date, p_close numeric, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_fund public.funds;
  v_old public.fund_prices;
  v_qstart date;
  v_label text;
begin
  perform public.require_parent();
  perform pg_advisory_xact_lock(hashtext('close:' || p_fund_id || ':' || p_date));
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  select * into v_old from public.fund_prices fp where fp.fund_id = p_fund_id and fp.price_date = p_date for update;
  if not found then
    raise exception 'There''s no close stored for % on %.', v_fund.name, public.fmt_date(p_date);
  end if;
  if p_close is null or p_close <= 0 or p_close <> round(p_close, 8) then
    raise exception 'A close is a price above $0, with at most 8 decimal places.';
  end if;
  -- The same value confirms a close that isn't final yet (fetched before the close
  -- time, for example on a day the market closed early without warning).
  if p_close = v_old.close and v_old.fetched_at >= public.close_time(v_fund.market, p_date) then
    raise exception 'That''s the close already stored, and it''s already final.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say where the right close comes from, so the fix explains itself.';
  end if;
  if public.app_now() < public.close_time(v_fund.market, p_date) then
    raise exception 'The market hasn''t closed yet that day, so there''s no final close to type in.';
  end if;

  -- Used by a trade: one settled at this close.
  if exists (select 1 from public.transactions t
              where t.fund_id = p_fund_id and t.vehicle = 'stock' and t.unit_price is not null
                and t.effective_at = public.close_time(v_fund.market, p_date)) then
    raise exception 'A trade already settled at this close, so it can''t change. Fix that trade with a correction instead.';
  end if;
  -- Used by a dividend: this is a quarter's last close and that quarter's dividend is paid.
  v_qstart := (date_trunc('quarter', p_date) + interval '3 months')::date;
  if p_date = public.last_trading_day_before(v_fund.market, v_qstart) then
    v_label := to_char(v_qstart, 'YYYY') || 'Q' || extract(quarter from v_qstart);
    if exists (select 1 from public.transactions t
                where t.type = 'dividend' and t.posting_key like 'dividend:' || v_label || ':' || p_fund_id || ':%') then
      raise exception 'A dividend was already paid from this close, so it can''t change. Fix it with a correction instead.';
    end if;
  end if;

  insert into public.fund_price_corrections (fund_id, price_date, old_close, new_close, note, corrected_by)
  values (p_fund_id, p_date, v_old.close, p_close, btrim(p_note), auth.uid());
  perform set_config('bigbucks.price_fix', 'on', true);
  update public.fund_prices set close = p_close, fetched_at = public.app_now()
   where fund_id = p_fund_id and price_date = p_date;
  perform set_config('bigbucks.price_fix', '', true);

  perform public.log_parent_action('correct_fund_price', null, null,
    case when p_close = v_old.close then 'Confirmed the ' else 'Fixed the ' end || v_fund.name || ' close for ' || public.fmt_date(p_date) || ': '
      || public.fmt_money4(v_old.close * 100) || ' → ' || public.fmt_money4(p_close * 100) || '.',
    jsonb_build_object('fund_id', p_fund_id, 'price_date', p_date, 'old_close', v_old.close,
                       'new_close', p_close, 'note', btrim(p_note)));
end;
$function$;

CREATE OR REPLACE FUNCTION public.settle_trades(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_req record;
  v_close_at timestamptz;
  v_close_date date;
  v_close numeric;
  v_savings_at timestamptz;
  v_units numeric;
  v_total numeric;
  v_free numeric;
  v_need numeric;
  v_sold_all_short boolean;
  v_cost_total bigint;
  v_cost_out bigint;
  v_exact numeric;
  v_proceeds bigint;
  v_note text;
  v_settled integer := 0;
  v_waiting integer := 0;
begin
  for v_req in
    select r.*, f.market, f.name as fund_name
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.status = 'pending' and r.type = 'move' and r.fund_id is not null
     order by r.id
       for update of r
  loop
    v_close_at := public.next_close(v_req.market, v_req.created_at);
    v_close_date := (v_close_at at time zone 'America/Toronto')::date;
    continue when v_close_date > p_date;

    -- Only a final close: one fetched after the market closed. Never a guess.
    -- One at a time with a fix to this close (correct_fund_price), so a trade never
    -- settles at a close that is being changed.
    perform pg_advisory_xact_lock(hashtext('close:' || v_req.fund_id || ':' || v_close_date));
    v_close := public.final_close(v_req.fund_id, v_close_date);
    if v_close is null or v_close_at > public.app_now() then
      v_waiting := v_waiting + 1;
      continue;
    end if;
    perform 1 from public.accounts a where a.id = v_req.account_id for update;
    -- The fund side counts from the close; the savings side too, unless that day's
    -- interest is already worked out (a late close).
    v_savings_at := public.savings_moment(v_close_at);

    if v_req.to_vehicle = 'stock' then
      -- Buy: units = amount ÷ close, rounded up at 8 decimal places.
      v_units := public.round_up_units(v_req.amount_cents / 100.0 / v_close);
      if public.vehicle_cents(v_req.account_id, 'savings') < v_req.amount_cents then
        raise exception 'Request %: savings has less than the % held for this buy.', v_req.id, public.fmt_money(v_req.amount_cents);
      end if;
      v_note := 'Bought ' || public.fmt_units(v_units) || ' units of ' || v_req.fund_name || ' at '
                || public.fmt_money(v_close * 100) || ' each.';
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, request_id, posting_key, effective_at, note)
      values (v_req.account_id, 'savings', v_req.fund_id, 'transfer_out', -v_req.amount_cents, v_req.id,
              'trade:' || v_req.id || ':savings', v_savings_at, v_note);
      -- The fund row's amount is what she paid: the fund's amounts add up to the cost of the units she holds.
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                       posting_key, effective_at, note)
      values (v_req.account_id, 'stock', v_req.fund_id, 'transfer_in', v_req.amount_cents, v_units, v_close, v_req.id,
              'trade:' || v_req.id || ':fund', v_close_at, v_note);
      perform public.notify(v_req.account_id, 'request', 'Your ' || v_req.fund_name || ' buy is done',
        'You bought ' || public.fmt_units(v_units) || ' units at ' || public.fmt_money(v_close * 100)
          || ' each for ' || public.fmt_money(v_req.amount_cents) || '.',
        'trade:' || v_req.id, p_request_id => v_req.id);
    else
      -- Sell. Units she can sell now: everything not held by her other pending sales.
      v_total := public.fund_units(v_req.account_id, v_req.fund_id);
      v_free := v_total - (public.held_units(v_req.account_id, v_req.fund_id) - v_req.held_units);
      v_sold_all_short := false;
      if v_req.sell_all then
        v_units := least(v_req.held_units, v_free);
      else
        -- By amount: the units the amount needs at this close, rounded down so she
        -- keeps more. If the price fell and that's more than she has, sell them all.
        v_need := public.round_down_units(v_req.amount_cents / 100.0 / v_close);
        v_units := least(v_need, v_free);
        v_sold_all_short := v_need > v_free;
      end if;
      if v_units <= 0 then
        raise exception 'Request %: no units left to sell.', v_req.id;
      end if;

      v_exact := v_units * v_close * 100;
      v_proceeds := ceil(v_exact)::bigint;
      select coalesce(sum(t.amount_cents), 0) into v_cost_total
        from public.transactions t
       where t.account_id = v_req.account_id and t.fund_id = v_req.fund_id and t.vehicle = 'stock';
      -- Average cost: the cost leaving the books is in proportion to the units sold.
      v_cost_out := case when v_units = v_total then v_cost_total
                         else least(greatest(round(v_cost_total * v_units / v_total), 1), v_cost_total) end;

      v_note := public.fmt_units(v_units) || ' units × ' || public.fmt_money(v_close * 100) || ' = '
                || public.fmt_money4(v_exact)
                || case when v_proceeds <> v_exact then ', rounded up to ' || public.fmt_money(v_proceeds) else '' end
                || case when v_sold_all_short then '. The price fell, so ' || public.fmt_money(v_req.amount_cents)
                          || ' needed more units than you had: you sold all of them.' else '' end;
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                       posting_key, effective_at, note)
      values (v_req.account_id, 'stock', v_req.fund_id, 'transfer_out', -v_cost_out, -v_units, v_close, v_req.id,
              'trade:' || v_req.id || ':fund', v_close_at, v_note);
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, request_id, posting_key, effective_at, note)
      values (v_req.account_id, 'savings', v_req.fund_id, 'transfer_in', v_proceeds, v_req.id,
              'trade:' || v_req.id || ':savings', v_savings_at, v_note);
      -- Late: the interest her money would have earned while it waited.
      perform public.post_late_interest(v_req.account_id, v_proceeds, public.edmonton_local(v_close_at)::date,
                                        v_savings_at, 'trade:' || v_req.id, 'your sale''s money');
      perform public.notify(v_req.account_id, 'request', 'Your ' || v_req.fund_name || ' sale is done',
        'You sold ' || public.fmt_units(v_units) || ' units at ' || public.fmt_money(v_close * 100)
          || ' each, and ' || public.fmt_money(v_proceeds) || ' went into your savings.',
        'trade:' || v_req.id, p_request_id => v_req.id);
    end if;

    update public.requests
       set status = 'settled', settled_at = v_close_at, decided_at = v_req.created_at
     where id = v_req.id;
    v_settled := v_settled + 1;
  end loop;

  return jsonb_build_object('status', case when v_waiting > 0 then 'waiting' else 'ok' end,
                            'settled', v_settled, 'waiting_for_close', v_waiting);
end;
$function$;

CREATE OR REPLACE FUNCTION public.pay_quarterly_dividends(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_quarter_start date := date_trunc('quarter', p_date)::date;
  v_quarter text := to_char(p_date, 'YYYY') || 'Q' || extract(quarter from p_date);
  v_qfrom date := (date_trunc('quarter', p_date) - interval '3 months')::date;
  v_qto date := (date_trunc('quarter', p_date) - interval '1 day')::date;
  v_days integer := (date_trunc('quarter', p_date)::date - (date_trunc('quarter', p_date) - interval '3 months')::date);
  v_fund public.funds;
  v_last date;
  v_close numeric;
  v_yield numeric;
  v_holder record;
  v_ud record;
  v_end_units numeric;
  v_avg numeric;
  v_exact numeric;
  v_amount bigint;
  v_at timestamptz;
  v_posted bigint;
  v_paid integer := 0;
  v_waiting integer := 0;
begin
  if extract(month from p_date) not in (1, 4, 7, 10) then
    return jsonb_build_object('status', 'ok', 'paid', 0);
  end if;

  for v_fund in select * from public.funds f order by f.sort_order loop
    continue when public.first_trading_day_from(v_fund.market, v_quarter_start) <> p_date;

    v_last := public.last_trading_day_before(v_fund.market, v_quarter_start);
    perform pg_advisory_xact_lock(hashtext('close:' || v_fund.id || ':' || v_last));
    v_close := public.final_close(v_fund.id, v_last);
    v_yield := coalesce(public.setting_on('dividend_yield:' || v_fund.id, p_date)::numeric, 0);
    v_at := public.savings_moment(public.edmonton_start(p_date));

    for v_holder in
      select t.account_id
        from public.transactions t
       where t.fund_id = v_fund.id and t.vehicle = 'stock'
         and t.effective_at < public.edmonton_start(v_quarter_start)
       group by t.account_id
       order by t.account_id
    loop
      if v_close is null then
        v_waiting := v_waiting + 1;
        exit;
      end if;
      select * into v_ud from public.dividend_unit_days(v_holder.account_id, v_fund.id, v_qfrom, v_qto, v_last);
      continue when v_ud.unit_days_x_den <= 0;
      -- In cents: (unit-days ÷ days) × close × 100 × (yield ÷ 100) ÷ 4, rounded up exactly.
      v_amount := public.ceil_div(v_ud.unit_days_x_den * v_close * v_yield, 4 * v_days * v_ud.den);
      continue when v_amount <= 0;
      v_exact := v_ud.unit_days_x_den * v_close * v_yield / (4 * v_days * v_ud.den);
      v_avg := v_ud.unit_days_x_den / (v_days * v_ud.den);
      select coalesce(sum(t.units), 0) into v_end_units from public.transactions t
       where t.account_id = v_holder.account_id and t.fund_id = v_fund.id and t.vehicle = 'stock'
         and t.effective_at < public.edmonton_start(v_quarter_start);
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
      values (v_holder.account_id, 'savings', v_fund.id, 'dividend', v_amount,
              'dividend:' || v_quarter || ':' || v_fund.id || ':' || v_holder.account_id, v_at,
              case
                -- The same units all quarter: the full quarter's working.
                when v_ud.unit_days_x_den = v_end_units * v_days * v_ud.den then
                  public.fmt_units(v_end_units) || ' units × ' || public.fmt_money(v_close * 100) || ' × '
                    || public.fmt_rate(v_yield) || ' ÷ 4 = '
                -- The same units on every day she had any: that share of the quarter.
                when v_end_units > 0 and v_ud.unit_days_x_den = v_end_units * v_ud.days_held * v_ud.den then
                  'You owned ' || public.fmt_units(v_end_units) || ' units for ' || v_ud.days_held || ' of the quarter''s '
                    || v_days || ' days: ' || public.fmt_units(v_end_units) || ' × ' || public.fmt_money(v_close * 100)
                    || ' × ' || public.fmt_rate(v_yield) || ' ÷ 4 × ' || v_ud.days_held || '/' || v_days || ' = '
                -- Otherwise: the average she held over the quarter.
                else
                  'Your units changed during the quarter: on average '
                    || case when v_avg = round(v_avg, 8) then '' else 'about ' end
                    || public.fmt_units(round(v_avg, 8)) || ' over its ' || v_days || ' days. '
                    || public.fmt_units(round(v_avg, 8)) || ' × ' || public.fmt_money(v_close * 100) || ' × '
                    || public.fmt_rate(v_yield) || ' ÷ 4 = '
              end
                || case when v_exact = v_amount then public.fmt_money(v_amount)
                        else public.fmt_money4(v_exact) || ', rounded up to ' || public.fmt_money(v_amount) end)
      on conflict (posting_key) do nothing
      returning id into v_posted;
      -- Only a dividend posted now can be late (a re-run while another fund waits posts nothing).
      if v_posted is not null then
        perform public.post_late_interest(v_holder.account_id, v_amount, p_date, v_at,
                                          'dividend:' || v_quarter || ':' || v_fund.id || ':' || v_holder.account_id,
                                          'your dividend');
        v_paid := v_paid + 1;
      end if;
      v_posted := null;
    end loop;
  end loop;

  return jsonb_build_object('status', case when v_waiting > 0 then 'waiting' else 'ok' end,
                            'paid', v_paid, 'waiting_for_close', v_waiting);
end;
$function$;

-- 3. No closure on a day whose dividends are paid.
CREATE OR REPLACE FUNCTION public.record_market_closure(p_market market, p_date date, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_name text := case p_market when 'nyse' then 'New York Stock Exchange' else 'Toronto Stock Exchange' end;
  v_req record;
  v_n integer := 0;
  v_ids bigint[];
begin
  perform public.require_parent();
  if p_market is null or p_date is null then
    raise exception 'Choose the market and the day it was closed.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say why the market was closed (for example "National day of mourning").';
  end if;
  if p_date > public.app_today() + 366 then
    raise exception 'That''s more than a year away.';
  end if;
  if not public.is_trading_day(p_market, p_date) then
    raise exception 'The % already doesn''t trade on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.fund_prices fp join public.funds f on f.id = fp.fund_id
              where f.market = p_market and fp.price_date = p_date) then
    raise exception 'There''s already a close for % on %, so the market was open that day.',
      v_name, public.fmt_date(p_date);
  end if;

  -- A quarter's first trading day whose dividends are already paid can't become a
  -- closed day: those dividends would look misdated.
  if p_date = public.first_trading_day_from(p_market, date_trunc('quarter', p_date)::date)
     and exists (select 1 from public.transactions t join public.funds f on f.id = t.fund_id
                  where t.type = 'dividend' and f.market = p_market
                    and t.posting_key like 'dividend:' || to_char(p_date, 'YYYY') || 'Q'
                                           || extract(quarter from p_date) || ':%') then
    raise exception 'Dividends were already paid on %, so it can''t be marked closed.', public.fmt_date(p_date);
  end if;

  -- The trades that were waiting for that day's close, before it's marked closed.
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from public.requests r join public.funds f on f.id = r.fund_id
   where r.status = 'pending' and r.type = 'move' and f.market = p_market
     and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date = p_date;

  insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url)
  values (p_market, p_date, btrim(p_note), 'closed', null, true, 'Recorded by Dad in Big Bucks')
  on conflict (market, holiday_date) do update
    set name = excluded.name, kind = 'closed', closes_at = null, confirmed = true, source_url = excluded.source_url;

  -- They now wait for the next close. Each girl with one is told.
  for v_req in
    select r.id, r.account_id, r.from_vehicle, f.name as fund_name,
           public.next_close(f.market, r.created_at) as next_at
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.id = any (v_ids)
     order by r.id
  loop
    perform public.notify(v_req.account_id, 'request', 'The market was closed',
      'The ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ', so your ' || v_req.fund_name || ' '
        || case when v_req.from_vehicle = 'stock' then 'sale' else 'buy' end
        || ' will happen at the next close, on ' || public.fmt_date(public.edmonton_local(v_req.next_at)::date) || '.',
      'closure:' || p_market || ':' || p_date || ':' || v_req.id, p_request_id => v_req.id);
    v_n := v_n + 1;
  end loop;

  perform public.log_parent_action('record_market_closure', null, null,
    'Recorded that the ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ': ' || btrim(p_note) || '.',
    jsonb_build_object('market', p_market, 'date', p_date, 'note', btrim(p_note), 'trades_told', v_n));
end;
$function$;

-- 4. The holiday warning ignores Dad's own rows.
CREATE OR REPLACE FUNCTION public.parent_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                                                         where h.market = mk.market and h.source_url <> 'Recorded by Dad in Big Bucks'
                                                           and extract(year from h.holiday_date) = y.y)
                                         or exists (select 1 from public.market_holidays h
                                                     where h.market = mk.market and h.source_url <> 'Recorded by Dad in Big Bucks' and not h.confirmed
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
$function$;

-- 2. An unexpected early close.
create function public.record_early_close(p_market public.market, p_date date, p_closes_at time, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := case p_market when 'nyse' then 'New York Stock Exchange' else 'Toronto Stock Exchange' end;
  v_req record;
  v_ids bigint[];
  v_n integer := 0;
begin
  perform public.require_parent();
  if p_market is null or p_date is null or p_closes_at is null then
    raise exception 'Choose the market, the day and the time it closed (Toronto time).';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say why the market closed early (for example "Systems outage").';
  end if;
  if p_closes_at <= time '09:30' or p_closes_at >= time '16:00' then
    raise exception 'An early close is between 9:30 am and 4:00 pm, Toronto time.';
  end if;
  if p_date > public.app_today() + 366 then
    raise exception 'That''s more than a year away.';
  end if;
  if not public.is_trading_day(p_market, p_date) then
    raise exception 'The % doesn''t trade on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.market_holidays h where h.market = p_market and h.holiday_date = p_date) then
    raise exception 'The % already has an early close on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.transactions t join public.funds f on f.id = t.fund_id
              where f.market = p_market and t.vehicle = 'stock' and t.unit_price is not null
                and t.effective_at = public.close_time(p_market, p_date)) then
    raise exception 'A trade already settled at that day''s usual close, so its close time can''t change.';
  end if;

  -- The trades waiting for that day's close, before the change.
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from public.requests r join public.funds f on f.id = r.fund_id
   where r.status = 'pending' and r.type = 'move' and f.market = p_market
     and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date = p_date;

  insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url)
  values (p_market, p_date, btrim(p_note), 'early_close', p_closes_at, true, 'Recorded by Dad in Big Bucks');

  -- Those asked for after the early close now wait for the next close. Each girl is told.
  for v_req in
    select r.id, r.account_id, r.from_vehicle, f.name as fund_name,
           public.next_close(f.market, r.created_at) as next_at
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.id = any (v_ids)
       and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date <> p_date
     order by r.id
  loop
    perform public.notify(v_req.account_id, 'request', 'The market closed early',
      'The ' || v_name || ' closed early on ' || public.fmt_date(p_date) || ', before your '
        || v_req.fund_name || ' ' || case when v_req.from_vehicle = 'stock' then 'sale' else 'buy' end
        || ' could happen. It will happen at the next close, on '
        || public.fmt_date(public.edmonton_local(v_req.next_at)::date) || '.',
      'early_close:' || p_market || ':' || p_date || ':' || v_req.id, p_request_id => v_req.id);
    v_n := v_n + 1;
  end loop;

  perform public.log_parent_action('record_early_close', null, null,
    'Recorded that the ' || v_name || ' closed early on ' || public.fmt_date(p_date) || ' at '
      || to_char(p_closes_at, 'FMHH12:MI am') || ' Toronto time: ' || btrim(p_note) || '.',
    jsonb_build_object('market', p_market, 'date', p_date, 'closes_at', p_closes_at, 'note', btrim(p_note),
                       'trades_told', v_n));
end;
$$;

revoke all on function public.record_early_close(public.market, date, time, text) from public, anon, authenticated, service_role;
grant execute on function public.record_early_close(public.market, date, time, text) to authenticated;
