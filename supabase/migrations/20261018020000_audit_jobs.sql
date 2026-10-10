-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). The nightly jobs.
--
-- Dad's decisions (2026-10-08):
--
-- 1. Savings interest and GICs never wait for fund prices. The nightly run now
--    has two chains. The fund chain (splits, settlement, dividends, market-move
--    notes) waits for each market's real close, day by day, as before. The rest
--    (request expiry, GIC maturities and their 7-day moves, monthly interest,
--    rate notices, daily interest) carries on even while a close is missing.
--
--    When a trade or dividend posts after that day's interest has already been
--    worked out, its savings side counts from the start of the first day whose
--    interest isn't worked out yet, so interest already worked out never changes.
--    The fund side still counts from the real close. Money that reaches savings
--    late (a sale's proceeds, a dividend) also gets the savings interest it would
--    have earned on the days it waited, as its own "Interest" line, rounded up.
--    Money that leaves savings late (a buy) simply earned interest a little longer.
--
-- 2. If the nightly run falls behind (a missed night, a failed job), she never
--    loses her 7 days to choose for a matured GIC: the window is stretched by the
--    number of days the maturity was late being processed (gic_holdings.choice_ends).
--
-- 3. Dividends are paid only for the days each unit was held in the quarter
--    (pro-rata): units held at the end of each day of the quarter, added up, ÷ the
--    quarter's days, × the quarter's last close × the yearly yield ÷ 4, rounded up.
--    Units from before a split in the quarter are counted in after-split units, to
--    match the close.
--
-- Also (audit): settlement, dividends and market-move notes use only final closes
-- (final_close, from 20261018010000_audit_prices.sql).

-- 1. Helpers -------------------------------------------------------------------------------------------

-- The last day whose savings interest is worked out (null before the first).
create function public.interest_done_through()
returns date
language sql stable
set search_path = ''
as $$
  select max(jr.run_for_date) from public.job_runs jr where jr.job = 'interest' and jr.status = 'ok';
$$;

-- When money posted now for moment p_at counts in savings: p_at itself, or, if that
-- day's interest is already worked out, the start of the first day that isn't.
create function public.savings_moment(p_at timestamptz)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select greatest(p_at, coalesce(public.edmonton_start(public.interest_done_through() + 1), p_at));
$$;

-- Exactly the savings interest p_cents would have earned from p_from to p_to
-- (whole days, both included), at each day's savings rate.
create function public.late_interest_exact(p_cents bigint, p_from date, p_to date)
returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce(sum(p_cents * (select r.rate from public.rate_on('savings', null, d::date) r) / 100
                      / case when extract(doy from make_date(extract(year from d)::int, 12, 31)) = 366 then 366 else 365 end),
                  0)
    from generate_series(p_from, p_to, interval '1 day') d;
$$;

-- Internal: posts the interest money waited for. p_from is the day it should have
-- started counting; p_at is when it really counts (an Alberta midnight).
create function public.post_late_interest(p_account uuid, p_cents bigint, p_from date, p_at timestamptz,
                                          p_key text, p_what text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_to date := public.edmonton_local(p_at)::date - 1;
  v_exact numeric;
  v_amount bigint;
begin
  if p_cents <= 0 or v_to < p_from then
    return;
  end if;
  v_exact := public.late_interest_exact(p_cents, p_from, v_to);
  v_amount := ceil(v_exact)::bigint;
  if v_amount <= 0 then
    return;
  end if;
  insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
  values (p_account, 'savings', 'interest', v_amount, 'late_interest:' || p_key, p_at,
          'Interest for the ' || (v_to - p_from + 1) || ' day' || case when v_to > p_from then 's' else '' end
            || ' ' || p_what || ' waited to reach your savings ('
            || case when v_to > p_from then public.fmt_date(p_from) || ' to ' else '' end || public.fmt_date(v_to)
            || '): ' || public.fmt_money(p_cents) || ' at the savings rate = ' || public.fmt_money4(v_exact)
            || case when v_exact = v_amount then '' else ', rounded up to ' || public.fmt_money(v_amount) end || '.')
  on conflict (posting_key) do nothing;
end;
$$;

-- Units × days for a quarter, for the pro-rata dividend: Σ over each day d of the
-- quarter of the units held at the end of d, counted in units as of the quarter's
-- last close (later splits in the quarter applied). Returned scaled by p_den (the
-- product of the "from" sides of those splits) so that it stays exact:
-- unit_days × den. p_den is 1 when no split happened in the quarter. Also: on how many
-- days she held any units (for the line's working).
create function public.dividend_unit_days(p_account uuid, p_fund text, p_qstart date, p_qend date, p_last date,
                                          out unit_days_x_den numeric, out den bigint, out days_held integer)
language plpgsql stable
set search_path = ''
as $$
declare
  v_splits public.fund_splits[];
  v_s public.fund_splits;
  v_day date;
  v_mult bigint;
  v_units numeric;
begin
  select coalesce(array_agg(s order by s.split_date), '{}') into v_splits from public.fund_splits s
   where s.fund_id = p_fund and s.split_date > p_qstart and s.split_date <= p_last;
  den := 1;
  foreach v_s in array v_splits loop
    den := den * v_s.ratio_from;
  end loop;
  unit_days_x_den := 0;
  days_held := 0;
  for v_day in select d::date from generate_series(p_qstart, p_qend, interval '1 day') d loop
    -- Splits after this day: their "to" side; splits on or before it: their "from" side.
    v_mult := 1;
    foreach v_s in array v_splits loop
      v_mult := v_mult * case when v_s.split_date > v_day then v_s.ratio_to else v_s.ratio_from end;
    end loop;
    select coalesce(sum(t.units), 0) into v_units from public.transactions t
     where t.account_id = p_account and t.fund_id = p_fund and t.vehicle = 'stock'
       and t.effective_at < public.edmonton_start(v_day + 1);
    unit_days_x_den := unit_days_x_den + v_mult * v_units;
    if v_units > 0 then
      days_held := days_held + 1;
    end if;
  end loop;
end;
$$;

-- The quarter a dividend is paid in, from its posting key (dividend:2027Q1:dow:<account>): its first day.
create function public.dividend_quarter_start(p_posting_key text)
returns date
language sql immutable
set search_path = ''
as $$
  select make_date(substr(split_part(p_posting_key, ':', 2), 1, 4)::int,
                   (substr(split_part(p_posting_key, ':', 2), 6, 1)::int - 1) * 3 + 1, 1);
$$;

-- a ÷ b rounded up, exactly (b > 0).
create function public.ceil_div(p_a numeric, p_b numeric)
returns bigint
language plpgsql immutable
set search_path = ''
as $$
declare
  v_q numeric := div(p_a, p_b);
begin
  if v_q * p_b < p_a then
    v_q := v_q + 1;
  end if;
  return v_q::bigint;
end;
$$;

-- 2. GIC choice window ----------------------------------------------------------------------------------

alter table public.gic_holdings add column choice_ends date;
comment on column public.gic_holdings.choice_ends is
  'A matured GIC: the day it moves to savings if she hasn''t chosen (her last day to choose is the day before). '
  'Maturity + 7, plus however many days late the maturity was processed.';
update public.gic_holdings set choice_ends = maturity_date + 7 where status = 'matured';

create or replace function public.mature_gics(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gic public.gic_holdings;
  v_exact numeric;
  v_interest bigint;
  v_ends date;
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
    -- She hears about it today: if that's later than the maturity date, she still gets her 7 days.
    v_ends := v_gic.maturity_date + 7 + greatest(public.app_today() - v_gic.maturity_date, 0);
    update public.gic_holdings set status = 'matured', choice_ends = v_ends where id = v_gic.id;

    perform public.notify(v_gic.account_id, 'gic_maturity', 'Your GIC is ready!',
      'Your ' || public.term_label(v_gic.term_months) || ' GIC finished and earned ' || public.fmt_money(v_interest)
        || ', so you now have ' || public.fmt_money(v_gic.principal_cents + v_interest)
        || '. Choose what happens next by ' || public.fmt_date(v_ends - 1)
        || ': renew it, pick a new term, or move it to savings. Until you choose, it earns the savings rate.',
      'gic_matured:' || v_gic.id, p_gic_id => v_gic.id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'matured', v_count);
end;
$$;

create or replace function public.auto_move_unclaimed_maturities(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gic public.gic_holdings;
  v_amount bigint;
  v_note text;
  v_count integer := 0;
begin
  for v_gic in
    select * from public.gic_holdings g
     where g.status = 'matured' and g.maturity_choice is null and g.choice_ends <= p_date
     order by g.id
       for update
  loop
    perform 1 from public.accounts a where a.id = v_gic.account_id for update;
    v_note := 'Moved to savings automatically: no choice was made by ' || public.fmt_date(v_gic.choice_ends - 1) || '.';
    select coalesce(sum(t.amount_cents), 0) into v_amount
      from public.transactions t where t.gic_id = v_gic.id and t.vehicle = 'gic';
    if v_amount > 0 then
      insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, effective_at, note) values
        (v_gic.account_id, 'gic', v_gic.id, 'transfer_out', -v_amount, 'gic_release:' || v_gic.id,
         public.edmonton_start(v_gic.choice_ends), v_note),
        (v_gic.account_id, 'savings', v_gic.id, 'transfer_in', v_amount, 'gic_release:' || v_gic.id || ':savings',
         public.edmonton_start(v_gic.choice_ends), v_note);
    end if;
    update public.gic_holdings set maturity_choice = 'to_savings' where id = v_gic.id;
    perform public.notify(v_gic.account_id, 'gic_maturity', 'Your GIC money is in savings',
      'You didn''t choose by ' || public.fmt_date(v_gic.choice_ends - 1) || ', so your ' || public.fmt_money(v_amount)
        || ' moved to savings, where it''s safe and still earning interest.',
      'gic_auto_move:' || v_gic.id, p_gic_id => v_gic.id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status', 'ok', 'moved', v_count);
end;
$$;

create or replace function public.choose_maturity(p_gic_id bigint, p_choice public.maturity_choice, p_new_term integer default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_today date := public.app_today();
  v_gic public.gic_holdings;
  v_amount bigint;
  v_term integer;
  v_rate record;
  v_new bigint;
begin
  select * into v_gic from public.gic_holdings g where g.id = p_gic_id for update;
  if not found or v_gic.account_id <> v_account then
    raise exception 'That GIC isn''t yours.' using errcode = '42501';
  end if;
  if v_gic.status = 'active' then
    raise exception 'This GIC hasn''t matured yet.';
  end if;
  if v_gic.status = 'broken' then
    raise exception 'This GIC was broken early, so there''s nothing to choose.';
  end if;
  if v_gic.maturity_choice is not null then
    raise exception 'You already chose what happens to this GIC.';
  end if;
  if public.app_now() >= public.edmonton_start(v_gic.choice_ends) then
    raise exception 'The 7 days to choose are over, so this money is moving to savings.';
  end if;
  if p_choice is null then
    raise exception 'Choose renew, a new term, or savings.';
  end if;

  select coalesce(sum(t.amount_cents), 0) into v_amount
    from public.transactions t where t.gic_id = p_gic_id and t.vehicle = 'gic';

  if p_choice = 'to_savings' then
    insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, note) values
      (v_account, 'gic', p_gic_id, 'transfer_out', -v_amount, 'gic_release:' || p_gic_id,
       'Moved your matured GIC to savings.'),
      (v_account, 'savings', p_gic_id, 'transfer_in', v_amount, 'gic_release:' || p_gic_id || ':savings',
       'Moved your matured GIC to savings.');
  else
    v_term := case when p_choice = 'renew' then v_gic.term_months else p_new_term end;
    if v_term is null or v_term not in (1, 3, 6, 9, 12, 24) then
      raise exception 'A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.';
    end if;
    select r.rate, r.rate_id into v_rate from public.rate_on('gic', v_term, v_today) r;
    if v_rate.rate is null then
      raise exception 'There is no rate for a % GIC yet.', public.term_label(v_term);
    end if;

    insert into public.gic_holdings (account_id, principal_cents, rate, rate_id, term_months, start_date,
                                     maturity_date, renewed_from_id)
    values (v_account, v_amount, v_rate.rate, v_rate.rate_id, v_term, v_today,
            (v_today + make_interval(months => v_term))::date, p_gic_id)
    returning id into v_new;

    insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, note) values
      (v_account, 'gic', p_gic_id, 'transfer_out', -v_amount, 'gic_renew:' || p_gic_id || ':out',
       'Moved into a new ' || public.term_label(v_term) || ' GIC at ' || public.fmt_rate(v_rate.rate) || '.'),
      (v_account, 'gic', v_new, 'transfer_in', v_amount, 'gic_renew:' || p_gic_id || ':in',
       'A new ' || public.term_label(v_term) || ' GIC at ' || public.fmt_rate(v_rate.rate)
       || ', from your matured GIC (' || public.fmt_money(v_gic.principal_cents) || ' + '
       || public.fmt_money(v_amount - v_gic.principal_cents) || ' interest).');
  end if;

  update public.gic_holdings set maturity_choice = p_choice where id = p_gic_id;
  return v_new;
end;
$$;

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
       case when g.status = 'matured' and g.maturity_choice is null then g.choice_ends - 1 end as choose_by
  from public.gic_holdings g
  left join lateral (
    select sum(t.amount_cents) as balance_cents
      from public.transactions t
     where t.gic_id = g.id and t.vehicle = 'gic') b on true;

-- 3. Settlement: final closes, and late money ---------------------------------------------------------

create or replace function public.settle_trades(p_date date)
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
$$;

-- 4. Dividends: pro-rata, final closes, late money -----------------------------------------------------

create or replace function public.pay_quarterly_dividends(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.write_market_move_notes(p_date date)
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
    v_close := public.final_close(v_fund.id, p_date);
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

-- 5. The nightly run: two chains -----------------------------------------------------------------------

create or replace function public.run_daily(p_through date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- job name, function, chain, blocks its chain's later work when not ok
  v_jobs constant text[][] := array[
    ['expire',       'expire_requests',                'core', 'true'],
    ['splits',       'apply_split',                    'fund', 'true'],
    ['settle',       'settle_trades',                  'fund', 'true'],
    ['dividends',    'pay_quarterly_dividends',        'fund', 'true'],
    ['notes',        'write_market_move_notes',        'fund', 'false'],
    ['gic_maturity', 'mature_gics',                    'core', 'true'],
    ['auto_move',    'auto_move_unclaimed_maturities', 'core', 'true'],
    ['monthly',      'post_monthly_interest',          'core', 'true'],
    ['rate_notices', 'send_rate_notices',              'core', 'true'],
    ['interest',     'accrue_savings_interest',        'core', 'true']];
  v_names public.job_name[];
  v_today date := public.app_today();
  v_start date;
  v_day date;
  v_i integer;
  v_job public.job_name;
  v_result jsonb;
  v_status public.job_status;
  v_fund_blocked boolean := false;  -- an earlier day's fund work is still waiting: later days' wait too
  v_core_blocked boolean;           -- today's core work isn't all done: interest waits
  v_core_problem boolean := false;  -- a core job failed or waited (not just "the day isn't over")
  v_problems jsonb := '[]'::jsonb;
  v_overall text := 'ok';
  v_last_done date;
  v_core_done date;
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
                      (select min(public.edmonton_local(a.created_at)::date) from public.accounts a),
                      p_through);

  v_day := v_start;
  while v_day <= p_through loop
    v_core_blocked := false;
    for v_i in 1 .. array_length(v_jobs, 1) loop
      v_job := v_jobs[v_i][1]::public.job_name;
      continue when exists (select 1 from public.job_runs jr
                             where jr.job = v_job and jr.run_for_date = v_day and jr.status = 'ok');
      -- Fund work goes in order, day by day: nothing for a later day while an earlier one waits.
      continue when v_jobs[v_i][3] = 'fund' and v_fund_blocked;

      if v_job = 'interest' and v_core_blocked then
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

      if v_status <> 'ok' and v_jobs[v_i][4] = 'true' then
        if v_jobs[v_i][3] = 'fund' then
          v_fund_blocked := true;
        else
          v_core_blocked := true;
        end if;
        -- Tonight's accrual waiting for the day to end is normal, not a problem.
        if not (v_job = 'interest' and v_day >= v_today and v_result ->> 'reason' = 'the day isn''t over yet') then
          v_problems := v_problems || jsonb_build_object('date', v_day, 'job', v_job, 'status', v_status, 'details', v_result);
          v_overall := case when v_status = 'failed' or v_overall = 'failed' then 'failed' else 'waiting' end;
          if v_jobs[v_i][3] = 'core' then
            v_core_problem := true;
          end if;
        end if;
      end if;
    end loop;

    -- A core job that can't finish holds up every later day.
    exit when v_core_problem;
    v_core_done := v_day;
    if not v_fund_blocked then
      v_last_done := v_day;
    end if;
    v_day := v_day + 1;
  end loop;

  return jsonb_build_object('status', v_overall, 'from', v_start, 'through', p_through,
                            'completed_through', v_last_done, 'core_completed_through', v_core_done,
                            'problems', v_problems);
end;
$$;

-- 6. Reconciliation: late money, pro-rata dividends, the stretched GIC window ---------------------------

create or replace function public.reconcile_account_core(p_account uuid, p_date date, p_jobs_done date, p_interest_done date)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_end timestamptz := public.edmonton_start(p_date + 1);
  v_is_today boolean := p_date = public.app_today();
  v_opened date;
  v_problems jsonb := '[]'::jsonb;
  v_savings bigint;
  v_gic bigint;
  v_fund_value bigint := 0;
  v_fund_cost bigint := 0;
  v_cat bigint;
  v_realised bigint := 0;
  v_r record;
  v_g record;
  v_req public.requests;
  v_gh public.gic_holdings;
  v_close numeric;
  v_close_at timestamptz;
  v_expected numeric;
  v_units numeric;
  v_n bigint;
  v_day date;
  v_last date;
  v_qstart date;
  v_yield numeric;
  v_month_from date;
  v_split public.fund_splits;
  v_market public.market;
  v_db record;
  v_view record;
  v_held bigint;
  v_ud record;
  v_days integer;
  v_src public.transactions;
  v_from date;
  v_stock_at timestamptz;
  v_savings_at timestamptz;
begin
  select public.edmonton_local(a.created_at)::date into v_opened from public.accounts a where a.id = p_account;

  -- 1. Nothing negative at the end of the day ---------------------------------
  select coalesce(sum(t.amount_cents), 0) into v_savings from public.transactions t
   where t.account_id = p_account and t.vehicle = 'savings' and t.effective_at < v_end;
  select coalesce(sum(t.amount_cents), 0) into v_gic from public.transactions t
   where t.account_id = p_account and t.vehicle = 'gic' and t.effective_at < v_end;
  if v_savings < 0 then
    v_problems := v_problems || public.recon_problem('negative', 'Savings is below zero.',
      jsonb_build_object('savings_cents', v_savings));
  end if;
  for v_r in
    select t.gic_id, sum(t.amount_cents) as bal from public.transactions t
     where t.account_id = p_account and t.vehicle = 'gic' and t.effective_at < v_end
     group by t.gic_id having sum(t.amount_cents) < 0
  loop
    v_problems := v_problems || public.recon_problem('negative', 'A GIC is below zero.',
      jsonb_build_object('gic_id', v_r.gic_id, 'balance_cents', v_r.bal));
  end loop;

  -- Fund units, cost and value (to the nearest cent, as the screens show it).
  for v_r in
    select t.fund_id, sum(t.units) as units, sum(t.amount_cents)::bigint as cost
      from public.transactions t
     where t.account_id = p_account and t.vehicle = 'stock' and t.effective_at < v_end
     group by t.fund_id
  loop
    if v_r.units < 0 then
      v_problems := v_problems || public.recon_problem('negative', 'A fund has fewer than zero units.',
        jsonb_build_object('fund', v_r.fund_id, 'units', v_r.units));
    end if;
    if v_r.units = 0 and v_r.cost <> 0 then
      v_problems := v_problems || public.recon_problem('fund_cost', 'A fund with no units still has a cost.',
        jsonb_build_object('fund', v_r.fund_id, 'cost_cents', v_r.cost));
    end if;
    select fp.close into v_close from public.fund_prices fp
     where fp.fund_id = v_r.fund_id and fp.price_date <= p_date order by fp.price_date desc limit 1;
    v_fund_value := v_fund_value + coalesce(round(v_r.units * v_close * 100), 0)::bigint;
    v_fund_cost := v_fund_cost + v_r.cost;
  end loop;

  -- 2. Every ledger line explained by its rule, with the right amount ------------
  -- Lines that a correction reverses are settled by that correction, so skip them.
  for v_r in
    select t.* from public.transactions t
     where t.account_id = p_account and t.effective_at < v_end
       and t.type not in ('transfer_in', 'transfer_out')
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
     order by t.id
  loop
    if v_r.type in ('deposit', 'withdraw') then
      select * into v_req from public.requests r where r.id = v_r.request_id;
      if not found or v_req.account_id <> p_account or v_req.type::text <> v_r.type::text
         or v_req.status <> 'approved'
         or v_r.amount_cents <> (case v_r.type when 'deposit' then v_req.amount_cents else -v_req.amount_cents end) then
        v_problems := v_problems || public.recon_problem('posting',
          'A ' || v_r.type || ' line doesn''t match an approved request.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'request_id', v_r.request_id));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'savings' and v_r.posting_key like 'late\_interest:%' then
      -- Interest for money that reached savings late: the line it follows, from the day
      -- it should have counted to the day before it did, at each day's savings rate.
      select * into v_src from public.transactions t
       where t.account_id = p_account and t.vehicle = 'savings'
         and t.posting_key = case when v_r.posting_key like 'late\_interest:trade:%'
                                  then substr(v_r.posting_key, 15) || ':savings'
                                  else substr(v_r.posting_key, 15) end;
      v_from := null;
      if v_src.id is not null and v_src.type = 'dividend' then
        select f.market into v_market from public.funds f where f.id = v_src.fund_id;
        v_from := public.first_trading_day_from(v_market, public.dividend_quarter_start(v_src.posting_key));
      elsif v_src.id is not null then
        select * into v_req from public.requests r where r.id = v_src.request_id;
        select f.market into v_market from public.funds f where f.id = v_req.fund_id;
        v_from := public.edmonton_local(public.next_close(v_market, v_req.created_at))::date;
      end if;
      v_expected := case when v_from is not null
                         then ceil(public.late_interest_exact(v_src.amount_cents, v_from,
                                                              public.edmonton_local(v_src.effective_at)::date - 1)) end;
      if v_src.id is null or v_r.effective_at <> v_src.effective_at or v_expected is null
         or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A late-money interest line isn''t the interest that money missed, rounded up.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'savings' then
      v_day := public.edmonton_local(v_r.effective_at)::date;
      v_month_from := (v_day - interval '1 month')::date;
      select ceil(coalesce(sum(ia.accrued), 0)) into v_expected from public.interest_accruals ia
       where ia.account_id = p_account and ia.accrual_date >= v_month_from and ia.accrual_date < v_day;
      if extract(day from v_day) <> 1 or v_r.effective_at <> public.edmonton_start(v_day)
         or v_r.posting_key is distinct from 'interest:' || to_char(v_month_from, 'YYYY-MM') || ':' || p_account
         or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A savings interest line isn''t last month''s accruals rounded up.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'gic' then
      select * into v_gh from public.gic_holdings g where g.id = v_r.gic_id;
      v_expected := ceil(v_gh.principal_cents * v_gh.rate * v_gh.term_months / 1200);
      if v_gh.account_id <> p_account or v_gh.status = 'broken' or v_r.amount_cents <> v_expected
         or v_r.effective_at <> public.edmonton_start(v_gh.maturity_date)
         or (select count(*) from public.transactions x
              where x.gic_id = v_r.gic_id and x.vehicle = 'gic' and x.type = 'interest') <> 1 then
        v_problems := v_problems || public.recon_problem('posting',
          'A GIC interest line isn''t principal × rate × term ÷ 12, rounded up, on its maturity date.',
          jsonb_build_object('transaction_id', v_r.id, 'gic_id', v_r.gic_id, 'amount_cents', v_r.amount_cents,
                             'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'dividend' then
      -- The quarter comes from the posting key (dividend:2027Q1:dow:<account>): it's paid
      -- on that quarter's first trading day, or later if the close came late.
      select f.market into v_market from public.funds f where f.id = v_r.fund_id;
      v_qstart := public.dividend_quarter_start(v_r.posting_key);
      v_day := public.first_trading_day_from(v_market, v_qstart);
      v_last := public.last_trading_day_before(v_market, v_qstart);
      v_close := public.final_close(v_r.fund_id, v_last);
      v_yield := coalesce(public.setting_on('dividend_yield:' || v_r.fund_id, v_day)::numeric, 0);
      v_days := v_qstart - (v_qstart - interval '3 months')::date;
      select * into v_ud from public.dividend_unit_days(p_account, v_r.fund_id, (v_qstart - interval '3 months')::date,
                                                        v_qstart - 1, v_last);
      v_expected := case when v_close is not null
                         then public.ceil_div(v_ud.unit_days_x_den * v_close * v_yield, 4 * v_days * v_ud.den) end;
      if v_r.posting_key is distinct from
            'dividend:' || to_char(v_qstart, 'YYYY') || 'Q' || extract(quarter from v_qstart) || ':' || v_r.fund_id || ':' || p_account
         or v_r.effective_at < public.edmonton_start(v_day)
         or (v_r.effective_at > public.edmonton_start(v_day)
             and v_r.effective_at <> public.edmonton_start(public.edmonton_local(v_r.effective_at)::date))
         or v_expected is null or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A dividend line isn''t the units held each day ÷ the quarter''s days × close × yield ÷ 4, rounded up, '
            || 'on the quarter''s first trading day.',
          jsonb_build_object('transaction_id', v_r.id, 'fund', v_r.fund_id, 'amount_cents', v_r.amount_cents,
                             'expected_cents', v_expected));
      elsif v_r.effective_at > public.edmonton_start(v_day) and not exists (
              select 1 from public.transactions x where x.posting_key = 'late_interest:' || v_r.posting_key)
            and ceil(public.late_interest_exact(v_r.amount_cents, v_day,
                                                public.edmonton_local(v_r.effective_at)::date - 1)) > 0 then
        v_problems := v_problems || public.recon_problem('posting',
          'A dividend reached savings late without the interest it missed.',
          jsonb_build_object('transaction_id', v_r.id));
      end if;

    elsif v_r.type = 'split_adjust' then
      v_day := public.edmonton_local(v_r.effective_at)::date;
      select * into v_split from public.fund_splits s where s.fund_id = v_r.fund_id and s.split_date = v_day;
      select coalesce(sum(t.units), 0) into v_units from public.transactions t
       where t.account_id = p_account and t.fund_id = v_r.fund_id and t.vehicle = 'stock' and t.effective_at < v_r.effective_at;
      v_expected := ceil(v_units * v_split.ratio_to / v_split.ratio_from * 100000000) / 100000000 - v_units;
      if v_split.fund_id is null or v_r.effective_at <> public.edmonton_start(v_day) or v_r.units <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A split line doesn''t scale her units by the split ratio.',
          jsonb_build_object('transaction_id', v_r.id, 'units', v_r.units, 'expected_units', v_expected));
      end if;

    elsif v_r.type = 'correction' then
      null; -- An open, noted fix (the table insists on the note). Counted in total worth below.

    else
      v_problems := v_problems || public.recon_problem('posting',
        'A ' || v_r.type || ' line has no rule that explains it.',
        jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents));
    end if;
  end loop;

  -- Moves between vehicles come in pairs that share a posting-key stem.
  for v_r in
    select t.* from public.transactions t
     where t.account_id = p_account and t.effective_at < v_end
       and t.type in ('transfer_in', 'transfer_out')
       and (t.posting_key is null
            or split_part(t.posting_key, ':', 1) not in ('gic_buy', 'gic_break', 'gic_release', 'gic_renew', 'trade'))
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
  loop
    v_problems := v_problems || public.recon_problem('posting', 'A move line has no rule that explains it.',
      jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents));
  end loop;

  for v_g in
    select split_part(t.posting_key, ':', 1) as kind, split_part(t.posting_key, ':', 2)::bigint as ref,
           count(*) as n, sum(t.amount_cents)::bigint as net,
           count(distinct t.effective_at) as moments, min(t.effective_at) as at,
           min(t.effective_at) filter (where t.vehicle = 'stock') as stock_at,
           min(t.effective_at) filter (where t.vehicle = 'savings') as savings_at,
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'savings'), 0)::bigint as savings_cents,
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'stock'), 0)::bigint as stock_cents,
           sum(t.units) filter (where t.vehicle = 'stock') as units,
           max(t.unit_price) as unit_price,
           array_agg(t.id order by t.id) as ids
      from public.transactions t
     where t.account_id = p_account
       and t.type in ('transfer_in', 'transfer_out')
       and split_part(t.posting_key, ':', 1) in ('gic_buy', 'gic_break', 'gic_release', 'gic_renew', 'trade')
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
     group by 1, 2
    having min(t.effective_at) < v_end
  loop
    if v_g.kind = 'trade' then
      -- A trade's fund side counts from its close; its savings side too, or from a later
      -- Alberta midnight when the close came after that day's interest was worked out.
      select * into v_req from public.requests r where r.id = v_g.ref;
      select f.market into v_market from public.funds f where f.id = v_req.fund_id;
      v_close_at := public.next_close(v_market, v_req.created_at);
      v_close := public.final_close(v_req.fund_id, (v_close_at at time zone 'America/Toronto')::date);
      if v_g.n <> 2 or v_g.stock_at is null or v_g.savings_at is null then
        v_problems := v_problems || public.recon_problem('posting', 'A move isn''t exactly two matching lines.',
          jsonb_build_object('transaction_ids', to_jsonb(v_g.ids)));
        continue;
      end if;
      if v_req.account_id <> p_account or v_req.status <> 'settled' or v_g.stock_at <> v_close_at
         or v_close is null or v_g.unit_price <> v_close
         or (v_g.savings_at <> v_close_at
             and (v_g.savings_at < v_close_at
                  or v_g.savings_at <> public.edmonton_start(public.edmonton_local(v_g.savings_at)::date))) then
        v_problems := v_problems || public.recon_problem('posting',
          'A trade didn''t settle at its own close.',
          jsonb_build_object('request_id', v_g.ref, 'settled_at', v_g.stock_at, 'expected_at', v_close_at));
      elsif v_req.to_vehicle = 'stock' then
        -- A buy: what she paid leaves savings; units = amount ÷ close, rounded up at 8 places.
        v_expected := ceil(v_req.amount_cents / 100.0 / v_close * 100000000) / 100000000;
        if v_g.net <> 0 or v_g.savings_cents <> -v_req.amount_cents or v_g.units <> v_expected then
          v_problems := v_problems || public.recon_problem('posting',
            'A fund buy doesn''t match amount ÷ close.',
            jsonb_build_object('request_id', v_g.ref, 'units', v_g.units, 'expected_units', v_expected));
        end if;
      else
        -- A sale: proceeds = units × close, rounded up. The difference from the cost is her realised gain.
        v_expected := ceil(-v_g.units * v_close * 100);
        if v_g.units >= 0 or v_g.savings_cents <> v_expected then
          v_problems := v_problems || public.recon_problem('posting',
            'A fund sale''s proceeds aren''t units × close, rounded up.',
            jsonb_build_object('request_id', v_g.ref, 'proceeds_cents', v_g.savings_cents, 'expected_cents', v_expected));
        elsif v_g.savings_at > v_close_at and not exists (
                select 1 from public.transactions x where x.posting_key = 'late_interest:trade:' || v_g.ref)
              and ceil(public.late_interest_exact(v_g.savings_cents, public.edmonton_local(v_close_at)::date,
                                                  public.edmonton_local(v_g.savings_at)::date - 1)) > 0 then
          v_problems := v_problems || public.recon_problem('posting',
            'A sale''s money reached savings late without the interest it missed.',
            jsonb_build_object('request_id', v_g.ref));
        end if;
        -- Realised gain counts once both sides have happened.
        if v_g.savings_at < v_end then
          v_realised := v_realised + v_g.net;
        end if;
      end if;
      continue;
    end if;

    if v_g.n <> 2 or v_g.moments <> 1 then
      v_problems := v_problems || public.recon_problem('posting', 'A move isn''t exactly two matching lines.',
        jsonb_build_object('transaction_ids', to_jsonb(v_g.ids)));
      continue;
    end if;

    -- GIC moves: the money comes out of one place and into the other, nothing lost.
    select * into v_gh from public.gic_holdings g where g.id = v_g.ref;
    if v_g.net <> 0 or v_gh.account_id <> p_account then
      v_problems := v_problems || public.recon_problem('posting', 'A GIC move doesn''t balance.',
        jsonb_build_object('gic_id', v_g.ref, 'transaction_ids', to_jsonb(v_g.ids)));
      continue;
    end if;
    select coalesce(sum(t.amount_cents), 0) into v_n from public.transactions t
     where t.gic_id = v_g.ref and t.vehicle = 'gic' and t.type = 'interest';
    if (v_g.kind = 'gic_buy' and (v_g.savings_cents <> -v_gh.principal_cents or v_gh.renewed_from_id is not null))
       or (v_g.kind = 'gic_break' and (v_gh.status <> 'broken' or v_g.savings_cents <> v_gh.principal_cents or v_n <> 0))
       or (v_g.kind = 'gic_release' and (v_gh.status <> 'matured' or v_g.savings_cents <> v_gh.principal_cents + v_n
                                         or v_g.at < public.edmonton_start(v_gh.maturity_date)
                                         or v_g.at > public.edmonton_start(v_gh.choice_ends)))
       or (v_g.kind = 'gic_renew' and (v_gh.status <> 'matured'
            or not exists (select 1 from public.gic_holdings n
                            where n.renewed_from_id = v_gh.id and n.principal_cents = v_gh.principal_cents + v_n
                              and exists (select 1 from public.transactions x
                                           where x.gic_id = n.id and x.id = any (v_g.ids) and x.amount_cents = n.principal_cents)))) then
      v_problems := v_problems || public.recon_problem('posting',
        'A GIC ' || replace(v_g.kind, 'gic_', '') || ' moved the wrong amount.',
        jsonb_build_object('gic_id', v_g.ref, 'transaction_ids', to_jsonb(v_g.ids)));
    end if;
  end loop;

  -- 3. Total worth = money in − money out + earnings ---------------------------
  -- Approved deposits − withdrawals + interest + dividends + corrections − penalties
  -- + realised gains (sale proceeds − cost) + unrealised gains (value − cost).
  -- A late trade whose savings side hasn't happened yet by the end of the day: its fund
  -- side has (units and cost in or out), so that cost is counted here until the money
  -- moves (+ what a buy paid, − the cost a sale took out).
  select coalesce(sum(t.amount_cents) filter (where t.type in ('deposit', 'withdraw', 'interest', 'dividend',
                                                                 'penalty', 'correction')), 0)
    into v_cat from public.transactions t
   where t.account_id = p_account and t.effective_at < v_end;
  select coalesce(sum(t.amount_cents), 0) into v_n from public.transactions t
   where t.account_id = p_account and t.vehicle = 'stock' and t.type in ('transfer_in', 'transfer_out')
     and t.posting_key like 'trade:%' and t.effective_at < v_end
     and exists (select 1 from public.transactions s where s.posting_key = split_part(t.posting_key, ':', 1) || ':'
                                                                        || split_part(t.posting_key, ':', 2) || ':savings'
                                                       and s.effective_at >= v_end);
  if v_cat + v_realised + (v_fund_value - v_fund_cost) + v_n <> v_savings + v_gic + v_fund_value then
    v_problems := v_problems || public.recon_problem('worth',
      'Total worth doesn''t equal money in − money out + earnings.',
      jsonb_build_object('by_vehicle_cents', v_savings + v_gic + v_fund_value,
                         'by_source_cents', v_cat + v_realised + (v_fund_value - v_fund_cost) + v_n));
  end if;

  -- 4. The app's figures match a fresh count -----------------------------------
  select * into v_db from public.daily_balances(p_account, p_date, p_date);
  if v_db.savings_cents <> v_savings or v_db.gic_cents <> v_gic or v_db.stock_cents <> v_fund_value
     or v_db.total_cents <> v_savings + v_gic + v_fund_value then
    v_problems := v_problems || public.recon_problem('app_figures', 'The graph figures don''t match the ledger.',
      jsonb_build_object('shown', to_jsonb(v_db), 'savings_cents', v_savings, 'gic_cents', v_gic,
                         'stock_cents', v_fund_value));
  end if;

  if v_is_today then
    select coalesce(sum(r.held_cents), 0) into v_held from public.requests r
     where r.account_id = p_account and r.status = 'pending';
    select * into v_view from public.account_balances ab where ab.account_id = p_account;
    if v_view.savings_cents <> v_savings or v_view.gic_cents <> v_gic or v_view.stock_value_cents <> v_fund_value
       or v_view.total_worth_cents <> v_savings + v_gic + v_fund_value
       or v_view.held_cents <> v_held or v_view.available_cents <> v_savings - v_held then
      v_problems := v_problems || public.recon_problem('app_figures', 'The balances shown don''t match the ledger.',
        jsonb_build_object('shown', to_jsonb(v_view), 'savings_cents', v_savings, 'gic_cents', v_gic,
                           'stock_cents', v_fund_value, 'held_cents', v_held));
    end if;

    for v_r in
      select fp.fund_id, fp.units, fp.value_cents,
             (select sum(t.units) from public.transactions t
               where t.account_id = p_account and t.fund_id = fp.fund_id and t.vehicle = 'stock') as ledger_units,
             (select round(sum(t.units) * (select p.close from public.fund_prices p
                                            where p.fund_id = fp.fund_id and p.price_date <= p_date
                                            order by p.price_date desc limit 1) * 100)
                from public.transactions t
               where t.account_id = p_account and t.fund_id = fp.fund_id and t.vehicle = 'stock') as ledger_value
        from public.fund_positions fp where fp.account_id = p_account
    loop
      if v_r.units <> v_r.ledger_units or v_r.value_cents <> coalesce(v_r.ledger_value, 0) then
        v_problems := v_problems || public.recon_problem('app_figures', 'A fund holding shown doesn''t match the ledger.',
          jsonb_build_object('fund', v_r.fund_id, 'shown_units', v_r.units, 'ledger_units', v_r.ledger_units,
                             'shown_cents', v_r.value_cents, 'ledger_cents', v_r.ledger_value));
      end if;
    end loop;

    for v_r in
      select gp.gic_id, gp.balance_cents,
             (select coalesce(sum(t.amount_cents), 0) from public.transactions t
               where t.gic_id = gp.gic_id and t.vehicle = 'gic') as ledger
        from public.gic_positions gp where gp.account_id = p_account
    loop
      if v_r.balance_cents <> v_r.ledger then
        v_problems := v_problems || public.recon_problem('app_figures', 'A GIC shown doesn''t match the ledger.',
          jsonb_build_object('gic_id', v_r.gic_id, 'shown_cents', v_r.balance_cents, 'ledger_cents', v_r.ledger));
      end if;
    end loop;

    -- Held money never exceeds what it's held against.
    if v_held > v_savings then
      v_problems := v_problems || public.recon_problem('held', 'More money is held than savings has.',
        jsonb_build_object('held_cents', v_held, 'savings_cents', v_savings));
    end if;
    for v_r in
      select r.fund_id, sum(r.held_units) as held,
             (select coalesce(sum(t.units), 0) from public.transactions t
               where t.account_id = p_account and t.fund_id = r.fund_id and t.vehicle = 'stock') as units
        from public.requests r
       where r.account_id = p_account and r.status = 'pending' and r.from_vehicle = 'stock'
       group by r.fund_id
    loop
      if v_r.held > v_r.units then
        v_problems := v_problems || public.recon_problem('held', 'More fund units are held for sales than she has.',
          jsonb_build_object('fund', v_r.fund_id, 'held_units', v_r.held, 'units', v_r.units));
      end if;
    end loop;
    for v_r in
      select r.id from public.requests r
       where r.account_id = p_account and r.status = 'pending'
         and r.held_cents <> case when r.type = 'withdraw' or r.to_vehicle = 'stock' then r.amount_cents else 0 end
    loop
      v_problems := v_problems || public.recon_problem('held', 'A pending request holds the wrong amount.',
        jsonb_build_object('request_id', v_r.id));
    end loop;
  end if;

  -- 5. Every GIC adds up --------------------------------------------------------
  for v_r in
    select g.*,
           (select coalesce(sum(t.amount_cents), 0) from public.transactions t
             where t.gic_id = g.id and t.vehicle = 'gic' and t.effective_at < v_end) as balance,
           (select coalesce(sum(t.amount_cents), 0) from public.transactions t
             where t.gic_id = g.id and t.vehicle = 'gic' and t.type = 'interest' and t.effective_at < v_end) as interest,
           exists (select 1 from public.transactions t
                    where t.gic_id = g.id and t.vehicle = 'gic' and t.type = 'transfer_in'
                      and t.amount_cents = g.principal_cents) as has_purchase
      from public.gic_holdings g
     where g.account_id = p_account and g.start_date <= p_date
  loop
    if not v_r.has_purchase then
      v_problems := v_problems || public.recon_problem('gic', 'A GIC has no purchase line for its principal.',
        jsonb_build_object('gic_id', v_r.id, 'principal_cents', v_r.principal_cents));
    elsif v_is_today and v_r.balance <> (case
            when v_r.status = 'active' then v_r.principal_cents
            when v_r.status = 'matured' and v_r.maturity_choice is null then v_r.principal_cents + v_r.interest
            else 0 end) then
      v_problems := v_problems || public.recon_problem('gic', 'A GIC''s balance doesn''t match its status.',
        jsonb_build_object('gic_id', v_r.id, 'status', v_r.status, 'balance_cents', v_r.balance));
    end if;
    if v_r.status = 'active' and v_r.maturity_date <= p_jobs_done and v_r.maturity_date <= p_date then
      v_problems := v_problems || public.recon_problem('missed', 'A GIC passed its maturity date without maturing.',
        jsonb_build_object('gic_id', v_r.id, 'maturity_date', v_r.maturity_date));
    end if;
  end loop;

  -- 6. Every day's interest accrual is there and right -------------------------
  -- A line reversed by a correction counts as never having happened, and so does
  -- the correction that reverses it: otherwise a mistake fixed today would leave
  -- every day between the mistake and the fix looking wrong forever.
  for v_r in
    with days as (
      select d::date as day
        from generate_series(v_opened, least(p_date - 1, p_interest_done), interval '1 day') d),
    ledger as (
      select t.* from public.transactions t
       where t.account_id = p_account and t.reverses_id is null
         and not exists (select 1 from public.transactions c where c.reverses_id = t.id)),
    expected as (
      select dd.day,
             (select coalesce(sum(t.amount_cents), 0) from ledger t
               where t.vehicle = 'savings'
                 and t.effective_at < public.edmonton_start(dd.day + 1))::bigint as savings,
             (select coalesce(sum(t.amount_cents), 0) from ledger t
                join public.gic_holdings g on g.id = t.gic_id
               where t.vehicle = 'gic' and g.status = 'matured'
                 and g.maturity_date <= dd.day
                 and t.effective_at < public.edmonton_start(dd.day + 1))::bigint as waiting,
             (select r.rate from public.rate_on('savings', null, dd.day) r) as rate,
             case when extract(doy from make_date(extract(year from dd.day)::int, 12, 31)) = 366
                  then 366 else 365 end as diy
        from days dd)
    select e.*, ia.balance_cents, ia.gic_waiting_cents, ia.rate as row_rate, ia.days_in_year, ia.accrued,
           ia.account_id is not null as has_row
      from expected e
      left join public.interest_accruals ia on ia.account_id = p_account and ia.accrual_date = e.day
     where (e.savings + e.waiting > 0) <> (ia.account_id is not null)
        or (ia.account_id is not null and (
              ia.balance_cents <> e.savings or ia.gic_waiting_cents <> e.waiting or ia.rate <> e.rate
              or ia.days_in_year <> e.diy
              or abs(ia.accrued - (e.savings + e.waiting) * e.rate / 100 / e.diy) > 0.000000001))
     order by e.day
     limit 5
  loop
    v_problems := v_problems || public.recon_problem('accrual',
      case when not v_r.has_row then 'A day''s savings interest is missing.'
           when v_r.savings + v_r.waiting = 0 then 'Interest was accrued on an empty balance.'
           else 'A day''s savings interest was worked out on the wrong balance or rate.' end,
      jsonb_build_object('date', v_r.day, 'expected_balance_cents', v_r.savings + v_r.waiting,
                         'row_balance_cents', coalesce(v_r.balance_cents, 0) + coalesce(v_r.gic_waiting_cents, 0),
                         'accrued', v_r.accrued));
  end loop;

  -- Each finished month with interest earned has its "Interest paid" line.
  for v_r in
    select date_trunc('month', ia.accrual_date)::date as month_from, ceil(sum(ia.accrued)) as due
      from public.interest_accruals ia
     where ia.account_id = p_account
       and (date_trunc('month', ia.accrual_date) + interval '1 month')::date <= least(p_date, p_jobs_done)
     group by 1
    having ceil(sum(ia.accrued)) > 0
  loop
    if not exists (select 1 from public.transactions t
                    where t.posting_key = 'interest:' || to_char(v_r.month_from, 'YYYY-MM') || ':' || p_account) then
      v_problems := v_problems || public.recon_problem('missed', 'A month''s savings interest was never paid.',
        jsonb_build_object('month', to_char(v_r.month_from, 'YYYY-MM'), 'due_cents', v_r.due));
    end if;
  end loop;

  -- 7. No posting key used twice (the table refuses it; this is a second look) --
  for v_r in
    select t.posting_key from public.transactions t
     where t.account_id = p_account and t.posting_key is not null
     group by t.posting_key having count(*) > 1
  loop
    v_problems := v_problems || public.recon_problem('duplicate', 'Something was posted twice.',
      jsonb_build_object('posting_key', v_r.posting_key));
  end loop;

  return v_problems;
