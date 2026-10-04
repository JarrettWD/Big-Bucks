-- The Graphs tab (stage 7 part 2c): graph_ranges, growth_by_option, money_in_vs_earned,
-- my_mix, gic_ladder and fund_chart. Known answers worked out by hand below.
begin;
select plan(41);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create function tests.nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true);
$$;
create function tests.acct(p_username text) returns uuid language sql as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.new_kid(p_username text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  return v_acct;
end;
$$;
-- The message a statement fails with (null if it succeeds).
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception
  when others then return sqlstate || ' ' || sqlerrm;
end;
$$;
create function tests.deposit(p_username text, p_cents bigint) returns void language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
end;
$$;
create function tests.settle(p_day text) returns void language plpgsql as $$
begin
  perform tests.nobody();
  perform tests.clock(p_day || ' 16:30');
  perform public.settle_trades(p_day::date);
end;
$$;
-- One option's line from growth_by_option, as "day pct earned" text, for compact known answers.
create function tests.line(p_user text, p_option text, p_from date, p_to date) returns text language sql as $$
  select string_agg(to_char(g.day, 'MM-DD') || ' ' || g.growth_pct || ' ' || g.earned_cents, ', ' order by g.day)
    from public.growth_by_option(tests.acct(p_user), p_from, p_to) g where g.option = p_option;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Prices on every weekday, Sep 28 to Nov 6. Flat, except:
--   Dow: 400 to Oct 5, 440 on Oct 6 and 7 (+10%), 396 on Oct 8 to 12 (−10%), 400 from Oct 13.
--   Nasdaq-100: 500, then 501 from Nov 5.
insert into public.fund_prices (fund_id, price_date, close)
select f.fund_id, d::date,
       case f.fund_id
         when 'dow' then case when d < '2026-10-06' then 400 when d < '2026-10-08' then 440
                              when d < '2026-10-13' then 396 else 400 end
         when 'nasdaq100' then case when d < '2026-11-05' then 500 else 501 end
         else 40 end
  from (values ('dow'), ('nasdaq100'), ('tsx')) f(fund_id)
 cross join generate_series(date '2026-09-28', date '2026-11-06', interval '1 day') d
 where extract(isodow from d) < 6;

-- Kid A's story --------------------------------------------------------------------------------------
--   Oct 1   $1,000 deposit; a $100 1-month GIC at 2.5%.
--   Oct 5   buys $250 of the Dow at 400 (0.625 units).                Dow worth $250.00
--   Oct 6   the Dow rises 10%.                                        $275.00  (+$25.00)
--   Oct 7   buys $220 more at 440 (0.5 units). Not growth.            $495.00
--   Oct 8   the Dow falls 10%.                                        $445.50  (−$49.50)
--   Oct 9   a $4.95 Dow dividend lands in savings: growth for the Dow, not for savings.
--   Oct 13  sells all 1.125 units at 400: $450.00 (+$4.50 on the day).
--   Nov 1   the GIC matures: +$0.21 interest. Savings interest of $0.89 posts.
--   Nov 2   the GIC's $100.21 moves to savings.
--   Nov 4   a $50 withdrawal (asked for on Nov 3).
--   Nov 5   a $50 deposit.
--
-- The Dow's time-weighted growth: 1.10 × 1 × 0.90 × (1 + 495/44550) × (1 + 450/44550)
--   = 0.99 × 1.0111… × 1.0101… = 1.011111… → +1.11%, while $25.00 − $49.50 + $4.95 + $4.50 = −$15.05
--   was earned in dollars (the second buy was bigger and caught the drop).
select tests.clock('2026-10-01 08:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b');
select tests.deposit('kid_a', 100000);
select tests.clock('2026-10-01 09:00');
select tests.as_kid('kid_a');
select public.buy_gic(10000, 1);

select tests.clock('2026-10-05 09:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'buy', 25000, false);
select tests.settle('2026-10-05');

select tests.clock('2026-10-07 09:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'buy', 22000, false);
select tests.settle('2026-10-07');

-- The market-move notes for Oct 6 (+10%) and Oct 8 (−10%).
select tests.clock('2026-10-08 16:30');
select public.write_market_move_notes('2026-10-06');
select public.write_market_move_notes('2026-10-08');

insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_a'), 'savings', 'dow', 'dividend', 495, 'test:dividend', public.edmonton_start('2026-10-09'),
        'Test dividend.');

select tests.clock('2026-10-13 09:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'sell', null, true);
select tests.settle('2026-10-13');

select tests.clock('2026-11-01 16:30');
select public.mature_gics('2026-11-01');
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_a'), 'savings', 'interest', 89, 'test:interest', public.edmonton_start('2026-11-01'),
        'Test interest.');

-- 1. The GIC ladder shows a matured GIC as ready -----------------------------------------------------

select tests.as_kid('kid_a');
select results_eq(
  $$select principal_cents, start_date, maturity_date, interest_cents, at_maturity_cents, ready
      from public.gic_ladder(tests.acct('kid_a'))$$,
  $$values (10000::bigint, date '2026-10-01', date '2026-11-01', 21::bigint, 10021::bigint, true)$$,
  'a matured GIC waiting for her choice is on the ladder, marked ready');

select tests.clock('2026-11-02 09:00');
select public.choose_maturity((select id from public.gic_holdings where account_id = tests.acct('kid_a')), 'to_savings');
select is((select count(*)::int from public.gic_ladder(tests.acct('kid_a'))), 0,
  'once moved to savings, it leaves the ladder');

select tests.clock('2026-11-03 09:00');
select public.request_withdrawal(5000);
select tests.clock('2026-11-04 10:00');
select tests.as_parent();
select public.approve_request((select id from public.requests where account_id = tests.acct('kid_a') and type = 'withdraw'));
select tests.clock('2026-11-05 09:00');
select tests.deposit('kid_a', 5000);

-- Kid B: $400 in on Nov 2; a 2-year and a 9-month GIC of $100 each, and $100 of the Nasdaq-100 at 500.
select tests.clock('2026-11-02 08:00');
select tests.deposit('kid_b', 40000);
select tests.clock('2026-11-02 09:00');
select tests.as_kid('kid_b');
select public.buy_gic(10000, 24);
select public.buy_gic(10000, 9);
select public.request_trade('nasdaq100', 'buy', 10000, false);
select tests.settle('2026-11-02');

-- Today: Friday Nov 6, 2026, at noon.
select tests.clock('2026-11-06 12:00');
select tests.as_kid('kid_a');

-- 2. graph_ranges ------------------------------------------------------------------------------------

select is(public.graph_ranges(tests.acct('kid_a')) - 'first_purchase',
  jsonb_build_object(
    'today', '2026-11-06', 'first_day', '2026-10-01',
    'worth', jsonb_build_object('1M', '2026-10-06', '3M', '2026-10-01', '1Y', '2026-10-01', 'All', '2026-10-01'),
    'fund', jsonb_build_object('1M', '2026-10-06', '3M', '2026-08-06', '6M', '2026-05-06'),
    'ladder_until', '2028-11-06'),
  'ranges: 1 month back, and never before her first day (3M, 1Y and All start on Oct 1); a fund''s go further back');
select is(public.graph_ranges(tests.acct('kid_a')) -> 'first_purchase', '{"dow": "2026-10-05"}'::jsonb,
  'her first Dow purchase was Oct 5');

-- 3. growth_by_option: time-weighted ----------------------------------------------------------------

select is(tests.line('kid_a', 'dow', '2026-10-01', '2026-11-06'),
  (select string_agg(x, ', ' order by x) from (
     select '10-05 0.00 0' as x union all select '10-06 10.00 2500' union all select '10-07 10.00 2500'
     union all select '10-08 -1.00 -2450' union all select '10-09 0.10 -1955' union all select '10-10 0.10 -1955'
     union all select '10-11 0.10 -1955' union all select '10-12 0.10 -1955'
     union all select to_char(d, 'MM-DD') || ' 1.11 -1505'
       from generate_series(date '2026-10-13', date '2026-11-06', interval '1 day') d) y),
  'the Dow: +10%, a buy that isn''t growth, −10% (−1.00% overall), the dividend (+0.10%), then the sale day''s rise (+1.11%), flat after selling');
select is((select string_agg(distinct g.growth_pct::text || ' ' || g.earned_cents, ',')
             from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-10-31') g
            where g.option = 'savings'),
  '0.00 0', 'a deposit isn''t growth: in October, with a deposit, a GIC, two buys, a dividend and a sale, savings grew 0%');
select results_eq(
  $$select g.day, g.growth_pct, g.earned_cents from public.growth_by_option(tests.acct('kid_a'), '2026-10-30', '2026-11-06') g
     where g.option = 'savings' order by g.day$$,
  $$values (date '2026-10-30', 0.00, 0::bigint), ('2026-10-31', 0.00, 0), ('2026-11-01', 0.10, 89), ('2026-11-02', 0.10, 89),
           ('2026-11-03', 0.10, 89), ('2026-11-04', 0.10, 89), ('2026-11-05', 0.10, 89), ('2026-11-06', 0.10, 89)$$,
  'savings: $0.89 of interest on $884.95 is +0.10%; the GIC money coming in, the withdrawal and the deposit don''t change it');
select results_eq(
  $$select g.day, g.growth_pct, g.earned_cents, g.flow_cents from public.growth_by_option(tests.acct('kid_a'), '2026-10-30', '2026-11-03') g
     where g.option = 'gic' order by g.day$$,
  $$values (date '2026-10-30', 0.00, 0::bigint, 0::bigint), ('2026-10-31', 0.00, 0, 0), ('2026-11-01', 0.21, 21, 0),
           ('2026-11-02', 0.21, 21, -10021), ('2026-11-03', 0.21, 21, 0)$$,
  'GICs step up when they mature (+$0.21, 0.21%), and moving the money to savings is a flow, not a loss');
select is((select count(*)::int from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-10-01') g
            where g.option = 'gic'), 1, 'a GIC bought on the range''s first day starts the GIC line');
select is(tests.line('kid_a', 'dow', '2026-10-07', '2026-10-09'), '10-07 0.00 0, 10-08 -10.00 -4950, 10-09 -9.00 -4455',
  'a range starts at 0%: from Oct 7, the drop is −10%, and the dividend lifts it to −9.00% (0.90 × 1.0111…)');
select results_eq(
  $$select g.day, g.flow_cents from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-10-13') g
     where g.option = 'dow' and g.flow_cents <> 0 order by g.day$$,
  $$values (date '2026-10-05', 25000::bigint), ('2026-10-07', 22000), ('2026-10-13', -45000)$$,
  'money into and out of the Dow (for the dots): both buys and the sale');
select results_eq(
  $$select g.day, g.flow_cents from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-11-06') g
     where g.option = 'savings' and g.flow_cents <> 0 order by g.day$$,
  $$values (date '2026-10-05', -25000::bigint), ('2026-10-07', -22000), ('2026-10-09', 495), ('2026-10-13', 45000),
           ('2026-11-02', 10021), ('2026-11-04', -5000), ('2026-11-05', 5000)$$,
  'money into and out of savings: buys, the dividend, the sale, the GIC, the withdrawal and the deposit');
select is((select count(*)::int from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-11-06') g
            where g.option in ('nasdaq100', 'tsx')), 0, 'no line for a fund she never had');
select is((select count(*)::int from public.growth_by_option(tests.acct('kid_a'), '2026-10-20', '2026-11-06') g
            where g.option = 'dow'), 0, 'nor for one she''d sold before the range began');
select tests.as_kid('kid_b');
select is((select string_agg(distinct g.option, ',' order by g.option)
             from public.growth_by_option(tests.acct('kid_b'), '2026-11-02', '2026-11-06') g),
  'gic,nasdaq100,savings', 'kid B has a line for each of her options');
select is(tests.line('kid_b', 'nasdaq100', '2026-11-02', '2026-11-06'),
  '11-02 0.00 0, 11-03 0.00 0, 11-04 0.00 0, 11-05 0.20 20, 11-06 0.20 20',
  'kid B''s Nasdaq-100: 500 → 501 is +0.20%, $0.20');
select tests.as_kid('kid_a');
select throws_ok($$select * from public.growth_by_option(tests.acct('kid_a'), '2026-11-06', '2026-10-01')$$,
  'P0001', 'Choose a date range of up to about 10 years.', 'a backwards range is refused');

-- 4. money_in_vs_earned ----------------------------------------------------------------------------

select results_eq(
  $$select m.day, m.net_deposits_cents, m.total_cents, m.earned_cents from public.money_in_vs_earned(tests.acct('kid_a')) m
     where m.day in ('2026-10-01', '2026-10-08', '2026-11-04', '2026-11-06') order by m.day$$,
  $$values (date '2026-10-01', 100000::bigint, 100000::bigint, 0::bigint),
           ('2026-10-08', 100000, 97550, -2450),
           ('2026-11-04', 95000, 93605, -1395),
           ('2026-11-06', 100000, 98605, -1395)$$,
  'money in vs earned: the gap is what her money earned (−$15.05 from the Dow, +$0.21 and +$0.89 of interest = −$13.95 by Nov 6)');
select is((select min(m.day) from public.money_in_vs_earned(tests.acct('kid_a')) m), date '2026-10-01',
  'it starts on her first day');
select is((select m.total_cents from public.money_in_vs_earned(tests.acct('kid_a')) m order by m.day desc limit 1),
  (select b.total_worth_cents from public.account_balances b where b.account_id = tests.acct('kid_a')),
  'its last point is her total worth today, the same as Home');
select is((select m.earned_cents from public.money_in_vs_earned(tests.acct('kid_a')) m order by m.day desc limit 1),
  (select sum(g.earned_cents)::bigint from public.growth_by_option(tests.acct('kid_a'), '2026-10-01', '2026-11-06') g
    where g.day = '2026-11-06'),
  'and what she earned matches the growth graph''s dollars added up (−$15.05 + $0.21 + $0.89)');

-- 5. my_mix ------------------------------------------------------------------------------------------

select tests.as_kid('kid_b');
select results_eq(
  $$select option, name, value_cents, mix_pct from public.my_mix(tests.acct('kid_b'))$$,
  $$values ('savings'::text, 'Savings'::text, 10000::bigint, 25), ('gic', 'GICs', 20000, 50),
           ('nasdaq100', 'Nasdaq-100', 10020, 25)$$,
  'kid B''s mix: 24.99%, 49.98% and 25.04% become 25, 50 and 25 (largest remainder), only what she holds');
select is((select sum(mix_pct)::int from public.my_mix(tests.acct('kid_b'))), 100, 'it adds up to exactly 100');
select tests.as_kid('kid_a');
select results_eq($$select option, mix_pct from public.my_mix(tests.acct('kid_a'))$$,
  $$values ('savings'::text, 100)$$, 'kid A has everything in savings: 100%');

-- 6. gic_ladder ---------------------------------------------------------------------------------------

select tests.as_kid('kid_b');
select results_eq(
  $$select term_months, rate, start_date, maturity_date, interest_cents, at_maturity_cents, ready
      from public.gic_ladder(tests.acct('kid_b'))$$,
  $$values (9::smallint, 4.500::numeric, date '2026-11-02', date '2027-08-02', 338::bigint, 10338::bigint, false),
           (24::smallint, 6.000, '2026-11-02', '2028-11-02', 1200, 11200, false)$$,
  'kid B''s ladder, soonest first: $100 for 9 months at 4.5% ($3.38), and 2 years at 6% ($12.00)');

-- 7. fund_chart -------------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'trades',
  '[{"d": "2026-10-05", "side": "buy", "price": 400, "units": 0.625, "amount_cents": 25000},
    {"d": "2026-10-07", "side": "buy", "price": 440, "units": 0.5, "amount_cents": 22000},
    {"d": "2026-10-13", "side": "sell", "price": 400, "units": 1.125, "amount_cents": 45000}]'::jsonb,
  'her buys and sells, each with its day, price, units and money');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'closes' -> 0,
  '{"d": "2026-10-05", "c": 400, "pct": 0.00}'::jsonb, 'the closes start at the range''s first close, 0%');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'closes' -> 1,
  '{"d": "2026-10-06", "c": 440, "pct": 10.00}'::jsonb, 'and each has its change since then');
