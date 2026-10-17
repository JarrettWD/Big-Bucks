-- Stage 11: the learning features (plan approved by Dad 2026-10-17). Known answers for the
-- what-if (each case: savings, 1-year GICs with a special and a renewal, the Nasdaq-100 with
-- a split and a dividend, and withdrawals), Compare the markets, the inflation view, the
-- reflection (a separate call: the sell never depends on it), view modes, the six switches,
-- What's new for accounts made after a feature is on (Dad's addition 5), RLS, and that no
-- money function knows about any of it.
begin;
select plan(66);

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.fetched_after_close() returns trigger language plpgsql as $t$
begin
  new.fetched_at := greatest(new.fetched_at,
    public.close_time((select f.market from public.funds f where f.id = new.fund_id), new.price_date)
      + interval '30 minutes');
  return new;
end;
$t$;
create trigger tests_fetched_after_close before insert on public.fund_prices
  for each row execute function tests.fetched_after_close();

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
create function tests.acct(p_username text) returns uuid language sql security definer as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.new_kid(p_username text, p_is_test boolean default true) returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, p_is_test) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb), (v_acct, 1, 'parent', v_user, null);
  return v_acct;
end;
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ran' using errcode = 'BB999';
exception
  when sqlstate 'BB999' then return null;
  when others then return sqlerrm;
end;
$$;
create function tests.closes(p_fund text, p_from date, p_to date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close)
  select p_fund, d::date, p_close
    from generate_series(p_from, p_to, interval '1 day') d
   where public.is_trading_day((select f.market from public.funds f where f.id = p_fund), d::date);
$$;
-- Money straight into the ledger at an Alberta moment (the what-if reads only the ledger).
create function tests.money(p_username text, p_cents bigint, p_at text) returns void language sql as $$
  insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
  values (tests.acct(p_username), 'savings', case when p_cents > 0 then 'deposit' else 'withdraw' end::public.transaction_type,
          p_cents, public.edmonton_at(p_at::timestamp));
$$;
create function tests.hold(p_username text, p_fund text, p_units numeric, p_price numeric, p_day date)
returns void language sql as $$
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, effective_at)
  values (tests.acct(p_username), 'savings', p_fund, 'transfer_out', -ceil(p_units * p_price * 100)::bigint, null, null,
          public.edmonton_at(p_day + time '14:00')),
         (tests.acct(p_username), 'stock', p_fund, 'transfer_in', ceil(p_units * p_price * 100)::bigint, p_units, p_price,
          public.edmonton_at(p_day + time '14:00'));
$$;
create function tests.wi(p_username text) returns jsonb language sql as $$
  select public.kid_what_if(tests.acct(p_username));
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
insert into public.settings (key, value, effective_date)
values ('feature:inflation', 'test', date '2026-01-01'), ('feature:whatif', 'test', date '2026-01-01'),
       ('feature:markets', 'test', date '2026-01-01'), ('feature:reflection', 'test', date '2026-01-01'),
       ('feature:statements', 'test', date '2026-01-01'), ('feature:viewmodes', 'test', date '2026-01-01'),
       ('dividend_yield:nasdaq100', '0.6', date '2026-01-01');

-- Closes. Dow: 400 on Oct 17, 2025, 400 in September 2026, 440 from Oct 1. Nasdaq-100: 100 in
-- September, 120 in October; then 500 from Dec 1 to Feb 12, a 2-for-1 split on Feb 16, 275 after.
-- TSX: 50, a 2-for-1 split on Oct 5, 25 after (no real change).
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2025-10-17', 400);
select tests.closes('dow', '2026-09-01', '2026-09-30', 400);
select tests.closes('dow', '2026-10-01', '2026-10-19', 440);
select tests.closes('nasdaq100', '2026-09-01', '2026-09-30', 100);
select tests.closes('nasdaq100', '2026-10-01', '2026-10-19', 120);
select tests.closes('nasdaq100', '2026-12-01', '2027-02-12', 500);
select tests.closes('nasdaq100', '2027-02-16', '2027-03-05', 275);
insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to) values ('nasdaq100', '2027-02-16', 1, 2);
select tests.closes('tsx', '2026-09-01', '2026-10-02', 50);
insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to) values ('tsx', '2026-10-05', 1, 2);
select tests.closes('tsx', '2026-10-05', '2026-10-19', 25);

