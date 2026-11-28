-- Block 1, item 3 (Dad, approved 2026-11-14 and 2026-11-27): the inflation switch made obvious.
-- Read-only figures only: nothing here posts, moves, rounds for posting or stores money.
--
-- 1. kid_inflation also gives her total worth and what it would buy next year if it didn't grow
--    ({real} on the Total card): total_worth_cents / (1 + inflation), rounded to the nearest cent,
--    like the savings line's "buys about what..." figure. Everything else is exactly as in
--    20261103000000_rate_help.sql.
-- 2. kid_rate_help also gives her savings in a year (year_total_cents: her balance plus
--    savings_year_cents, the same figure as the savings line) and the gap to prices
--    (gap_cents = need_cents - year_total_cents; above 0 means behind prices). For the Inflation ?:
--    "At 1.0%, your savings grow to about $75.95, about 67¢ behind prices." The browser never
--    does the subtraction (money rule 3).
-- parent_view already calls both, so "View as" gets the new figures with no change.
-- Known answers: supabase/tests/inflation_total_test.sql.

create or replace function public.kid_inflation(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_infl numeric := coalesce(public.setting_on('inflation_rate', public.app_today())::numeric, 0);
  v_rate numeric := coalesce(public.wish_savings_rate(public.app_today()), 0);
  v_now bigint;
  v_year numeric;
  v_total bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  if not public.feature_enabled('inflation', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  select coalesce(b.savings_cents, 0), coalesce(b.total_worth_cents, 0) into v_now, v_total
    from public.account_balances b where b.account_id = p_account_id;
  v_total := coalesce(v_total, 0);
  -- Like the real interest: monthly, each month rounded up (savings_year_cents), so it agrees
  -- with the Interest rate ? beside her savings (2026-10-26).
  v_year := coalesce(v_now, 0) + coalesce(public.savings_year_cents(coalesce(v_now, 0), v_rate), 0);

  return jsonb_build_object(
    'on', true,
    'inflation_rate', public.setting_on('inflation_rate', v_today),
    -- The Total card (block 1, item 3): her total, and what it buys next year if it doesn't grow.
    'total', jsonb_build_object('now_cents', v_total,
                                'buys_like_cents', round(v_total / (1 + v_infl / 100))::bigint),
    'savings', jsonb_build_object('now_cents', coalesce(v_now, 0), 'savings_rate', v_rate,
                                  'in_a_year_cents', v_year::bigint,
                                  'buys_like_cents', round(v_year / (1 + v_infl / 100))::bigint),
    'gics', coalesce((
      select jsonb_agg(jsonb_build_object(
               'gic_id', g.id, 'principal_cents', g.principal_cents, 'rate', g.rate, 'term_months', g.term_months,
               'maturity_date', g.maturity_date, 'days', g.maturity_date - v_today,
               'at_maturity_cents', g.principal_cents + public.gic_interest_cents(g.principal_cents, g.rate, g.term_months),
               'buys_like_cents', round((g.principal_cents + public.gic_interest_cents(g.principal_cents, g.rate, g.term_months))
                                        / power(1 + v_infl / 100, greatest(g.maturity_date - v_today, 0) / 365.0))::bigint)
               order by g.maturity_date, g.id)
        from public.gic_holdings g
       where g.account_id = p_account_id and g.status = 'active'), '[]'::jsonb),
    'funds', coalesce((
      select jsonb_agg(jsonb_build_object('fund', x.id, 'name', x.name,
               'year_change_pct', case when x.then_c is null then null else round((x.now_c / x.then_c - 1) * 100, 2) end)
               order by x.sort_order)
        from (select f.id, f.name, f.sort_order, l.close as now_c,
                     (select fp.close * coalesce((select exp(sum(ln(s.ratio_from::numeric / s.ratio_to))) from public.fund_splits s
                                                   where s.fund_id = f.id and s.split_date > fp.price_date
                                                     and s.split_date <= l.price_date), 1)
                        from public.fund_prices fp
                       where fp.fund_id = f.id and fp.price_date <= (l.price_date - interval '1 year')::date
                       order by fp.price_date desc limit 1) as then_c
                from public.funds f
                cross join lateral (select fp.price_date, fp.close from public.fund_prices fp
                                     where fp.fund_id = f.id and fp.source = 'daily' and fp.price_date <= v_today
                                       and fp.fetched_at >= public.close_time(f.market, fp.price_date)
                                     order by fp.price_date desc limit 1) l
               where public.fund_units(p_account_id, f.id) > 0) x), '[]'::jsonb));
end;
$$;

-- 3. View as ----------------------------------------------------------------------------------------


comment on function public.kid_inflation(uuid) is
  'The inflation view on Home: her savings, GICs, funds and total, and what each would buy later. Worked out here, never in the browser. Read-only.';

create or replace function public.kid_rate_help(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_now record;                -- the rate in force today (a special included): what Home shows
  v_special_end date;
  v_rate numeric;              -- the regular rate: what both year projections use
  v_infl numeric := coalesce(public.setting_on('inflation_rate', public.app_today())::numeric, 0);
  v_bal bigint;
  v_need bigint;
  v_year_total bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  select * into v_now from public.rate_on('savings', null, v_today);
  select r.end_date into v_special_end from public.rates r where r.id = v_now.rate_id and r.is_special;
  v_rate := coalesce(public.wish_savings_rate(v_today), v_now.rate, 0);

  select coalesce(b.savings_cents, 0) into v_bal from public.account_balances b where b.account_id = p_account_id;
  v_bal := coalesce(v_bal, 0);
  if v_bal > 0 then
    v_need := ceil(v_bal * (1 + v_infl / 100))::bigint;
    -- The same "in a year" figure as kid_inflation's savings line (savings_year_cents).
    v_year_total := v_bal + public.savings_year_cents(v_bal, v_rate);
  end if;
  return jsonb_build_object(
    'today', v_today,
    'savings_rate', v_rate,
    'now_rate', coalesce(v_now.rate, v_rate),
    'special_until', v_special_end,
    'per_100_cents', ceil(v_rate * 100)::bigint,
    'per_100_exact', v_rate * 100 = ceil(v_rate * 100),
    'balance_cents', v_bal,
    'year_cents', case when v_bal > 0 and v_rate > 0 then public.savings_year_cents(v_bal, v_rate) end,
    'inflation_rate', v_infl,
    'infl_100_cents', 10000 + ceil(v_infl * 100)::bigint,
    'infl_exact', v_infl * 100 = ceil(v_infl * 100),
    'need_cents', v_need,
    -- Block 1, item 3: her savings in a year, and how far that is behind prices (below 0: ahead).
    'year_total_cents', v_year_total,
    'gap_cents', v_need - v_year_total);
end;
$$;
comment on function public.kid_rate_help(uuid) is
  'The live figures for the Interest rate and Inflation ?s beside her savings (2026-10-26). Year figures use the regular rate; a running savings special comes with its last day (2026-10-27); her savings in a year and the gap to prices (block 1, item 3). Read-only.';

-- create or replace keeps each function's grants; restated so this file says who may call them.
revoke all on function public.kid_inflation(uuid) from public, anon, authenticated, service_role;
grant execute on function public.kid_inflation(uuid) to authenticated;
revoke all on function public.kid_rate_help(uuid) from public, anon, authenticated, service_role;
grant execute on function public.kid_rate_help(uuid) to authenticated;
