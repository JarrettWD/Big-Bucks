-- Alberta's time rule, pinned in the database.
--
-- Alberta's Official Time Act (passed June 18, 2026) keeps the province on
-- UTC−6 all year from November 1, 2026: the clocks went forward on March 8, 2026
-- and never go back again. IANA time-zone data 2026c has the new rule, but a
-- Postgres server only knows what its own copy of that data says, and the local
-- Postgres (17.11) still turns Alberta to UTC−7 on Nov 1, 2026. Production's may
-- lag the same way.
--
-- So the app no longer asks the server about Alberta. Two small functions hold
-- the rule:
--   edmonton_local(moment)    → the Alberta clock time at that moment
--   edmonton_at(clock time)   → the moment that Alberta clock time happens
-- From 2026-03-08 09:00 UTC (3:00 am Alberta time, when the clocks went forward
-- for the last time) Alberta is UTC−6, worked out with plain arithmetic and no
-- time-zone data. Earlier moments use the server's America/Edmonton history,
-- which every server agrees on.
--
-- Every function that turned a moment into an Alberta date or time is recreated
-- below, copied unchanged from its latest version except that it now goes
-- through these two functions. A test fails if any other function names
-- America/Edmonton.
--
-- Market closes stay in Toronto time (4:00 pm, or the early-close time in
-- market_holidays) and use the server's America/Toronto data, whose rules have
-- not changed since 2007. In Alberta a close is 2:00 pm from the second Sunday
-- in March to the first Sunday in November, and 3:00 pm the rest of the year.
-- check_time_rules() confirms all of this on any server, production included.
--
-- If Alberta's rule ever changes again: a new migration that replaces
-- edmonton_local and edmonton_at, plus a time machine run.

create function public.edmonton_local(p timestamptz)
returns timestamp
language sql immutable
set search_path = ''
as $$
  select case
           when p >= timestamptz '2026-03-08 09:00:00+00'
             then (p at time zone 'UTC') - interval '6 hours'
           else p at time zone 'America/Edmonton'
         end;
$$;

comment on function public.edmonton_local(timestamptz) is
  'The Alberta clock time at a moment. Pinned rule: UTC−6 from 2026-03-08 09:00 UTC on.';

create function public.edmonton_at(p timestamp)
returns timestamptz
language sql immutable
set search_path = ''
as $$
  select case
           when p >= timestamp '2026-03-08 03:00:00'
             then (p + interval '6 hours') at time zone 'UTC'
           else p at time zone 'America/Edmonton'
         end;
$$;

comment on function public.edmonton_at(timestamp) is
  'The moment an Alberta clock time happens. Pinned rule: UTC−6 from 2026-03-08 03:00 Alberta time on.';

