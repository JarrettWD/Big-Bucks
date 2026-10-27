-- The live figures in the "Interest rate" and "Inflation" ?s, and plainer special wording
-- (Dad, 2026-10-26, from the Oct 26 rate-change check). Read-only figures and notice wording:
-- nothing here posts, moves or stores money.
--
-- 1. kid_rate_help: what the ?s beside her savings show, worked out here (never in the browser):
--      "At 1.0% a year, every $100 earns $1 in a year." (the plain meaning of the percent), and
--      "Your $95.00 would earn about 96¢ in a year." (her own figure, worked out like the real
--      interest: monthly, each month rounded up to the cent in her favour: savings_year_cents).
--    The rate is the one Home shows beside "Earning x% a year" (specials included).
--    Inflation the same way: "At 2.0% a year, something that costs $100 now costs $102 next year."
--    and "Your $95.00 in savings would need to grow to $96.90 to buy the same things."
-- 2. kid_inflation's "in a year" figure uses savings_year_cents too, so the inflation line and the
--    Interest rate ? never disagree by a cent (it used to round once, at the end of the year).
-- 3. parent_view reads kid_rate_help for "View as".
-- 4. The two glossary entries lose their fixed examples ("At 2% a year ...", "If things cost 2%
--    more ..."), which looked wrong beside a live 1.0%; the live lines replace them. Each is
--    reworded only if it still has its original words.
-- 5. Specials say "Last day: {date}" (not "It ends after {date}"), and GICs bought during one keep
--    its rate "until they mature": send_rate_notices (from 20261014000000_settings_screen.sql) and
--    add_rate_unlogged (from 20261031000000_rate_notice_wording.sql), only those words changed.
--    Notices already sent keep their words.
-- Known answers: supabase/tests/rate_help_test.sql.

-- 1. A year of savings interest, like the real thing -----------------------------------------------

-- Her balance at a fixed rate for 12 months, interest added monthly and each month rounded up to the
-- cent (the real interest accrues daily and is paid on the 1st, rounded up). Returns the interest.
create function public.savings_year_cents(p_balance bigint, p_rate numeric)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  b bigint := p_balance;
begin
  if p_balance is null or p_balance <= 0 or p_rate is null or p_rate <= 0 then
    return 0;
  end if;
  for i in 1..12 loop
    b := b + ceil(b * p_rate / 1200)::bigint;
  end loop;
  return b - p_balance;
end;
$$;
comment on function public.savings_year_cents(bigint, numeric) is
  'A year of savings interest on a balance at a fixed rate: monthly, each month rounded up to the cent. A guide for the ?s, never posted.';

create function public.kid_rate_help(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_rate numeric := coalesce((public.rate_on('savings', null, public.app_today())).rate, 0);
  v_infl numeric := coalesce(public.setting_on('inflation_rate', public.app_today())::numeric, 0);
  v_bal bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  select coalesce(b.savings_cents, 0) into v_bal from public.account_balances b where b.account_id = p_account_id;
  v_bal := coalesce(v_bal, 0);
  return jsonb_build_object(
    'savings_rate', v_rate,
    'per_100_cents', ceil(v_rate * 100)::bigint,
    'per_100_exact', v_rate * 100 = ceil(v_rate * 100),
    'balance_cents', v_bal,
    'year_cents', case when v_bal > 0 and v_rate > 0 then public.savings_year_cents(v_bal, v_rate) end,
    'inflation_rate', v_infl,
    'infl_100_cents', 10000 + ceil(v_infl * 100)::bigint,
    'infl_exact', v_infl * 100 = ceil(v_infl * 100),
    'need_cents', case when v_bal > 0 then ceil(v_bal * (1 + v_infl / 100))::bigint end);
end;
$$;
comment on function public.kid_rate_help(uuid) is
  'The live figures for the Interest rate and Inflation ?s beside her savings (2026-10-26). Read-only.';

-- 2. The inflation view, with the same year of interest ----------------------------------------------

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
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  if not public.feature_enabled('inflation', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  select coalesce(b.savings_cents, 0) into v_now from public.account_balances b where b.account_id = p_account_id;
  -- Like the real interest: monthly, each month rounded up (savings_year_cents), so it agrees
  -- with the Interest rate ? beside her savings (2026-10-26).
  v_year := coalesce(v_now, 0) + coalesce(public.savings_year_cents(coalesce(v_now, 0), v_rate), 0);

  return jsonb_build_object(
    'on', true,
    'inflation_rate', public.setting_on('inflation_rate', v_today),
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

create or replace function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  r jsonb;
begin
  perform public.require_parent();
  if p_account is null or not exists (select 1 from public.accounts x where x.id = p_account) then
    raise exception 'There''s no account to view.';
  end if;

  case p_read
    when 'account' then
      select jsonb_build_object('account_id', x.id, 'name', x.name, 'is_test', x.is_test)
        into r from public.accounts x where x.id = p_account;
    when 'app_today' then
      r := to_jsonb(public.app_today());
    -- Her Home: the same rows her app reads from these views and her notices.
    when 'balances' then
      select to_jsonb(b) into r from public.account_balances b where b.account_id = p_account;
    when 'home_gics' then
      select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]'::jsonb) into r
        from public.gic_positions g
       where g.account_id = p_account
         and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null));
    when 'unread_notices' then
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                                                   'related_gic_id', n.related_gic_id)
                                order by n.created_at desc, n.id desc), '[]'::jsonb) into r
        from public.notifications n where n.account_id = p_account and n.read_at is null;
    when 'unread_count' then
      r := to_jsonb((select count(*) from public.notifications n where n.account_id = p_account and n.read_at is null));
    when 'figures_updating' then
      r := to_jsonb(public.figures_updating(p_account));
    when 'feature_enabled' then
      r := to_jsonb(public.feature_enabled(a ->> 'p_feature', p_account));
    when 'current_rates' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.current_rates() with ordinality t;
    when 'fund_overview' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.fund_overview(p_account) with ordinality t;
    when 'my_activity' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_activity(p_account, coalesce((a ->> 'p_limit')::integer, 20),
                                (a ->> 'p_before_at')::timestamptz, a ->> 'p_before_key') with ordinality t;
    when 'my_notices' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_notices(p_account, coalesce((a ->> 'p_limit')::integer, 50),
                               (a ->> 'p_before_id')::bigint) with ordinality t;
    when 'my_questions' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_questions(p_account) with ordinality t;
    -- B4: her onboarding and her signed agreements.
    when 'onboarding_state' then
      r := public.onboarding_state(p_account);
    when 'my_agreements' then
      r := public.my_agreements(p_account);
    -- Stage 9: her goal card on Home (never the "Got it" marker).
    when 'kid_goal' then
      r := public.kid_goal(p_account);
    -- Stage 10: her look and her badges.
    when 'kid_look' then
      r := public.kid_look(p_account);
    when 'kid_badges' then
      r := public.kid_badges(p_account);
    -- Stage 11: the learning features, read exactly as she reads them.
    when 'kid_features' then
      r := public.kid_features(p_account);
    when 'kid_view_mode' then
      r := to_jsonb(public.kid_view_mode(p_account));
    when 'kid_statement_months' then
      r := public.kid_statement_months(p_account);
    when 'kid_statement' then
      r := public.kid_statement(p_account, (a ->> 'p_month')::date);
    when 'kid_what_if' then
      r := public.kid_what_if(p_account);
    when 'kid_market_compare' then
      r := public.kid_market_compare(p_account, a ->> 'p_range');
    when 'kid_inflation' then
      r := public.kid_inflation(p_account);
    -- 2026-10-26: the live figures in the Interest rate and Inflation ?s.
    when 'kid_rate_help' then
      r := public.kid_rate_help(p_account);
    when 'kid_reflections' then
      r := public.kid_reflections(p_account);
    -- Her Graphs.
    when 'graph_ranges' then
      r := public.graph_ranges(p_account);
    when 'daily_balances' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.daily_balances(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'growth_by_option' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.growth_by_option(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'money_in_vs_earned' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.money_in_vs_earned(p_account) with ordinality t;
    when 'my_mix' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_mix(p_account) with ordinality t;
    when 'gic_ladder' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.gic_ladder(p_account) with ordinality t;
    when 'fund_chart' then
      r := public.fund_chart(p_account, a ->> 'p_fund_id', (a ->> 'p_from')::date);
    else
      raise exception 'There''s no "%" to view.', p_read;
  end case;
  return r;
end;
$$;

-- 5. Specials: "Last day" ---------------------------------------------------------------------------

create or replace function public.send_rate_notices(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rate public.rates;
  v_s public.settings;
  v_what text;
  v_back numeric;
  v_account uuid;
  v_count integer := 0;
begin
  -- Going live today (skip a change saved today: its first notice already said "today").
  for v_rate in
    select * from public.rates r
     where r.effective_date = p_date and public.edmonton_local(r.created_at)::date < p_date
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id
  loop
    v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live',
        case when v_rate.is_special then 'The ' || v_what || ' special at ' || public.fmt_rate(v_rate.rate) || ' starts today'
             else 'The new ' || v_what || ' rate is now ' || public.fmt_rate(v_rate.rate) end,
        case when v_rate.is_special then 'Last day: ' || public.fmt_date(v_rate.end_date) || '.'
             else 'It applies from today.' end,
        'rate_live:' || v_rate.id || ':' || v_account, p_rate_id => v_rate.id);
      v_count := v_count + 1;
    end loop;
  end loop;

  -- Specials that ended yesterday.
  for v_rate in
    select * from public.rates r
     where r.is_special and r.end_date = p_date - 1
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id
  loop
    v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
    v_back := (public.rate_on(v_rate.vehicle, v_rate.gic_term, p_date)).rate;
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live', 'The ' || v_what || ' special has ended',
        case when v_rate.vehicle = 'savings'
             then 'Savings is back to ' || public.fmt_rate(v_back) || '.'
             else public.term_label(v_rate.gic_term) || ' GICs are back to ' || public.fmt_rate(v_back)
                  || '. GICs bought during the special keep ' || public.fmt_rate(v_rate.rate) || ' until they mature.' end,
        'rate_end:' || v_rate.id || ':' || v_account, p_rate_id => v_rate.id);
      v_count := v_count + 1;
    end loop;
  end loop;

  -- A dividend yield change announced before today, starting today (the one in force).
  for v_s in
    select * from public.settings s
     where s.key like 'dividend_yield:%' and s.effective_date = p_date
       and not exists (select 1 from public.cancellations c where c.setting_id = s.id)
       and s.id = (select s2.id from public.settings s2
                    where s2.key = s.key and s2.effective_date = s.effective_date
                      and not exists (select 1 from public.cancellations c2 where c2.setting_id = s2.id)
                    order by s2.id desc limit 1)
       and exists (select 1 from public.notifications n
                    where n.dedupe_key like 'yield_change:' || s.id || ':%'
                      and public.edmonton_local(n.created_at)::date < p_date)
     order by s.id
  loop
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'rate_live',
        'The ' || public.fund_label(substr(v_s.key, length('dividend_yield:') + 1)) || ' fund''s new dividend rate is now '
          || public.fmt_rate(v_s.value::numeric),
        'It applies from today.',
        'yield_live:' || v_s.id || ':' || v_account);
      v_count := v_count + 1;
    end loop;
  end loop;
  return jsonb_build_object('status', 'ok', 'notices', v_count);