select tests.clock('2026-10-10 09:00');
select tests.new_kid('ln_a');            -- inflation, markets, reflection, modes
select tests.new_kid('ln_sis', false);   -- a real kid (the switches are "test accounts only")
select tests.new_kid('wi_a');            -- what-if: savings, a split
select tests.new_kid('wi_b');            -- what-if: a GIC special and a renewal
select tests.new_kid('wi_c');            -- what-if: a dividend
select tests.new_kid('wi_d');            -- what-if: a withdrawal
select tests.new_kid('wi_none');         -- nothing in yet

-- 1. The switches --------------------------------------------------------------------------------------

select is((select array_agg(name order by sort_order) from public.feature_list()),
  array['wishlist', 'personalisation', 'badges', 'inflation', 'whatif', 'markets', 'reflection', 'statements', 'viewmodes'],
  'Settings lists the six new switches after the earlier three');
select is((select count(*) from public.whats_new_features
            where feature in ('inflation', 'whatif', 'markets', 'reflection', 'statements', 'viewmodes')), 6::bigint,
  'each has its What''s new card');

select is(public.kid_features(tests.acct('ln_a')) ->> 'markets', 'true', 'one call says which switches are on for her...');
select is(public.kid_features(tests.acct('ln_sis')) ->> 'markets', 'false', '...and off for a real kid while "test accounts only"');

-- 2. The inflation view ---------------------------------------------------------------------------------

select tests.money('ln_a', 18411, '2026-10-10 10:00');
insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
values (tests.acct('ln_a'), 10000, 3, 3, '2026-10-10', '2027-01-10');
select tests.hold('ln_a', 'dow', 0.001, 440, '2026-10-13');
select tests.clock('2026-10-20 12:00');
select is(public.kid_inflation(tests.acct('ln_a')) ->> 'inflation_rate', '2.0', 'the rate is the inflation setting in force: 2.0%');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'savings' ->> 'now_cents', '18367',
  'her savings now ($184.11 in, $0.44 of it to the fund)');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'savings' ->> 'savings_rate', '2.000', 'at the regular savings rate, 2%');
-- $183.67 × (1 + 2%/12)^12 = $187.377..., about $187.38; ÷ 1.02 = $183.703..., about $183.70.
select is(public.kid_inflation(tests.acct('ln_a')) -> 'savings' ->> 'in_a_year_cents', '18738',
  '...in a year, compounding monthly: about $187.38');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'savings' ->> 'buys_like_cents', '18370',
  '...which buys what about $183.70 buys today');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'gics' -> 0 ->> 'at_maturity_cents', '10075',
  'a $100 3-month GIC at 3%: $100.75 when it finishes');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'gics' -> 0 ->> 'buys_like_cents', '10030',
  '...like about $100.30 today (82 days of 2% a year)');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'funds' -> 0 ->> 'fund', 'dow', 'her fund...');
select is(public.kid_inflation(tests.acct('ln_a')) -> 'funds' -> 0 ->> 'year_change_pct', '10.00',
  '...went up 10% over the past year (from Oct 17, 2025 to Oct 19, 2026), looking back, never a promise');
select tests.as_kid('ln_sis');
select is(public.kid_inflation(public.my_account_id()), '{"on": false}'::jsonb, 'off for a real kid while "test accounts only"');

-- 3. Compare the markets ------------------------------------------------------------------------------

select tests.as_kid('ln_a');
select is(public.kid_market_compare(public.my_account_id(), '1M') ->> 'from', '2026-09-21',
  '1M starts at the first close on or after Sep 20');
select is((select f ->> 'last_pct' from jsonb_array_elements(public.kid_market_compare(public.my_account_id(), '1M') -> 'funds') f
            where f ->> 'fund' = 'dow'), '10.00', 'the Dow fund: +10%');