-- Views and app_today() run as the caller, so the app's roles may run these.
-- They only do arithmetic.
revoke all on function public.edmonton_local(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.edmonton_at(timestamp) from public, anon, authenticated, service_role;
grant execute on function public.edmonton_local(timestamptz) to authenticated, service_role;
grant execute on function public.edmonton_at(timestamp) to authenticated, service_role;

-- The functions that use Alberta dates and times ------------------------------------
-- create or replace keeps each function's grants and comments.

-- app_now: from 20261002000000_settings_and_clock.sql (1 change)
create or replace function public.app_now()
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_local_dev text;
  v_override  text;
begin
  select s.value into v_local_dev
    from public.settings s
   where s.key = 'is_local_dev'
   order by s.id desc
   limit 1;

  if v_local_dev is distinct from 'true' then
    return now();
  end if;

  select btrim(s.value) into v_override
    from public.settings s
   where s.key = 'clock_override'
   order by s.id desc
   limit 1;

  if v_override is null or v_override = '' then
    return now();
  end if;

  if v_override !~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' then
    raise exception 'clock_override "%" is not a valid Edmonton date and time. Use YYYY-MM-DD HH:MI, or an empty value to clear it.',
      v_override;
  end if;

  return public.edmonton_at(v_override::timestamp);
end;
$$;

-- app_today: from 20261002000000_settings_and_clock.sql (1 change)
create or replace function public.app_today()
returns date
language sql
stable
set search_path = ''
as $$
  select public.edmonton_local(public.app_now())::date;
$$;

-- edmonton_start: from 20261002080000_engine_core.sql (1 change)
create or replace function public.edmonton_start(p_date date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select public.edmonton_at(p_date::timestamp);
$$;

-- fmt_moment: from 20261002080000_engine_core.sql (1 change)
create or replace function public.fmt_moment(p timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select to_char(public.edmonton_local(p), 'Mon FMDD "at" FMHH12:MI am');
$$;

-- request_trade: from 20261002090000_kid_actions.sql (1 change)
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
    if p_amount_cents > v_units * v_close * 100 then
      raise exception 'Your % units are worth about %, so you can sell up to that (or choose "sell all").',
        v_fund.name, public.fmt_money(floor(v_units * v_close * 100));
    end if;
    -- Hold the units the amount needs at the latest close. If the price falls by
    -- the close, settlement sells what she has (see settle_trades).
    v_hold := least(v_units, public.round_up_units(p_amount_cents / 100.0 / v_close));
  end if;

  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all, held_units)
  values (v_account, 'move', 'stock', 'savings', p_fund_id, p_amount_cents, coalesce(p_sell_all, false), v_hold)
  returning id into v_id;
  return v_id;
end;
$$;

-- send_rate_notices: from 20261002110000_daily_jobs.sql (1 change)
create or replace function public.send_rate_notices(p_date date)
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
     where r.effective_date = p_date and public.edmonton_local(r.created_at)::date < p_date
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

-- run_daily: from 20261002110000_daily_jobs.sql (1 change)
create or replace function public.run_daily(p_through date)
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
                      (select min(public.edmonton_local(a.created_at)::date) from public.accounts a),
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

-- fund_return: from 20261002120000_reads.sql (1 change)
create or replace function public.fund_return(p_account_id uuid, p_fund_id text, p_from date)
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
    select public.edmonton_local(t.effective_at)::date as day, -sum(t.amount_cents) as amount
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

-- reconcile_account: from 20261003000000_reconcile.sql (4 changes)
create or replace function public.reconcile_account(p_account uuid, p_date date, p_jobs_done date, p_interest_done date)
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
  v_rows record;
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
      v_day := public.edmonton_local(v_r.effective_at)::date;
      v_qstart := date_trunc('quarter', v_day)::date;
      select f.market into v_market from public.funds f where f.id = v_r.fund_id;
      v_last := public.last_trading_day_before(v_market, v_qstart);
      v_close_at := public.close_time(v_market, v_last);
      select fp.close into v_close from public.fund_prices fp where fp.fund_id = v_r.fund_id and fp.price_date = v_last;
      select coalesce(sum(t.units), 0) into v_units from public.transactions t
       where t.account_id = p_account and t.fund_id = v_r.fund_id and t.vehicle = 'stock' and t.effective_at <= v_close_at;
      v_yield := public.setting_on('dividend_yield:' || v_r.fund_id, v_day)::numeric;
      v_expected := ceil(v_units * v_close * v_yield / 4);
      if v_day <> public.first_trading_day_from(v_market, v_qstart)
         or v_r.effective_at <> public.edmonton_start(v_day)
         or v_r.posting_key is distinct from
            'dividend:' || to_char(v_day, 'YYYY') || 'Q' || extract(quarter from v_day) || ':' || v_r.fund_id || ':' || p_account
         or v_expected is null or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A dividend line isn''t units × close × yield ÷ 4, rounded up, on the quarter''s first trading day.',
          jsonb_build_object('transaction_id', v_r.id, 'fund', v_r.fund_id, 'amount_cents', v_r.amount_cents,
                             'expected_cents', v_expected));
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
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'savings'), 0)::bigint as savings_cents,
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'stock'), 0)::bigint as stock_cents,
           sum(t.units) filter (where t.vehicle = 'stock') as units,
           max(t.unit_price) as unit_price,
           array_agg(t.id order by t.id) as ids
      from public.transactions t
     where t.account_id = p_account and t.effective_at < v_end
       and t.type in ('transfer_in', 'transfer_out')
       and split_part(t.posting_key, ':', 1) in ('gic_buy', 'gic_break', 'gic_release', 'gic_renew', 'trade')
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
     group by 1, 2
  loop
    if v_g.n <> 2 or v_g.moments <> 1 then
      v_problems := v_problems || public.recon_problem('posting', 'A move isn''t exactly two matching lines.',
        jsonb_build_object('transaction_ids', to_jsonb(v_g.ids)));
      continue;
    end if;

    if v_g.kind = 'trade' then
      select * into v_req from public.requests r where r.id = v_g.ref;
      select f.market into v_market from public.funds f where f.id = v_req.fund_id;
      v_close_at := public.next_close(v_market, v_req.created_at);
      select fp.close into v_close from public.fund_prices fp
       where fp.fund_id = v_req.fund_id and fp.price_date = (v_close_at at time zone 'America/Toronto')::date;
      if v_req.account_id <> p_account or v_req.status <> 'settled' or v_g.at <> v_close_at
         or v_close is null or v_g.unit_price <> v_close then
        v_problems := v_problems || public.recon_problem('posting',
          'A trade didn''t settle at its own close.',
          jsonb_build_object('request_id', v_g.ref, 'settled_at', v_g.at, 'expected_at', v_close_at));
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
        end if;
        v_realised := v_realised + v_g.net;
      end if;
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
                                         or v_g.at > public.edmonton_start(v_gh.maturity_date + 7)))
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
  select coalesce(sum(t.amount_cents) filter (where t.type in ('deposit', 'withdraw', 'interest', 'dividend',
                                                                 'penalty', 'correction')), 0)
    into v_cat from public.transactions t
   where t.account_id = p_account and t.effective_at < v_end;
  if v_cat + v_realised + (v_fund_value - v_fund_cost) <> v_savings + v_gic + v_fund_value then
    v_problems := v_problems || public.recon_problem('worth',
      'Total worth doesn''t equal money in − money out + earnings.',
      jsonb_build_object('by_vehicle_cents', v_savings + v_gic + v_fund_value,
                         'by_source_cents', v_cat + v_realised + (v_fund_value - v_fund_cost)));
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