select is(jsonb_array_length(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'closes'), 25,
  'every close from Oct 5 to Nov 6 (25 weekdays)');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'change_pct', '0.00'::jsonb,
  'the Dow itself ended where it started (400)');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') -> 'notes',
  jsonb_build_array(
    jsonb_build_object('d', '2026-10-06', 'body', public.setting_on('market_move_note_up', '2026-10-06')),
    jsonb_build_object('d', '2026-10-08', 'body', public.setting_on('market_move_note_down', '2026-10-08'))),
  'the market-move notes: the jump on Oct 6 and the drop on Oct 8');
select is(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-05') - array['closes', 'trades', 'notes'],
  '{"fund_id": "dow", "from": "2026-10-05", "today": "2026-11-06", "change_pct": 0.00,
    "range_growth_pct": 1.11, "range_earned_cents": -1505, "holding": null}'::jsonb,
  'her growth in the range is the growth graph''s (+1.11%, −$15.05); she holds none now');
select is(jsonb_array_length(public.fund_chart(tests.acct('kid_a'), 'dow', '2026-10-20') -> 'trades'), 0,
  'a range after her trades has none');
select tests.as_kid('kid_b');
select is(public.fund_chart(tests.acct('kid_b'), 'nasdaq100', '2026-11-02') -> 'holding',
  '{"units": 0.2, "value_cents": 10020, "cost_cents": 10000, "gain_cents": 20, "return_pct": 0.20}'::jsonb,
  'what she holds now, against what she paid (Home''s "since first purchase" figure)');
