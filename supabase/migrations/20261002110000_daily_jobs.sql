-- Stage 2: the daily jobs and run_daily.
--
-- Each job takes a date, does that date's work, and can run any number of times:
-- automatic postings carry a unique posting_key, notices a dedupe_key and notes
-- an auto_key, so a second run writes nothing new. Each returns
-- {"status": "ok" | "waiting", ...}. "waiting" means something it needs isn't
-- there yet (a close, or the end of the day); it is safe to run again later.
--
-- Automatic postings count from their own moment (effective_at), not from when
-- the job happened to run: a trade from its close, interest and maturities from
-- the start of their day. So a catch-up run gives exactly the answer an on-time
-- run would have.
--
-- Only the server runs these (service role). run_daily(date) runs them in order
-- for every date not yet done, recording each in job_runs.

-- Deposits and withdrawals Dad hasn't answered expire 7 × 24 hours after the
-- request, releasing any hold, with a kind notice.
create function public.expire_requests(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff timestamptz := least(public.app_now(), public.edmonton_start(p_date + 1));
  v_req public.requests;
  v_count integer := 0;
begin
  for v_req in
    select * from public.requests r
     where r.status = 'pending' and r.type in ('deposit', 'withdraw')
       and r.created_at + interval '168 hours' <= v_cutoff
     order by r.id
       for update
  loop
    update public.requests
       set status = 'expired', decided_at = v_req.created_at + interval '168 hours'
     where id = v_req.id;
    perform public.notify(v_req.account_id, 'request_expired', 'Your request ran out of time',
      'Your request to ' || case v_req.type when 'deposit' then 'put in ' else 'take out ' end
        || public.fmt_money(v_req.amount_cents) || ' waited 7 days without an answer, so it was cancelled. '
        || case v_req.type when 'withdraw' then 'The money is free to use again, and you can ask again any time.'
                else 'You can ask again any time.' end,
      'expired:' || v_req.id, p_request_id => v_req.id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'expired', v_count);
end;
$$;

-- Splits that take effect on this date: scale every holding with a $0
-- split_adjust line (rounded up, so she never loses a fraction), and scale the
-- units held by pending sales.
create function public.apply_split(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_split public.fund_splits;
  v_ratio numeric;
  v_holder record;
  v_new numeric;
  v_inserted bigint;
  v_count integer := 0;
begin
  for v_split in select * from public.fund_splits s where s.split_date = p_date order by s.fund_id loop
    v_ratio := v_split.ratio_to::numeric / v_split.ratio_from;
    for v_holder in
      select t.account_id, sum(t.units) as units
        from public.transactions t
       where t.fund_id = v_split.fund_id and t.vehicle = 'stock'
         and t.effective_at < public.edmonton_start(p_date)
       group by t.account_id
      having sum(t.units) > 0
    loop
      v_new := public.round_up_units(v_holder.units * v_ratio);
      v_inserted := null;
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, posting_key,
                                       effective_at, note)
      values (v_holder.account_id, 'stock', v_split.fund_id, 'split_adjust', 0, v_new - v_holder.units,
              'split:' || v_split.fund_id || ':' || p_date || ':' || v_holder.account_id,
              public.edmonton_start(p_date),
              v_split.ratio_to || '-for-' || v_split.ratio_from || ' split: your ' || public.fmt_units(v_holder.units)
                || ' units became ' || public.fmt_units(v_new) || '. Each unit is worth less, so your holding is worth the same.')
      on conflict (posting_key) do nothing
      returning id into v_inserted;

      if v_inserted is not null then
        update public.requests r
           set held_units = public.round_up_units(r.held_units * v_ratio)
         where r.account_id = v_holder.account_id and r.fund_id = v_split.fund_id
           and r.status = 'pending' and r.from_vehicle = 'stock';
        v_count := v_count + 1;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('status', 'ok', 'adjusted', v_count);
end;
$$;

-- Settle fund trades whose close falls on or before this date, at that close.
-- A trade never settles on any other day's price: if its close is missing, it
-- waits (status "waiting") and settles once the real close arrives.
create function public.settle_trades(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req record;
  v_close_at timestamptz;
  v_close_date date;
  v_close numeric;
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

    select fp.close into v_close from public.fund_prices fp
     where fp.fund_id = v_req.fund_id and fp.price_date = v_close_date;
    if v_close is null or v_close_at > public.app_now() then
      v_waiting := v_waiting + 1;
      continue;
    end if;
    perform 1 from public.accounts a where a.id = v_req.account_id for update;

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
              'trade:' || v_req.id || ':savings', v_close_at, v_note);
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
              'trade:' || v_req.id || ':savings', v_close_at, v_note);
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
$$;