-- my_activity: from 20261005000000_kid_home.sql (1 change)
create or replace function public.my_activity(p_account_id uuid, p_limit integer default 20,
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
  select l.item_key, l.at, public.edmonton_local(l.at)::date, l.kind, l.request_type, l.amount_cents,
         l.fund_id, l.gic_id, l.gic_term, l.rate, l.units, l.unit_price, l.note, l.transaction_ids, l.request_id
    from lines l
   where p_before_at is null or (l.at, l.item_key) < (p_before_at, coalesce(p_before_key, ''))
   order by l.at desc, l.item_key desc
   limit least(greatest(coalesce(p_limit, 20), 1), 200);
end;
$$;

comment on function public.app_today() is
  'Today''s date in Alberta, from app_now() and the pinned rule in edmonton_local().';

-- The glossary --------------------------------------------------------------------------

update public.glossary
   set kid_text = $$The end of the stock market's day, at 4:00 pm in Toronto. In Alberta that's 2:00 pm from March to early November, and 3:00 pm the rest of the year. The price at that moment is called the close.$$
 where term = 'Market close';

-- The check Dad runs on production (stage 4) ---------------------------------------
--
-- In the Supabase Dashboard: SQL Editor → select * from public.check_time_rules();
-- Every row with ok = true or ok = null (information only) means the server
-- agrees. Any ok = false row means stop and look before going further.

create function public.check_time_rules()
returns table (check_name text, expected text, actual text, ok boolean)
language plpgsql stable
set search_path = ''
as $$
declare
  v_fmt constant text := 'YYYY-MM-DD HH24:MI';
  v_server_offset text;
begin
  -- 1. The pinned Alberta rule: noon UTC−6 on both sides of Nov 1, 2026.
  return query
    select x.n, x.e, to_char(public.edmonton_local(x.m), v_fmt), to_char(public.edmonton_local(x.m), v_fmt) = x.e
      from (values
        ('Alberta, 18:00 UTC on Sat Oct 31, 2026', timestamptz '2026-10-31 18:00:00+00', '2026-10-31 12:00'),
        ('Alberta, 18:00 UTC on Mon Nov 2, 2026 (no clock change)', timestamptz '2026-11-02 18:00:00+00', '2026-11-02 12:00'),
        ('Alberta, 18:00 UTC on Fri Jan 15, 2027', timestamptz '2027-01-15 18:00:00+00', '2027-01-15 12:00'),
        ('Alberta, 05:30 UTC on Jan 1, 2027 is still Dec 31', timestamptz '2027-01-01 05:30:00+00', '2026-12-31 23:30'),
        ('Alberta, 18:00 UTC on Thu Jul 1, 2027', timestamptz '2027-07-01 18:00:00+00', '2027-07-01 12:00')
      ) as x(n, m, e);

  return query
    select 'Alberta midnight starting Dec 1, 2026, in UTC'::text, '2026-12-01 06:00'::text,
           to_char(public.edmonton_start(date '2026-12-01') at time zone 'UTC', v_fmt),
           to_char(public.edmonton_start(date '2026-12-01') at time zone 'UTC', v_fmt) = '2026-12-01 06:00';

  -- 2. The server's Toronto data: 4:00 pm Toronto in UTC either side of each clock change.
  return query
    select x.n, x.e, to_char((x.l at time zone 'America/Toronto') at time zone 'UTC', v_fmt),
           to_char((x.l at time zone 'America/Toronto') at time zone 'UTC', v_fmt) = x.e
      from (values
        ('Toronto 4:00 pm Fri Oct 30, 2026 in UTC (summer time)', timestamp '2026-10-30 16:00', '2026-10-30 20:00'),
        ('Toronto 4:00 pm Mon Nov 2, 2026 in UTC (standard time)', timestamp '2026-11-02 16:00', '2026-11-02 21:00'),
        ('Toronto 4:00 pm Fri Mar 12, 2027 in UTC (standard time)', timestamp '2027-03-12 16:00', '2027-03-12 21:00'),
        ('Toronto 4:00 pm Mon Mar 15, 2027 in UTC (summer time)', timestamp '2027-03-15 16:00', '2027-03-15 20:00'),
        ('Toronto 4:00 pm Fri Nov 5, 2027 in UTC (summer time)', timestamp '2027-11-05 16:00', '2027-11-05 20:00'),
        ('Toronto 4:00 pm Mon Nov 8, 2027 in UTC (standard time)', timestamp '2027-11-08 16:00', '2027-11-08 21:00')
      ) as x(n, l, e);

  -- 3. Market closes in Alberta time, from close_time().
  return query
    select x.n, x.e, to_char(public.edmonton_local(public.close_time(x.mk::public.market, x.d)), v_fmt),
           to_char(public.edmonton_local(public.close_time(x.mk::public.market, x.d)), v_fmt) = x.e
      from (values
        ('NYSE close Fri Oct 30, 2026, Alberta time', 'nyse', date '2026-10-30', '2026-10-30 14:00'),
        ('NYSE close Mon Nov 2, 2026, Alberta time', 'nyse', date '2026-11-02', '2026-11-02 15:00'),
        ('NYSE early close Fri Nov 27, 2026, Alberta time', 'nyse', date '2026-11-27', '2026-11-27 12:00'),
        ('TSX early close Thu Dec 24, 2026, Alberta time', 'tsx', date '2026-12-24', '2026-12-24 12:00'),
        ('TSX close Fri Mar 12, 2027, Alberta time', 'tsx', date '2027-03-12', '2027-03-12 15:00'),
        ('TSX close Mon Mar 15, 2027, Alberta time', 'tsx', date '2027-03-15', '2027-03-15 14:00')
      ) as x(n, mk, d, e);

  -- 4. The app clock follows the real clock (no time-machine override).
  return query
    select 'app_now() is the real time (no clock override)'::text, 'yes'::text,
           case when public.app_now() = now() then 'yes' else 'no: ' || public.app_now()::text end,
           public.app_now() = now();
  return query
    select 'app_today() is the Alberta date right now'::text, public.edmonton_local(now())::date::text,
           public.app_today()::text, public.app_today() = public.edmonton_local(now())::date;

  -- 5. Information only: does the server's own time-zone data know the new rule?
  --    The app doesn't rely on it, so either answer is fine.
  v_server_offset := to_char((timestamptz '2026-12-01 18:00:00+00' at time zone 'America/Edmonton'), 'HH24:MI');
  return query
    select 'Information only: server''s own Alberta data, 18:00 UTC on Dec 1, 2026'::text, '12:00'::text,
           v_server_offset || case when v_server_offset = '12:00' then ' (up to date)'
                                   else ' (old data; harmless, the app uses its pinned rule)' end,
           null::boolean;
end;
$$;

revoke all on function public.check_time_rules() from public, anon, authenticated, service_role;