end;
$$;

create or replace function public.add_rate_unlogged(p_vehicle public.vehicle, p_gic_term integer, p_rate numeric,
                                                    p_effective_date date default null, p_note text default null,
                                                    p_end_date date default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_effective date := coalesce(p_effective_date, public.app_today() + 7);
  v_note text := public.as_sentence(p_note);
  v_special boolean := p_end_date is not null;
  v_old numeric;
  v_after numeric;
  v_in_force numeric;
  v_special_end date;
  v_label text;
  v_title text;
  v_body text;
  v_id bigint;
  v_account uuid;
begin
  perform public.require_parent();

  if p_vehicle is null or p_vehicle not in ('savings', 'gic') then
    raise exception 'Rates are only for savings and GICs.';
  end if;
  if p_vehicle = 'savings' and p_gic_term is not null then
    raise exception 'The savings rate has no term.';
  end if;
  if p_vehicle = 'gic' and (p_gic_term is null or p_gic_term not in (1, 3, 6, 9, 12, 24)) then
    raise exception 'GIC terms are 1, 3, 6, 9, 12 or 24 months.';
  end if;
  if p_rate is null or p_rate < 0 or p_rate >= 100 then
    raise exception 'A rate must be between 0%% and 99.999%%.';
  end if;
  if p_rate <> round(p_rate, 3) then
    raise exception 'Use at most 3 decimal places (for example 2.125).';
  end if;
  if v_effective < v_today then
    raise exception 'A rate change can''t start in the past: it would change interest already earned.';
  end if;
  if v_special and p_end_date < v_effective then
    raise exception 'A special can''t end before it starts.';
  end if;

  v_old := (public.rate_on(p_vehicle, p_gic_term, v_effective - 1)).rate;

  insert into public.rates (vehicle, gic_term, rate, effective_date, end_date, is_special, note, created_by)
  values (p_vehicle, p_gic_term, p_rate, v_effective, p_end_date, v_special, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  v_label := case when p_vehicle = 'savings' then 'Savings rate' else public.term_label(p_gic_term) || ' GIC rate' end;
  -- What the girls actually get on the first day: a running special can hide a regular change.
  v_in_force := (public.rate_on(p_vehicle, p_gic_term, v_effective)).rate;
  if not v_special and v_in_force is distinct from p_rate then
    select r.end_date into v_special_end from public.rates r
     where r.is_special and r.vehicle = p_vehicle and r.gic_term is not distinct from p_gic_term
       and r.effective_date <= v_effective and r.end_date >= v_effective
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id desc limit 1;
  end if;

  if v_special then
    v_after := (public.rate_on(p_vehicle, p_gic_term, p_end_date + 1)).rate;
    v_title := 'Special: '
      || case when p_vehicle = 'savings' then 'savings' else public.term_label(p_gic_term) || ' GICs' end
      || ' at ' || public.fmt_rate(p_rate) || ' from ' || public.fmt_date(v_effective) || ' to ' || public.fmt_date(p_end_date);
    v_body := concat_ws(' ', v_note,
      'Last day: ' || public.fmt_date(p_end_date) || '. Then the rate goes back to ' || public.fmt_rate(v_after) || '.',
      case when p_vehicle = 'gic' then 'A GIC bought during the special keeps ' || public.fmt_rate(p_rate) || ' until it matures.' end);
  elsif v_special_end is not null then
    -- Hidden behind a running special: nothing changes for her until it ends.
    v_title := v_label || ' after the special: ' || public.fmt_rate(p_rate);
    v_body := concat_ws(' ', v_note,
      'The special at ' || public.fmt_rate(v_in_force) || ' keeps going. Last day: ' || public.fmt_date(v_special_end)
        || '. After that, the rate will be ' || public.fmt_rate(p_rate) || '.',
      case when p_vehicle = 'gic' then 'GICs you already have keep their locked-in rate.' end);
  else
    v_title := v_label || ' '
      || case when v_old is null or p_rate = v_old then 'is ' || public.fmt_rate(p_rate)
              when p_rate < v_old then 'drops from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(p_rate)
              else 'goes up from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(p_rate) end
      || case when v_effective = v_today then ' today' else ' on ' || public.fmt_date(v_effective) end;
    v_body := concat_ws(' ', v_note,
      case
        -- A savings change never changes GIC rates (Dad, 2026-10-19): a true, neutral line, never
        -- a tip to buy a GIC first (it misled on Oct 19, when a 1-month special began the same day).
        when p_vehicle = 'savings' then
          'This doesn''t change GIC rates. A GIC keeps the rate it was bought at until it matures.'
        -- A GIC cut later: buying that term before then keeps today's rate, but only when today's
        -- rate for that term really holds every day until then (no special or other change between).
        when v_effective > v_today and v_old is not null and p_rate < v_old
             and (select count(distinct (public.rate_on('gic', p_gic_term, d::date)).rate)
                    from generate_series(v_today, v_effective - 1, interval '1 day') d) = 1 then
          'Tip: a ' || public.term_label(p_gic_term) || ' GIC bought before ' || public.fmt_date(v_effective)
            || ' keeps today''s ' || public.fmt_rate((public.rate_on('gic', p_gic_term, v_today)).rate) || '.'
        -- A GIC increase (Dad, 2026-10-19): her GICs keep their rate, and a new one gets the new
        -- rate, but only said when nothing contradicts it: that term really pays the new rate on
        -- its first day (no special then), and no other change for that term is planned after it.
        when v_old is not null and p_rate > v_old
             and (public.rate_on('gic', p_gic_term, v_effective)).rate = p_rate
             and not exists (select 1 from public.rates r
                              where r.vehicle = 'gic' and r.gic_term = p_gic_term and r.id <> v_id
                                and case when r.is_special then r.end_date >= v_effective   -- a special then or later
                                         else r.effective_date > v_effective end           -- a later change
                                and not exists (select 1 from public.cancellations c where c.rate_id = r.id)) then
          'GICs you already have keep their locked-in rate. A ' || public.term_label(p_gic_term) || ' GIC bought '
            || case when v_effective = v_today then 'from today' else 'from ' || public.fmt_date(v_effective) end
            || ' gets ' || public.fmt_rate(p_rate) || '.'
        else 'GICs you already have keep their locked-in rate.'
      end);
  end if;

  for v_account in select a.id from public.accounts a loop
    perform public.notify(v_account, 'rate_change', v_title, v_body,
      'rate_change:' || v_id || ':' || v_account, p_rate_id => v_id);
  end loop;
  return v_id;
end;
$$;

-- 4. The glossary ------------------------------------------------------------------------------------

update public.glossary
   set kid_text = 'How much interest you earn in a year, shown as a percent.'
 where term = 'Interest rate'
   and kid_text = 'How much interest you earn in a year, shown as a percent. At 2% a year, $100 earns $2 in a year.';

update public.glossary
   set kid_text = 'Prices slowly going up over time. Your money needs to grow at least as fast as prices just to buy the same stuff.'
 where term = 'Inflation'
   and kid_text = 'Prices slowly going up over time. If things cost 2% more next year, your money needs to grow at least 2% just to buy the same stuff.';

-- Grants: the helper is internal; the read is for signed-in users (it checks whose account).
revoke all on function public.savings_year_cents(bigint, numeric) from public, anon, authenticated, service_role;
revoke all on function public.kid_rate_help(uuid) from public, anon, authenticated, service_role;
grant execute on function public.kid_rate_help(uuid) to authenticated;