select is((select f ->> 'last_pct' from jsonb_array_elements(public.kid_market_compare(public.my_account_id(), '1M') -> 'funds') f
            where f ->> 'fund' = 'nasdaq100'), '20.00', 'the Nasdaq-100 fund: +20%');
select is((select f ->> 'last_pct' from jsonb_array_elements(public.kid_market_compare(public.my_account_id(), '1M') -> 'funds') f
            where f ->> 'fund' = 'tsx'), '0.00', 'the TSX fund: 0% (a 2-for-1 split is not a 50% fall)');
select is((select (f -> 'points' -> 0 ->> 'pct') from jsonb_array_elements(public.kid_market_compare(public.my_account_id(), '1M') -> 'funds') f
            where f ->> 'fund' = 'dow'), '0.00', 'every line starts at 0%');
select is(tests.err($$select public.kid_market_compare(public.my_account_id(), '5Y')$$),
  'Pick 1M, 3M, 1Y, 2Y or since you started.', 'only the listed ranges');
select is(public.kid_market_compare(public.my_account_id(), 'start') ->> 'from', '2026-10-12',
  '"Since you started": from the first close on or after the day her account opened');

-- 4. Reflection: a separate call after a sell ------------------------------------------------------------

insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, held_units)
values (tests.acct('ln_a'), 'move', 'stock', 'savings', 'dow', 1000, 0.02272728);
insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, held_cents)
values (tests.acct('ln_a'), 'move', 'savings', 'stock', 'dow', 1000, 1000);
create temp table rq as
  select (select id from public.requests where account_id = tests.acct('ln_a') and from_vehicle = 'stock') as sell,
         (select id from public.requests where account_id = tests.acct('ln_a') and to_vehicle = 'stock') as buy;
create temp table sell_before as select r.* from public.requests r where r.id = (select sell from rq);
select tests.as_kid('ln_a');
select is(tests.err(format('select public.kid_save_reflection(%s, %L)', (select sell from rq), repeat('x', 301))),
  'Keep it to 300 letters or fewer.', 'at most 300 letters');
select is(tests.err(format('select public.kid_save_reflection(%s, %L)', (select sell from rq), '   ')),
  'Type why, or tap Skip.', 'not empty');
select is((select r::text from public.requests r where r.id = (select sell from rq)), (select s::text from sell_before s),
  'a refused reflection leaves the sell exactly as it was');
select is(tests.err(format('select public.kid_save_reflection(%s, %L)', (select buy from rq), 'Because')),
  'That isn''t one of your fund sales.', 'only for a sale, not a buy');
select lives_ok(format('select public.kid_save_reflection(%s, %L)', (select sell from rq),
  '  Prices went up, so I took some profit.  '), 'she says why she sold');
select is(public.kid_reflections(public.my_account_id()) -> 0 ->> 'text', 'Prices went up, so I took some profit.',
  'it''s kept, trimmed, with that sale');
select is((public.kid_reflections(public.my_account_id()) -> 0 ->> 'request_id')::bigint, (select sell from rq),
  '...linked to its request');
select is(tests.err(format('select public.kid_save_reflection(%s, %L)', (select sell from rq), 'Again')),
  'You already said why you sold.', 'once per sale');
select is((select r::text from public.requests r where r.id = (select sell from rq)), (select s::text from sell_before s),
  'the sell itself is untouched by its reflection');
select tests.as_kid('ln_sis');
select is(tests.err(format('select public.kid_save_reflection(%s, %L)', (select sell from rq), 'Hmm')),
  'That isn''t one of your fund sales.', 'her sister can''t write on her sale');
select is(tests.err(format('select public.kid_reflections(%L)', tests.acct('ln_a'))),
  'You can only see your own reflections.', '...or read why she sold');
set local role authenticated;
select is((select count(*) from public.sell_reflections), 0::bigint, '...not even straight from the table');
reset role;
select tests.as_parent();
select is(jsonb_array_length(public.kid_reflections(tests.acct('ln_a'))), 1, 'Dad can read it');
select is(public.parent_view(tests.acct('ln_a'), 'kid_reflections'), public.kid_reflections(tests.acct('ln_a')),
  '"View as" reads exactly what she reads');
