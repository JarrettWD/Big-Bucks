-- Stage 3: nightly reconciliation, "Updating…", and the health check.
--
-- reconcile(date) re-checks every account from the raw ledger as of the end of
-- that date: every line must be explained by its rule and carry the right
-- amount, nothing may be negative, the app's figures must match a fresh count,
-- every GIC must add up, every day's interest accrual must be there and right,
-- and total worth must equal money in − money out + earnings. Problems become
-- alerts (quiet for test accounts), and while the latest check of an account
-- found a problem, figures_updating(account) is true so the app shows
-- "Updating…" instead of a number that might be wrong.
--
-- Dad's decision at the stage 3 plan: "Updating…" clears by itself once a later
-- check finds the account clean, but the alert stays open on the dashboard until
-- Dad acknowledges it (acknowledge_alert).
--
-- health_check() lists open problems for the daily GitHub check (stage 4).

-- One problem, as reconcile records it.
create function public.recon_problem(p_code text, p_message text, p_details jsonb default '{}'::jsonb)
returns jsonb
language sql immutable
set search_path = ''
as $$
  select jsonb_build_object('code', p_code, 'message', p_message, 'details', coalesce(p_details, '{}'::jsonb));
$$;

-- Every check for one account as of the end of p_date. Returns a list of problems
-- (empty when all is well). p_jobs_done / p_interest_done: the last dates the
-- daily jobs and the interest accruals have completed, so a job that simply
-- hasn't run yet (a missing close, a missed night) isn't reported as missing.
create function public.reconcile_account(p_account uuid, p_date date, p_jobs_done date, p_interest_done date)
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
  select (a.created_at at time zone 'America/Edmonton')::date into v_opened from public.accounts a where a.id = p_account;

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
      v_day := (v_r.effective_at at time zone 'America/Edmonton')::date;
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
      v_day := (v_r.effective_at at time zone 'America/Edmonton')::date;
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
      v_day := (v_r.effective_at at time zone 'America/Edmonton')::date;
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

-- What Dad sees on the dashboard for each kind of problem.
create function public.recon_alert_message(p_code text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_code
    when 'negative'    then 'A balance went below zero.'
    when 'fund_cost'   then 'A fund''s cost doesn''t add up.'
    when 'posting'     then 'A ledger line doesn''t match the rule that should have made it.'
    when 'worth'       then 'Total worth doesn''t equal money in, minus money out, plus earnings.'
    when 'app_figures' then 'A figure the app shows doesn''t match the ledger.'
    when 'held'        then 'Money or units held by a pending request don''t add up.'
    when 'gic'         then 'A GIC doesn''t add up.'
    when 'accrual'     then 'A day''s savings interest is missing or wrong.'
    when 'missed'      then 'Something that should have been posted wasn''t.'
    when 'duplicate'   then 'Something was posted twice.'
    else 'The nightly check found a problem.' end
    || ' Her figures show "Updating…" until a later check finds them right.';
$$;

-- The nightly check, for every account, as of the end of p_date.
create function public.reconcile(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_jobs text[] := array['expire', 'splits', 'settle', 'gic_maturity', 'auto_move', 'dividends', 'monthly',
                         'rate_notices'];
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

-- True while the latest nightly check found a problem with this account, so the
-- app shows "Updating…" instead of her figures. A kid may ask only about herself.
create function public.figures_updating(p_account_id uuid)
returns boolean
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_details jsonb;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  select jr.details into v_details from public.job_runs jr
   where jr.job = 'reconcile' order by jr.id desc limit 1;
  return coalesce((select bool_or(p ->> 'account_id' = p_account_id::text)
                     from jsonb_array_elements(v_details -> 'problems') p), false);
end;
$$;

-- Dad marks an alert as dealt with (parent with MFA only).
create function public.acknowledge_alert(p_alert_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  update public.alerts set resolved_at = public.app_now(), resolved_by = auth.uid()
   where id = p_alert_id and resolved_at is null;
  if not found then
    raise exception 'There''s no open alert %.', p_alert_id;
  end if;
end;
$$;

-- For the daily GitHub check (stage 4): every open problem, or none. Quiet alerts
-- (test accounts) don't count. Also reports daily jobs or the nightly check
-- falling behind: by the morning, last night's run should have finished
-- yesterday's jobs and the day before's interest.
create function public.health_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_problems jsonb := '[]'::jsonb;
  v_r record;
  v_last date;
begin
  for v_r in
    select al.id, al.kind, al.account_id, al.message, al.created_at from public.alerts al
     where al.resolved_at is null and not al.is_quiet order by al.id
  loop
    v_problems := v_problems || jsonb_build_object('kind', 'alert', 'alert_id', v_r.id, 'alert_kind', v_r.kind,
                                                   'account_id', v_r.account_id, 'message', v_r.message,
                                                   'since', v_r.created_at);
  end loop;

  if exists (select 1 from public.accounts) then
    for v_r in
      select j.name, j.due, max(jr.run_for_date) filter (where jr.status = 'ok') as last_ok
        from (values ('expire', 1), ('splits', 1), ('settle', 1), ('gic_maturity', 1), ('auto_move', 1),
                     ('dividends', 1), ('monthly', 1), ('rate_notices', 1), ('interest', 2), ('reconcile', 1)) j(name, due)
        left join public.job_runs jr on jr.job::text = j.name
       group by j.name, j.due
    loop
      -- reconcile counts when it ran at all: the problems it finds are alerts above.
      if v_r.name = 'reconcile' then
        select max(jr.run_for_date) into v_last from public.job_runs jr where jr.job = 'reconcile';
      else
        v_last := v_r.last_ok;
      end if;
      if v_last is null or v_last < v_today - v_r.due then
        v_problems := v_problems || jsonb_build_object('kind', 'behind', 'job', v_r.name, 'done_through', v_last,
          'message', 'The ' || v_r.name || ' job has only finished through '
                     || coalesce(to_char(v_last, 'Mon DD, YYYY'), 'never') || '.');
      end if;
    end loop;
  end if;

  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'checked_at', public.app_now(),
                            'problems', v_problems);
end;
$$;

-- Who may run them. Internal helpers (recon_problem, reconcile_account,
-- recon_alert_message) get no grant: only reconcile, as the owner, calls them.
revoke all on function public.recon_problem(text, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_account(uuid, date, date, date) from public, anon, authenticated, service_role;
revoke all on function public.recon_alert_message(text) from public, anon, authenticated, service_role;
revoke all on function public.reconcile(date) from public, anon, authenticated, service_role;
revoke all on function public.figures_updating(uuid) from public, anon, authenticated, service_role;
revoke all on function public.acknowledge_alert(bigint) from public, anon, authenticated, service_role;
revoke all on function public.health_check() from public, anon, authenticated, service_role;

grant execute on function public.reconcile(date) to service_role;
grant execute on function public.health_check() to service_role;
grant execute on function public.figures_updating(uuid) to authenticated, service_role;
grant execute on function public.acknowledge_alert(bigint) to authenticated;