end;
$$;

-- reconcile: "every daily job finished through" now means the jobs that don't wait for
-- prices (it's what the GIC and monthly-interest checks need).
create or replace function public.reconcile(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_jobs text[] := array['expire', 'gic_maturity', 'auto_move', 'monthly', 'rate_notices'];
  v_jobs_done date;
  v_interest_done date;
  v_acc record;
  v_found jsonb;
  v_code text;
  v_summary jsonb := '[]'::jsonb;
  v_alerts integer := 0;
  v_accounts integer := 0;
begin
  if p_date is null or p_date > v_today then
    raise exception 'Can''t check % because it hasn''t happened yet.', p_date;
  end if;

  -- The last date every daily job finished (each job's own latest "ok" date, the earliest of them).
  select min(d) into v_jobs_done from (
    select coalesce(max(jr.run_for_date) filter (where jr.status = 'ok'), date '-infinity') as d
      from unnest(v_jobs) j(name)
      left join public.job_runs jr on jr.job::text = j.name
     group by j.name) x;
  select coalesce(max(jr.run_for_date), date '-infinity') into v_interest_done
    from public.job_runs jr where jr.job = 'interest' and jr.status = 'ok';

  for v_acc in select a.id, a.is_test from public.accounts a order by a.id loop
    v_accounts := v_accounts + 1;
    v_found := public.reconcile_account(v_acc.id, p_date, v_jobs_done, v_interest_done);
    continue when jsonb_array_length(v_found) = 0;

    for v_code in select distinct p ->> 'code' from jsonb_array_elements(v_found) p loop
      v_summary := v_summary || jsonb_build_object(
        'account_id', v_acc.id, 'code', v_code,
        'count', (select count(*) from jsonb_array_elements(v_found) p where p ->> 'code' = v_code),
        'examples', (select jsonb_agg(p) from (select p from jsonb_array_elements(v_found) p
                                                where p ->> 'code' = v_code limit 3) e));
      -- One open alert per account and kind of problem; test accounts are logged quietly.
      if not exists (select 1 from public.alerts al
                      where al.kind = 'mismatch' and al.account_id = v_acc.id and al.resolved_at is null
                        and al.details ->> 'code' = v_code) then
        insert into public.alerts (kind, account_id, is_quiet, message, details)
        values ('mismatch', v_acc.id, v_acc.is_test, public.recon_alert_message(v_code),
                jsonb_build_object('code', v_code, 'date', p_date,
                                   'examples', (select jsonb_agg(p) from (select p from jsonb_array_elements(v_found) p
                                                                           where p ->> 'code' = v_code limit 3) e)));
        v_alerts := v_alerts + 1;
      end if;
    end loop;
  end loop;

  insert into public.job_runs (job, run_for_date, status, details, finished_at)
  values ('reconcile', p_date, (case when jsonb_array_length(v_summary) = 0 then 'ok' else 'failed' end)::public.job_status,
          jsonb_build_object('accounts', v_accounts, 'problems', v_summary, 'new_alerts', v_alerts,
                             'jobs_done_through', v_jobs_done, 'interest_done_through', v_interest_done),
          public.app_now());

  return jsonb_build_object('status', case when jsonb_array_length(v_summary) = 0 then 'ok' else 'problems' end,
                            'date', p_date, 'accounts', v_accounts, 'problems', v_summary, 'new_alerts', v_alerts);
end;
$$;

revoke all on function public.interest_done_through() from public, anon, authenticated, service_role;
revoke all on function public.savings_moment(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.late_interest_exact(bigint, date, date) from public, anon, authenticated, service_role;
revoke all on function public.post_late_interest(uuid, bigint, date, timestamptz, text, text) from public, anon, authenticated, service_role;
revoke all on function public.dividend_unit_days(uuid, text, date, date, date) from public, anon, authenticated, service_role;
revoke all on function public.ceil_div(numeric, numeric) from public, anon, authenticated, service_role;
revoke all on function public.dividend_quarter_start(text) from public, anon, authenticated, service_role;