select tests.nobody();
select is(tests.err($$update public.sell_reflections set reflection = 'changed'$$),
  'sell_reflections is append-only: update is not allowed. Add a new row instead.', 'reflections can''t be changed...');
select is(tests.err($$delete from public.sell_reflections$$),
  'sell_reflections is append-only: delete is not allowed. Add a new row instead.', '...or deleted');
select ok('public.sell_reflections' = any (private.prelaunch_tables()), 'the pre-launch reset clears them');

-- 5. View modes -----------------------------------------------------------------------------------------

select tests.as_kid('ln_a');
select is(public.kid_view_mode(public.my_account_id()), 'detailed', 'detailed to start');
select is(public.kid_set_view_mode('basic'), 'basic', 'she switches to the simpler view');
select is(public.kid_view_mode(public.my_account_id()), 'basic', '...kept on her account, so every device shows it');
select is(tests.err($$select public.kid_set_view_mode('tiny')$$), 'Pick basic or detailed.', 'only the two modes');
select tests.as_kid('ln_sis');
select is(public.kid_view_mode(public.my_account_id()), 'detailed', 'with the switch off for her: always detailed');
select is(tests.err($$select public.kid_set_view_mode('basic')$$),
  'The simpler view isn''t switched on for you yet.', '...and she can''t switch');

-- 6. What-if: dividends (Jan 5, 2027) ---------------------------------------------------------------------

select tests.nobody();
select is(tests.wi('wi_none'), '{"on": true, "none": true}'::jsonb, 'nothing put in yet: nothing to compare');
select tests.money('wi_c', 100000, '2026-12-01 09:00');
select tests.clock('2027-01-05 12:00');
-- $1,000 buys 2 units at Dec 1's $500. Q4: 2 units on 31 of its 92 days, at Dec 31's $500 and 0.6% a year:
-- 62 × 500 × 0.6 ÷ (4 × 92) = 50.54 cents, rounded up to 51, paid Jan 4.
select is(tests.wi('wi_c') ->> 'nasdaq_cents', '100051', 'Nasdaq-100: 2 units at $500 plus a $0.51 dividend');
select is(tests.wi('wi_c') ->> 'nasdaq_dividends_cents', '51', '...the dividend, by the real pro-rata rule');
select is(tests.wi('wi_c') ->> 'actual_cents', (select total_worth_cents::text from public.account_balances where account_id = tests.acct('wi_c')),
  'her real total sits beside it');

-- 7. What-if: a withdrawal (Feb 2, 2027) ------------------------------------------------------------------

select tests.money('wi_d', 100000, '2027-01-04 09:00');
select tests.money('wi_d', -30000, '2027-01-20 10:00');
select tests.clock('2027-02-02 12:00');
-- Savings: $1,000 for Jan 4–19 (16 days), $700 for Jan 20–31 (12 days) at 2%:
-- (100000 × 16 + 70000 × 12) × 0.02 ÷ 365 = 133.70 cents, rounded up to $1.34, paid Feb 1.
select is(tests.wi('wi_d') ->> 'savings_cents', '70134', 'savings: $700.00 and $1.34 of interest paid Feb 1');
select is(tests.wi('wi_d') ->> 'gic_cents', '70000',
  '1-year GICs: the withdrawal broke the GIC (principal back, no interest), as a real break does');
select is(tests.wi('wi_d') ->> 'gics_growing', '0', '...so none is still growing');
select is(tests.wi('wi_d') ->> 'nasdaq_cents', '70000',
  'Nasdaq-100: 0.6 of its 2 units sold at $500 for the withdrawal; 1.4 left at $500');

-- 8. What-if: savings and a split (Mar 2, 2027) ------------------------------------------------------------

select tests.money('wi_a', 100000, '2027-02-01 00:30');
select tests.clock('2027-03-02 12:00');
-- 28 days of February: 100000 × 0.02 × 28 ÷ 365 = 153.42 cents, rounded up to $1.54, paid Mar 1.
-- March 1's interest is still accruing, so it isn't counted (as with her real money).
select is(tests.wi('wi_a') ->> 'savings_cents', '100154', 'savings: $1,000.00 and February''s $1.54');
select is(tests.wi('wi_a') ->> 'gic_cents', '100000', '1-year GIC: $1,000.00, its interest comes when it finishes');
select is(tests.wi('wi_a') ->> 'gics_growing', '1', '...one still growing (Dad''s addition 3)');
select is(tests.wi('wi_a') ->> 'nasdaq_cents', '110000', 'Nasdaq-100: 2 units became 4 at the split; 4 × $275 = $1,100.00');