-- GICs maturing on (or, catching up, before) this date: post the interest from
-- the start of the maturity day and ask her to choose.
create function public.mature_gics(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gic public.gic_holdings;
  v_exact numeric;
  v_interest bigint;
  v_count integer := 0;
begin
  for v_gic in
    select * from public.gic_holdings g
     where g.status = 'active' and g.maturity_date <= p_date
     order by g.id
       for update
  loop
    v_exact := v_gic.principal_cents * v_gic.rate * v_gic.term_months / 1200;
    v_interest := public.gic_interest_cents(v_gic.principal_cents, v_gic.rate, v_gic.term_months);
    if v_interest > 0 then
      insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, effective_at, note)
      values (v_gic.account_id, 'gic', v_gic.id, 'interest', v_interest, 'gic_interest:' || v_gic.id,
              public.edmonton_start(v_gic.maturity_date),
              public.fmt_money(v_gic.principal_cents) || ' × ' || public.fmt_rate(v_gic.rate) || ' × '
                || v_gic.term_months || '/12 = '
                || case when v_exact = v_interest then public.fmt_money(v_interest)
                        else public.fmt_money4(v_exact) || ', rounded up to ' || public.fmt_money(v_interest) end)
      on conflict (posting_key) do nothing;
    end if;
    update public.gic_holdings set status = 'matured' where id = v_gic.id;

    perform public.notify(v_gic.account_id, 'gic_maturity', 'Your GIC is ready!',
      'Your ' || public.term_label(v_gic.term_months) || ' GIC finished and earned ' || public.fmt_money(v_interest)
        || ', so you now have ' || public.fmt_money(v_gic.principal_cents + v_interest)
        || '. Choose what happens next by ' || public.fmt_date(v_gic.maturity_date + 6)
        || ': renew it, pick a new term, or move it to savings. Until you choose, it earns the savings rate.',
      'gic_matured:' || v_gic.id, p_gic_id => v_gic.id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'matured', v_count);
end;
$$;

-- A matured GIC with no choice by the start of day 7 moves to savings then.
create function public.auto_move_unclaimed_maturities(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gic public.gic_holdings;
  v_amount bigint;
  v_note text := 'Moved to savings automatically: no choice was made within 7 days.';
  v_count integer := 0;
begin
  for v_gic in
    select * from public.gic_holdings g
     where g.status = 'matured' and g.maturity_choice is null and g.maturity_date + 7 <= p_date
     order by g.id
       for update
  loop
    perform 1 from public.accounts a where a.id = v_gic.account_id for update;
    select coalesce(sum(t.amount_cents), 0) into v_amount
      from public.transactions t where t.gic_id = v_gic.id and t.vehicle = 'gic';
    if v_amount > 0 then
      insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, effective_at, note) values
        (v_gic.account_id, 'gic', v_gic.id, 'transfer_out', -v_amount, 'gic_release:' || v_gic.id,
         public.edmonton_start(v_gic.maturity_date + 7), v_note),
        (v_gic.account_id, 'savings', v_gic.id, 'transfer_in', v_amount, 'gic_release:' || v_gic.id || ':savings',
         public.edmonton_start(v_gic.maturity_date + 7), v_note);
    end if;
    update public.gic_holdings set maturity_choice = 'to_savings' where id = v_gic.id;
    perform public.notify(v_gic.account_id, 'gic_maturity', 'Your GIC money is in savings',
      'You didn''t choose within 7 days, so your ' || public.fmt_money(v_amount)
        || ' moved to savings, where it''s safe and still earning interest.',
      'gic_auto_move:' || v_gic.id, p_gic_id => v_gic.id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'moved', v_count);
end;
$$;