select is(public.fund_chart(tests.acct('kid_b'), 'tsx', '2026-10-06') ->> 'range_growth_pct', null,
  'a fund she doesn''t own still has its price line, but no growth of hers');
select throws_ok($$select public.fund_chart(tests.acct('kid_b'), 'gold', '2026-10-06')$$, 'P0001',
  'There''s no fund called gold.', 'an unknown fund is refused');

-- 8. The glossary ------------------------------------------------------------------------------------

select is((select count(*)::int from public.glossary where term in ('Growth', 'Money earned')), 2,
  'the two words the Graphs tab explains are in the glossary');

-- 9. Who may call them -------------------------------------------------------------------------------

select tests.as_kid('kid_b');
select is(
  (select count(*)::int from unnest(array[
     $$select public.graph_ranges(%L)$$,
     $$select * from public.growth_by_option(%L, '2026-10-01', '2026-11-06')$$,
     $$select * from public.money_in_vs_earned(%L)$$,
     $$select * from public.my_mix(%L)$$,
     $$select * from public.gic_ladder(%L)$$,
     $$select public.fund_chart(%L, 'dow', '2026-10-01')$$]) q
    where tests.err(format(q, tests.acct('kid_a'))) = '42501 You can only see your own account.'),
  6, 'kid B can''t read kid A''s graphs (all six functions refuse)');
select tests.as_parent('aal1');
select throws_ok(format($$select * from public.growth_by_option(%L, '2026-10-01', '2026-11-06')$$, tests.acct('kid_a')),
  '42501', 'You can only see your own account.', 'a parent without the authenticator code can''t');
select tests.as_parent('aal2');
select is((select count(*)::int from public.my_mix(tests.acct('kid_a'))), 1, 'a parent with the code can');
select ok(
  not has_function_privilege('anon', 'public.graph_ranges(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.growth_by_option(uuid, date, date)', 'execute')
  and not has_function_privilege('anon', 'public.money_in_vs_earned(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.my_mix(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.gic_ladder(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.fund_chart(uuid, text, date)', 'execute'),
  'signed-out visitors can call none of them');

select * from finish();
rollback;