-- 9. What-if: a special rate, then a renewal (Mar 5, 2027) ---------------------------------------------------

insert into public.rates (vehicle, gic_term, rate, effective_date, end_date, is_special, note)
values ('gic', 12, 6.000, '2026-03-01', '2026-03-31', true, 'Test special');
select tests.money('wi_b', 100000, '2026-03-02 10:00');
select tests.clock('2027-03-05 12:00');
select is(tests.wi('wi_b') ->> 'gic_cents', '106000',
  'a deposit during a special locks it: $1,000 at 6% = $1,060.00, renewed Mar 2, 2027');
select is(tests.wi('wi_b') ->> 'gics_growing', '1', '...and the renewed GIC is still growing');

-- 10. Who sees the what-if ----------------------------------------------------------------------------------

select tests.as_kid('ln_sis');
select is(tests.err(format('select public.kid_what_if(%L)', tests.acct('wi_a'))),
  'You can only see your own what-if.', 'another kid can''t see hers');
select is(public.kid_what_if(public.my_account_id()), '{"on": false}'::jsonb, 'off for a real kid while "test accounts only"');
select tests.as_parent();
select is(public.parent_view(tests.acct('wi_a'), 'kid_what_if'), public.kid_what_if(tests.acct('wi_a')),
  '"View as" reads exactly what she reads');

-- 11. What's new for accounts made after a feature is on (Dad's addition 5) -----------------------------------

insert into public.settings (key, value, effective_date)
values ('feature:wishlist', 'test', date '2026-01-01'), ('feature:personalisation', 'test', date '2026-01-01'),
       ('feature:badges', 'test', date '2026-01-01'), ('feature:markets', 'off', public.app_today());
select tests.new_kid('wn_new');
select tests.as_kid('wn_new');
select public.finish_onboarding();
select is(public.whats_new(), '[]'::jsonb,
  'a girl who finishes onboarding with features on gets no What''s new for them (Wish List, Make it yours, Badges, Stage 11)');
select is((select count(*) from public.whats_new_seen where account_id = tests.acct('wn_new')), 8::bigint,
  '...all eight that were on are marked as met');
select tests.nobody();
insert into public.settings (key, value, effective_date) values ('feature:markets', 'test', public.app_today());
select tests.as_kid('wn_new');
select is((select jsonb_agg(w ->> 'feature') from jsonb_array_elements(public.whats_new()) w), '["markets"]'::jsonb,
  'a feature switched on after she onboarded gets its card');
select public.mark_whats_new_seen('markets');
select is(public.whats_new(), '[]'::jsonb, '...once');

-- 12. No money function knows about any of it ------------------------------------------------------------------

select tests.nobody();
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and (p.prosrc ilike '%what_if%' or p.prosrc ilike '%reflection%' or p.prosrc ilike '%inflation_view%'
                   or p.prosrc ilike '%market_compare%' or p.prosrc ilike '%view_mode%' or p.prosrc ilike '%statement%')
              and p.proname in ('buy_gic', 'break_gic', 'break_gic_core', 'choose_maturity', 'approve_request',
                                'approve_request_unlogged', 'request_deposit', 'request_withdrawal', 'request_trade',
                                'settle_trades', 'mature_gics', 'auto_move_unclaimed_maturities', 'post_monthly_interest',
                                'accrue_savings_interest', 'pay_quarterly_dividends', 'post_late_interest', 'apply_split',
                                'expire_requests', 'correct_savings', 'reconcile', 'reconcile_through', 'run_daily',
                                'move_preview', 'parent_decision_preview', 'set_setting', 'set_setting_unlogged')), null,
  'no money function calls any learning feature');

select * from finish();
rollback;