-- On the first business day of January, April, July and October (per fund's
-- market): units held at the previous quarter's last close × that close × the
-- fund's yearly yield ÷ 4, rounded up to the cent, into savings.
create function public.pay_quarterly_dividends(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quarter_start date := date_trunc('quarter', p_date)::date;
  v_quarter text := to_char(p_date, 'YYYY') || 'Q' || extract(quarter from p_date);
  v_fund public.funds;
  v_last date;
  v_close_at timestamptz;
  v_close numeric;
  v_yield numeric;
  v_holder record;
  v_exact numeric;
  v_amount bigint;
  v_paid integer := 0;
  v_waiting integer := 0;
begin
  if extract(month from p_date) not in (1, 4, 7, 10) then
    return jsonb_build_object('status', 'ok', 'paid', 0);
  end if;

  for v_fund in select * from public.funds f order by f.sort_order loop
    continue when public.first_trading_day_from(v_fund.market, v_quarter_start) <> p_date;

    v_last := public.last_trading_day_before(v_fund.market, v_quarter_start);
    v_close_at := public.close_time(v_fund.market, v_last);
    select fp.close into v_close from public.fund_prices fp where fp.fund_id = v_fund.id and fp.price_date = v_last;
    v_yield := public.setting_on('dividend_yield:' || v_fund.id, p_date)::numeric;

    for v_holder in
      select t.account_id, sum(t.units) as units
        from public.transactions t
       where t.fund_id = v_fund.id and t.vehicle = 'stock' and t.effective_at <= v_close_at
       group by t.account_id
      having sum(t.units) > 0
    loop
      if v_close is null then
        v_waiting := v_waiting + 1;
        exit;
      end if;
      -- In cents: units × close × 100 × (yield ÷ 100) ÷ 4
      v_exact := v_holder.units * v_close * coalesce(v_yield, 0) / 4;
      v_amount := ceil(v_exact)::bigint;
      continue when v_amount <= 0;
      insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
      values (v_holder.account_id, 'savings', v_fund.id, 'dividend', v_amount,
              'dividend:' || v_quarter || ':' || v_fund.id || ':' || v_holder.account_id,
              public.edmonton_start(p_date),
              public.fmt_units(v_holder.units) || ' units × ' || public.fmt_money(v_close * 100) || ' × '
                || public.fmt_rate(v_yield) || ' ÷ 4 = '
                || case when v_exact = v_amount then public.fmt_money(v_amount)
                        else public.fmt_money4(v_exact) || ', rounded up to ' || public.fmt_money(v_amount) end)
      on conflict (posting_key) do nothing;
      v_paid := v_paid + 1;
    end loop;
  end loop;

  return jsonb_build_object('status', case when v_waiting > 0 then 'waiting' else 'ok' end,
                            'paid', v_paid, 'waiting_for_close', v_waiting);
end;
$$;

-- On the 1st: post last month's savings interest, the daily accruals summed and
-- rounded up to the cent, with the working.
create function public.post_monthly_interest(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from date := (p_date - interval '1 month')::date;
  v_month text := to_char(p_date - interval '1 month', 'FMMonth');
  v_acc record;
  v_amount bigint;
  v_note text;
  v_count integer := 0;
begin
  if extract(day from p_date) <> 1 then
    return jsonb_build_object('status', 'ok', 'posted', 0);
  end if;

  for v_acc in
    select ia.account_id, sum(ia.accrued) as total, count(*) as days,
           min(ia.balance_cents + ia.gic_waiting_cents) as low, max(ia.balance_cents + ia.gic_waiting_cents) as high,
           min(ia.rate) as rate_low, max(ia.rate) as rate_high, min(ia.days_in_year) as diy,
           min(ia.accrued) as daily
      from public.interest_accruals ia
     where ia.accrual_date >= v_from and ia.accrual_date < p_date
     group by ia.account_id
     order by ia.account_id
  loop
    v_amount := ceil(v_acc.total)::bigint;
    continue when v_amount <= 0;
    -- One balance and one rate all month: show the whole sum. Otherwise the total.
    v_note := v_month || ': '
      || case when v_acc.low = v_acc.high and v_acc.rate_low = v_acc.rate_high then
                public.fmt_money(v_acc.low) || ' × ' || public.fmt_rate(v_acc.rate_low) || ' ÷ ' || v_acc.diy
                || ' = ' || public.fmt_money4(v_acc.daily) || ' a day, for ' || v_acc.days || ' days = '
              else v_acc.days || ' days of interest added up to ' end
      || public.fmt_money4(v_acc.total)
      || case when v_acc.total = v_amount then '' else ', rounded up to ' || public.fmt_money(v_amount) end;
    insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
    values (v_acc.account_id, 'savings', 'interest', v_amount,
            'interest:' || to_char(v_from, 'YYYY-MM') || ':' || v_acc.account_id,
            public.edmonton_start(p_date), v_note)
    on conflict (posting_key) do nothing;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'posted', v_count);
end;
$$;

-- When a fund's close moves more than 2% from its previous close, add the
-- standard note for that day. A missing close on a trading day means "waiting".
create function public.write_market_move_notes(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_close numeric;
  v_prev numeric;
  v_change numeric;
  v_waiting integer := 0;
  v_count integer := 0;
begin
  for v_fund in select * from public.funds f order by f.sort_order loop
    continue when not public.is_trading_day(v_fund.market, p_date);
    select fp.close into v_close from public.fund_prices fp where fp.fund_id = v_fund.id and fp.price_date = p_date;
    if v_close is null then
      v_waiting := v_waiting + 1;
      continue;
    end if;
    select fp.close into v_prev from public.fund_prices fp
     where fp.fund_id = v_fund.id and fp.price_date < p_date
     order by fp.price_date desc limit 1;
    continue when v_prev is null;

    v_change := (v_close - v_prev) / v_prev;
    if abs(v_change) > 0.02 then
      insert into public.notes (note_date, fund_id, body, audience, auto_key)
      values (p_date, v_fund.id,
              public.setting_on(case when v_change > 0 then 'market_move_note_up' else 'market_move_note_down' end, p_date),
              'kids', 'move:' || v_fund.id || ':' || p_date)
      on conflict (auto_key) do nothing;
      v_count := v_count + 1;
    end if;
  end loop;
  return jsonb_build_object('status', case when v_waiting > 0 then 'waiting' else 'ok' end,
                            'notes', v_count, 'missing_closes', v_waiting);
end;
$$;

-- Rate notices on the day: a regular change going live, a special starting, a
-- special ending. (The first notice went out when Dad saved the rate.)
create function public.send_rate_notices(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rate public.rates;
  v_what text;
  v_back numeric;
  v_account uuid;
  v_count integer := 0;
begin
  -- Going live today (skip a change saved today: its first notice already said "today").
  for v_rate in
    select * from public.rates r
     where r.effective_date = p_date and (r.created_at at time zone 'America/Edmonton')::date < p_date
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
  for v_rate in select * from public.rates r where r.is_special and r.end_date = p_date - 1 order by r.id loop
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
  return jsonb_build_object('status', 'ok', 'notices', v_count);
end;
$$;

-- Savings interest for one finished day: end-of-day savings (held money
-- included) plus matured GIC money waiting for her choice, × that day's savings
-- rate ÷ the days in that year, kept as fractional cents. Waits until the day is over.
create function public.accrue_savings_interest(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_end timestamptz := public.edmonton_start(p_date + 1);
  v_rate record;
  v_days smallint := case when extract(doy from make_date(extract(year from p_date)::int, 12, 31)) = 366 then 366 else 365 end;
  v_acc record;
  v_count integer := 0;
begin
  if p_date >= public.app_today() then
    return jsonb_build_object('status', 'waiting', 'reason', 'the day isn''t over yet');
  end if;
  select r.rate, r.rate_id into v_rate from public.rate_on('savings', null, p_date) r;
  if v_rate.rate is null then
    raise exception 'No savings rate for %.', p_date;
  end if;

  for v_acc in
    select a.id,
           public.vehicle_cents(a.id, 'savings', v_end) as savings,
           coalesce((select sum(t.amount_cents) from public.transactions t
                      join public.gic_holdings g on g.id = t.gic_id
                     where t.account_id = a.id and t.vehicle = 'gic' and t.effective_at < v_end
                       and g.status = 'matured' and g.maturity_date <= p_date), 0)::bigint as waiting
      from public.accounts a
     order by a.id
  loop
    continue when v_acc.savings + v_acc.waiting <= 0;
    insert into public.interest_accruals (account_id, accrual_date, balance_cents, gic_waiting_cents, rate, rate_id,
                                          days_in_year, accrued)
    values (v_acc.id, p_date, v_acc.savings, v_acc.waiting, v_rate.rate, v_rate.rate_id, v_days,
            (v_acc.savings + v_acc.waiting) * v_rate.rate / 100 / v_days)
    on conflict (account_id, accrual_date) do nothing;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'accounts', v_count);
end;
$$;

-- run_daily: every job, in order, for every date from the first one not yet done
-- through p_through. A job that is "waiting" or fails stops the run at that date
-- (except the market-move notes, which never hold anything up), so nothing is
-- ever processed out of order. The next run starts again from there.
create function public.run_daily(p_through date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- job name, function, blocks later dates when not ok
  v_jobs constant text[][] := array[
    ['expire',       'expire_requests',                'true'],
    ['splits',       'apply_split',                    'true'],
    ['settle',       'settle_trades',                  'true'],
    ['gic_maturity', 'mature_gics',                    'true'],
    ['auto_move',    'auto_move_unclaimed_maturities', 'true'],
    ['dividends',    'pay_quarterly_dividends',        'true'],
    ['monthly',      'post_monthly_interest',          'true'],
    ['notes',        'write_market_move_notes',        'false'],
    ['rate_notices', 'send_rate_notices',              'true'],
    ['interest',     'accrue_savings_interest',        'true']];
  v_names public.job_name[];
  v_today date := public.app_today();
  v_start date;
  v_day date;
  v_i integer;
  v_job public.job_name;
  v_result jsonb;
  v_status public.job_status;
  v_blocked boolean;
  v_problems jsonb := '[]'::jsonb;
  v_overall text := 'ok';
  v_last_done date;
begin
  if p_through > v_today then
    raise exception 'Can''t run the jobs for % because it hasn''t happened yet (it''s in the future).', p_through;
  end if;

  select array_agg(v_jobs[i][1]::public.job_name) into v_names from generate_subscripts(v_jobs, 1) i;

  -- Start at the earliest date with an unfinished job, else the day after the last
  -- finished one, else (first ever run) the day the first account was opened.
  select least(
           (select min(jr.run_for_date) from public.job_runs jr
             where jr.job = any (v_names) and jr.status <> 'ok'
               and not exists (select 1 from public.job_runs ok
                                where ok.job = jr.job and ok.run_for_date = jr.run_for_date and ok.status = 'ok')),
           (select max(jr.run_for_date) + 1 from public.job_runs jr where jr.job = any (v_names) and jr.status = 'ok'))
    into v_start;
  v_start := coalesce(v_start,
                      (select min((a.created_at at time zone 'America/Edmonton')::date) from public.accounts a),
                      p_through);

  v_day := v_start;
  while v_day <= p_through loop
    v_blocked := false;
    for v_i in 1 .. array_length(v_jobs, 1) loop
      v_job := v_jobs[v_i][1]::public.job_name;
      continue when exists (select 1 from public.job_runs jr
                             where jr.job = v_job and jr.run_for_date = v_day and jr.status = 'ok');

      if v_job = 'interest' and v_blocked then
        v_status := 'retrying';
        v_result := jsonb_build_object('status', 'waiting', 'reason', 'waiting for the other jobs for this day');
      else
        begin
          execute format('select public.%I($1)', v_jobs[v_i][2]) into v_result using v_day;
          v_status := case when v_result ->> 'status' = 'ok' then 'ok' else 'retrying' end;
        exception when others then
          v_status := 'failed';
          v_result := jsonb_build_object('status', 'failed', 'error', sqlerrm, 'sqlstate', sqlstate);
        end;
      end if;

      insert into public.job_runs (job, run_for_date, status, details, finished_at)
      values (v_job, v_day, v_status, v_result, public.app_now());

      if v_status <> 'ok' and v_jobs[v_i][3] = 'true' then
        v_blocked := true;
        -- Tonight's accrual waiting for the day to end is normal, not a problem.
        if not (v_job = 'interest' and v_day >= v_today and v_result ->> 'reason' = 'the day isn''t over yet') then
          v_problems := v_problems || jsonb_build_object('date', v_day, 'job', v_job, 'status', v_status, 'details', v_result);
          v_overall := case when v_status = 'failed' or v_overall = 'failed' then 'failed' else 'waiting' end;
        end if;
      end if;
    end loop;

    exit when v_blocked and v_overall <> 'ok';
    v_last_done := v_day;
    v_day := v_day + 1;
  end loop;

  return jsonb_build_object('status', v_overall, 'from', v_start, 'through', p_through,
                            'completed_through', v_last_done, 'problems', v_problems);
end;
$$;

