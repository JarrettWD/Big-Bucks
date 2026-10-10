-- Known answers for the pre-launch audit fixes (stage 4, step 1, 2026-10-08):
--   * only final closes settle trades or pay dividends; prices and splits are append-only;
--     Dad can fix an unused close, and record a market closure;
--   * savings interest and GICs never wait for fund prices; money that reaches savings
--     late counts from the next Alberta midnight and gets the interest it missed;
--   * a late nightly run never costs her days of her GIC choice;
--   * pro-rata dividends (days held in the quarter, splits counted), at the yield in force
--     on the payment day;
--   * the agreement gate; the rate notice hidden by a special; Dad's longer history view;
--     the 7-day rule across midnight; TRUNCATE refused on the What's new tables.
-- One simulated stretch, Oct 5, 2026 to Jan 6, 2027, with the nightly run each evening.
begin;
select plan(81);

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
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
-- A new kid; p_countersigned false leaves Dad's signature off.
create function tests.new_kid(p_username text, p_countersigned boolean default true) returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
  if p_countersigned then
    insert into public.agreement_signatures (account_id, version, signer, signed_by)
      values (v_acct, 1, 'parent', v_user);
  end if;
  return v_acct;
end;
$$;
create function tests.fund(p_username text, p_cents bigint) returns void language plpgsql as $$
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
-- A close fetched 30 minutes after the market closed (final), or an hour before (not final).
create function tests.price(p_fund text, p_date date, p_close numeric, p_final boolean default true) returns void
language sql as $$
  insert into public.fund_prices (fund_id, price_date, close, fetched_at)
  select p_fund, p_date, p_close,
         public.close_time(f.market, p_date) + case when p_final then interval '30 minutes' else interval '-2 hours' end
    from public.funds f where f.id = p_fund;
$$;
-- The nightly run at 4:30 pm on a day.
create function tests.night(p_day date) returns text language plpgsql as $$
begin
  perform tests.clock(p_day || ' 16:30');
  perform tests.nobody();
  return public.run_daily(p_day) ->> 'status';
end;
$$;
create function tests.nights(p_from date, p_to date) returns text language plpgsql as $$
declare
  d date;
  v text;
begin
  for d in select generate_series(p_from, p_to, interval '1 day')::date loop
    v := tests.night(d);
  end loop;
  return v;
end;
$$;
create function tests.trade(p_username text, p_fund text) returns public.requests language sql as $$
  select * from public.requests where account_id = tests.acct(p_username) and fund_id = p_fund order by id desc limit 1;
$$;
create function tests.units(p_username text, p_fund text) returns numeric language sql as $$
  select coalesce(sum(units), 0) from public.transactions
   where account_id = tests.acct(p_username) and fund_id = p_fund and vehicle = 'stock';
$$;
create function tests.edm(p text) returns timestamptz language sql as $$
  select public.edmonton_at(p::timestamp);
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Closes for every trading day, except the ones the story sets itself: the Dow's Nov 17
-- and Dec 31 closes arrive late, Dec 14 is an unscheduled NYSE closure, and the
-- Nasdaq-100's Dec 16 close is first fetched too early. The Dow splits 2-for-1 on Dec 1.
insert into public.fund_prices (fund_id, price_date, close, fetched_at)
select f.id, d::date,
       case f.id when 'dow' then case when d < '2026-12-01' then 500 else 250 end
                 when 'nasdaq100' then 100 else 40 end,
       public.close_time(f.market, d::date) + interval '30 minutes'
  from public.funds f cross join generate_series(date '2026-10-01', date '2027-01-08', interval '1 day') d
 where public.is_trading_day(f.market, d::date)
   and not (f.id = 'dow' and d::date in ('2026-11-17', '2026-12-31'))
   and not (f.market = 'nyse' and d::date = '2026-12-14')
   and not (f.id = 'nasdaq100' and d::date = '2026-12-16');
insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to) values ('dow', '2026-12-01', 1, 2);

-- 1. Prices and splits are append-only ----------------------------------------------------------

select is(tests.err($$update public.fund_prices set close = 1 where fund_id = 'dow' and price_date = '2026-10-05'$$),
  'fund_prices is append-only: update is not allowed. A wrong close is fixed with correct_fund_price.',
  'a stored close can''t be edited, even by the database owner');
select is(tests.err($$delete from public.fund_prices where fund_id = 'dow' and price_date = '2026-10-05'$$),
  'fund_prices is append-only: delete is not allowed. A wrong close is fixed with correct_fund_price.',
  '...or deleted');
select is(tests.err($$truncate public.fund_prices cascade$$),
  'fund_prices is append-only: truncate is not allowed. Add a new row instead.', '...or wiped');
select is(tests.err($$update public.fund_splits set ratio_to = 3$$),
  'fund_splits is append-only: update is not allowed. Add a new row instead.', 'splits can''t be edited');
select is(tests.err($$delete from public.fund_splits$$),
  'fund_splits is append-only: delete is not allowed. Add a new row instead.', '...or deleted');
select is(tests.err($$truncate public.whats_new_seen$$),
  'whats_new_seen is append-only: truncate is not allowed. Add a new row instead.', 'What''s new tables refuse TRUNCATE');
select is(tests.err($$truncate public.whats_new_features cascade$$),
  'whats_new_features is append-only: truncate is not allowed. Add a new row instead.', '...both of them');

-- 2. The story starts: Oct 5 -----------------------------------------------------------------------

select tests.clock('2026-10-05 09:00');
select tests.new_kid('kid_g');   -- two GICs that mature in a missed week
select tests.new_kid('kid_s');   -- a sale whose close comes late
select tests.new_kid('kid_p');   -- pro-rata: a partial sale and a split in the quarter
select tests.new_kid('kid_d');   -- buys 3 days before the quarter ends; a late dividend
select tests.new_kid('kid_c');   -- a market closure; an early-fetched close
select tests.new_kid('kid_x', false);  -- Dad hasn't signed her agreement
select tests.fund(k, 100000) from unnest(array['kid_g', 'kid_s', 'kid_p', 'kid_d', 'kid_c']) k;

select tests.clock('2026-10-05 10:00');
select tests.as_kid('kid_g');
select public.buy_gic(10000, 1);
select public.buy_gic(10000, 1);
select tests.as_kid('kid_s');
select public.request_trade('dow', 'buy', 50000);
select tests.as_kid('kid_p');
select public.request_trade('dow', 'buy', 100000);

-- 3. The agreement gate (kid_x: she signed, Dad hasn't) -------------------------------------------

select tests.as_kid('kid_x');
create temp table xdep as select public.request_deposit(1000) as id;
select ok((select id from xdep) is not null, 'she can ask for her first deposit once she has signed');
select tests.as_parent();
select is(tests.err('select public.approve_request((select id from xdep))'),
  'Test kid_x signed her agreement and is waiting for you to sign it too. Sign it first (it''s at the top of Approvals), then approve this.',
  'Dad can''t approve it until he has signed too, so no money moves before both signatures');
select tests.as_kid('kid_x');
select is(tests.err('select public.request_withdrawal(500)'),
  'Dad hasn''t signed your agreement yet. As soon as he does, this will work.', 'no withdrawal before both have signed');
select is(tests.err($$select public.request_trade('dow', 'buy', 1000)$$),
  'Dad hasn''t signed your agreement yet. As soon as he does, this will work.', 'no fund trade');
select is(tests.err('select public.buy_gic(1000, 1)'),
  'Dad hasn''t signed your agreement yet. As soon as he does, this will work.', 'no GIC');
select is(tests.err('select public.break_gic(1)'),
  'Dad hasn''t signed your agreement yet. As soon as he does, this will work.', 'no breaking a GIC');
select is(tests.err('select public.finish_onboarding()'),
  'Dad hasn''t signed your agreement yet. As soon as he does, this will work.', 'and onboarding can''t finish');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.proname in ('request_withdrawal_core', 'request_trade_core', 'buy_gic_core', 'break_gic_core')
           and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  '{}'::text[], 'the unchecked originals can''t be called from the app');

-- 4. October and early November: every night runs ------------------------------------------------

select is(tests.nights('2026-10-05', '2026-11-04'), 'ok', 'Oct 5 to Nov 4: every night runs');
select is(tests.units('kid_s', 'dow'), 1.00000000, 'kid_s bought 1 Dow unit at the Oct 5 close ($500 ÷ $500)');
select is(tests.units('kid_p', 'dow'), 2.00000000, 'kid_p bought 2');

-- 5. A missed week: her GIC choice window stretches -----------------------------------------------

-- Both GICs mature Thu Nov 5. No nightly run Nov 5 to Nov 8; Nov 9's run catches up.
select is(tests.night('2026-11-09'), 'ok', 'Nov 9''s run catches up the missed nights');
select results_eq(
  $$select status::text, choice_ends from public.gic_holdings where account_id = tests.acct('kid_g') order by id$$,
  $$values ('matured', date '2026-11-16'), ('matured', date '2026-11-16')$$,
  'processed 4 days late, so her 7 days start from Nov 9: they move on their own on Nov 16, not Nov 12');
select is((select distinct choose_by from public.gic_positions where account_id = tests.acct('kid_g')), date '2026-11-15',
  'the screens show her last day to choose: Nov 15');
select is((select body from public.notifications where dedupe_key = 'gic_matured:'
             || (select min(id) from public.gic_holdings where account_id = tests.acct('kid_g'))),
  'Your 1-month GIC finished and earned $0.21, so you now have $100.21. Choose what happens next by Nov 15: renew it, pick a new term, or move it to savings. Until you choose, it earns the savings rate.',
  'her notice gives the stretched date');
select is((select amount_cents from public.transactions
            where posting_key = 'gic_interest:' || (select min(id) from public.gic_holdings where account_id = tests.acct('kid_g'))),
  21::bigint, 'GIC interest is still dated its maturity day: $100 × 2.5% × 1/12 = $0.2083, rounded up to $0.21');
select is(tests.nights('2026-11-10', '2026-11-12'), 'ok', 'Nov 10 to 12 run');
select is((select count(*)::int from public.gic_holdings where account_id = tests.acct('kid_g') and maturity_choice is null), 2,
  'Nov 12 (the old day 7) passes and nothing moved: she still has her days');
select tests.clock('2026-11-13 12:00');
select tests.as_kid('kid_g');
select lives_ok(format('select public.choose_maturity(%s, %L)',
                       (select min(id) from public.gic_holdings where account_id = tests.acct('kid_g')), 'to_savings'),
  'on Nov 13, after the old deadline, she can still choose');

-- 6. Pro-rata: kid_p sells half on Nov 16 (on time) ------------------------------------------------

select 'ran: ' || tests.nights('2026-11-13', '2026-11-15');
select tests.clock('2026-11-16 10:00');
select tests.as_kid('kid_p');
select public.request_trade('dow', 'sell', 50000);
select is(tests.night('2026-11-16'), 'ok', 'Nov 16 runs');
select is(tests.units('kid_p', 'dow'), 1.00000000, 'kid_p sold 1 unit at $500, keeping 1');
select is((select effective_at from public.transactions where account_id = tests.acct('kid_g') and type = 'transfer_in'
            and vehicle = 'savings' and posting_key like 'gic_release:%' and note like 'Moved to savings automatically%'),
  public.edmonton_start('2026-11-16'), 'the GIC she didn''t choose for moved to savings at the start of Nov 16');
select is((select note from public.transactions where account_id = tests.acct('kid_g') and vehicle = 'savings'
            and note like 'Moved to savings automatically%'),
  'Moved to savings automatically: no choice was made by Nov 15.', '...saying why');

-- 7. A late close: interest carries on; the sale's money gets what it missed ----------------------

select tests.clock('2026-11-17 10:00');
select tests.as_kid('kid_s');
select public.request_trade('dow', 'sell', null, true);
select is(tests.night('2026-11-17'), 'waiting', 'Nov 17: the Dow close is missing, so the fund work waits');
select is(tests.night('2026-11-18'), 'waiting', 'Nov 18: still waiting...');
select ok(exists (select 1 from public.job_runs where job = 'interest' and run_for_date = '2026-11-17' and status = 'ok'),
  '...but Nov 17''s savings interest was worked out anyway (Dad''s decision, 2026-10-08)');
select is((select balance_cents from public.interest_accruals where account_id = tests.acct('kid_s') and accrual_date = '2026-11-17'),
  (select balance_cents from public.interest_accruals where account_id = tests.acct('kid_s') and accrual_date = '2026-11-16'),
  'on what was really in her savings that night: the same as the night before, without the sale''s money');
select is(tests.night('2026-11-19'), 'waiting', 'Nov 19: still waiting');
select tests.clock('2026-11-20 16:00');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2026-11-17', 510);
select is(tests.night('2026-11-20'), 'ok', 'Nov 20: the close arrives and everything catches up');
select results_eq(
  $$select t.vehicle::text, t.amount_cents, t.effective_at from public.transactions t
     where t.request_id = (tests.trade('kid_s', 'dow')).id order by t.vehicle$$,
  $$values ('savings', 51000::bigint, public.edmonton_start('2026-11-19')),
           ('stock', -50000::bigint, public.close_time('nyse', '2026-11-17'))$$,
  'the sale settled at Nov 17''s real close ($510); her units left at the close, and the $510 counts from the start of Nov 19 (Nov 17 and 18''s interest was already worked out)');
select results_eq(
  $$select amount_cents, effective_at, note from public.transactions
     where posting_key = 'late_interest:trade:' || (tests.trade('kid_s', 'dow')).id$$,
  $$values (6::bigint, public.edmonton_start('2026-11-19'),
            'Interest for the 2 days your sale''s money waited to reach your savings (Nov 17 to Nov 18): $510.00 at the savings rate = $0.0559, rounded up to $0.06.')$$,
  'the interest it missed: $510 × 2% ÷ 365 × 2 days = $0.0559, rounded up to $0.06, as its own line');
select is((select balance_cents from public.interest_accruals where account_id = tests.acct('kid_s') and accrual_date = '2026-11-19')
          - (select balance_cents from public.interest_accruals where account_id = tests.acct('kid_s') and accrual_date = '2026-11-18'),
  51006::bigint, 'from Nov 19 her savings interest includes the $510 and the $0.06');

-- 8. A market closure (Dec 14) and a close fetched too early (Dec 16) -----------------------------

select 'ran: ' || tests.nights('2026-11-21', '2026-12-13');
select is(tests.units('kid_p', 'dow'), 2.00000000, 'the Dec 1 split doubled kid_p''s 1 unit to 2');
select tests.clock('2026-12-14 10:00');
select tests.as_kid('kid_c');
select public.request_trade('nasdaq100', 'buy', 10000);
select tests.clock('2026-12-14 16:00');
select tests.as_kid('kid_c');
select is(tests.err($$select public.record_market_closure('nyse', '2026-12-14', 'National day of mourning')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'only Dad can record a closure');
select tests.as_parent('aal1');
select is(tests.err($$select public.record_market_closure('nyse', '2026-12-14', 'National day of mourning')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...with the authenticator code');
select tests.as_parent();
select is(tests.err($$select public.record_market_closure('nyse', '2026-12-12', 'x')$$),
  'The New York Stock Exchange already doesn''t trade on Dec 12.', 'a Saturday is already closed');
select is(tests.err($$select public.record_market_closure('nyse', '2026-12-11', 'x')$$),
  'There''s already a close for New York Stock Exchange on Dec 11, so the market was open that day.',
  'a day with a close was open');
select lives_ok($$select public.record_market_closure('nyse', '2026-12-14', 'National day of mourning')$$,
  'Dad records that the NYSE was closed on Mon Dec 14');
select is(public.is_trading_day('nyse', '2026-12-14'), false, 'Dec 14 is now a closed day');
select is((select body from public.notifications where dedupe_key like 'closure:nyse:2026-12-14:%'),
  'The New York Stock Exchange was closed on Dec 14, so your Nasdaq-100 buy will happen at the next close, on Dec 15.',
  'kid_c, whose buy was waiting for that day, is told');
select results_eq(
  $$select action, summary from public.parent_actions where action = 'record_market_closure'$$,
  $$values ('record_market_closure', 'Recorded that the New York Stock Exchange was closed on Dec 14: National day of mourning.')$$,
  'it''s in Dad''s log');
select is(tests.night('2026-12-14'), 'ok', 'Dec 14''s run doesn''t wait for a close that will never come');
select is(tests.night('2026-12-15'), 'ok', 'Dec 15 runs');
select results_eq(
  $$select r.settled_at, t.unit_price from public.requests r join public.transactions t on t.request_id = r.id and t.vehicle = 'stock'
     where r.id = (tests.trade('kid_c', 'nasdaq100')).id$$,
  $$values (public.close_time('nyse', '2026-12-15'), 100::numeric(20,8))$$, 'the buy settled at the next close, Dec 15');

select tests.clock('2026-12-16 10:00');
select tests.as_kid('kid_c');
select public.request_trade('nasdaq100', 'buy', 10000);
select tests.clock('2026-12-16 13:00');
select tests.price('nasdaq100', '2026-12-16', 101, false);
select is(tests.night('2026-12-16'), 'waiting', 'a close fetched at 1:00 pm, before the 3:00 pm close, isn''t final: it waits');
select is((tests.trade('kid_c', 'nasdaq100')).status::text, 'pending', '...and the trade doesn''t settle on it');
select is(public.final_close('nasdaq100', '2026-12-16'), null::numeric, 'final_close() doesn''t count it');
select tests.clock('2026-12-16 17:00');
select tests.as_kid('kid_c');
select is(tests.err($$select public.correct_fund_price('nasdaq100', '2026-12-16', 102, 'From the exchange')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'only Dad can fix a close');
select tests.as_parent();
select is(tests.err($$select public.correct_fund_price('nasdaq100', '2026-12-16', 102, ' ')$$),
  'Say where the right close comes from, so the fix explains itself.', 'a fix needs a reason');
select lives_ok($$select public.correct_fund_price('nasdaq100', '2026-12-16', 102, 'From the exchange''s closing price')$$,
  'Dad types in the real close from the exchange');
select results_eq(
  $$select old_close, new_close, note from public.fund_price_corrections$$,
  $$values (101::numeric(20,8), 102::numeric(20,8), 'From the exchange''s closing price')$$, 'the old and new close are kept');
select is((select summary from public.parent_actions where action = 'correct_fund_price'),
  'Fixed the Nasdaq-100 close for Dec 16: $101.0000 → $102.0000.', '...and it''s in Dad''s log');
select is(tests.night('2026-12-16'), 'ok', 'the run carries on');
select is(tests.units('kid_c', 'nasdaq100'), 1.98039216, 'the buy settled at $102: $100 ÷ 102 = 0.98039216 units (rounded up)');
select tests.as_parent();
select is(tests.err($$select public.correct_fund_price('nasdaq100', '2026-12-16', 103, 'Again')$$),
  'A trade already settled at this close, so it can''t change. Fix that trade with a correction instead.',
  'a close a trade settled at can''t change');

-- 9. Pro-rata dividends, a yield set after the quarter, and a late close --------------------------

select 'ran: ' || tests.nights('2026-12-17', '2026-12-28');
select tests.clock('2026-12-29 10:00');
select tests.as_kid('kid_d');
select public.request_trade('dow', 'buy', 50000);
select public.request_trade('tsx', 'buy', 40000);
select 'ran: ' || tests.nights('2026-12-29', '2027-01-01');
-- The TSX yield goes up from 2.8% to 4.0% on Jan 2: after the quarter ended, before it's paid.
insert into public.settings (key, value, effective_date) values ('dividend_yield:tsx', '4.0', '2027-01-02');
select 'ran: ' || tests.nights('2027-01-02', '2027-01-03');
select is(tests.night('2027-01-04'), 'waiting', 'Jan 4: the Dow''s Dec 31 close is missing, so its dividend waits');
select is((select amount_cents from public.transactions where posting_key = 'dividend:2027Q1:tsx:' || tests.acct('kid_d')),
  14::bigint, 'TSX: 10 units for 3 of 92 days × $40 × 4.0% (the yield on the payment day) ÷ 4 × 3/92 = $0.1304, rounded up to $0.14');
select is((select note from public.transactions where posting_key = 'dividend:2027Q1:tsx:' || tests.acct('kid_d')),
  'You owned 10.00000000 units for 3 of the quarter''s 92 days: 10.00000000 × $40.00 × 4.0% ÷ 4 × 3/92 = $0.1304, rounded up to $0.14',
  'the line explains the days she held them');
select is((select effective_at from public.transactions where posting_key = 'dividend:2027Q1:tsx:' || tests.acct('kid_d')),
  public.edmonton_start('2027-01-04'), 'the TSX dividend was on time: from the start of Jan 4');
select is(tests.night('2027-01-05'), 'waiting', 'Jan 5: still waiting');
select is((select count(*)::int from public.transactions where posting_key like 'late\_interest:dividend:2027Q1:tsx:%'), 0,
  'running the dividend job again while the Dow waits adds nothing to the TSX dividend');
select tests.clock('2027-01-06 16:00');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2026-12-31', 250);
select is(tests.night('2027-01-06'), 'ok', 'Jan 6: the close arrives and the dividends are paid');
select results_eq(
  $$select p.username, t.amount_cents from public.transactions t join public.profiles p on p.account_id = t.account_id
     where t.posting_key like 'dividend:2027Q1:dow:%' order by p.username$$,
  $$values ('kid_d', 8::bigint), ('kid_p', 318::bigint), ('kid_s', 106::bigint)$$,
  'pro-rata Dow dividends at $250 × 1.8% ÷ 4 ÷ 92 days, units counted after the Dec 1 split: '
  || 'kid_d 2 units × 3 days = $0.0734 → $0.08; kid_p 2 units × 42 days × 2 + 1 × 15 × 2 + 2 × 31 = 260 → $3.1793 → $3.18; '
  || 'kid_s 1 unit × 43 days × 2 = 86 → $1.0516 → $1.06 (she sold before the quarter ended and still gets her share)');
select is((select note from public.transactions where posting_key = 'dividend:2027Q1:dow:' || tests.acct('kid_p')),
  'Your units changed during the quarter: on average about 2.82608696 over its 92 days. 2.82608696 × $250.00 × 1.8% ÷ 4 = $3.1793, rounded up to $3.18',
  'when her units changed, the line shows the average she held');
select is((select effective_at from public.transactions where posting_key = 'dividend:2027Q1:dow:' || tests.acct('kid_p')),
  public.edmonton_start('2027-01-05'), 'Jan 4''s interest was already worked out, so the Dow dividends count from the start of Jan 5');
select results_eq(
  $$select p.username, t.amount_cents from public.transactions t join public.profiles p on p.account_id = t.account_id
     where t.posting_key like 'late\_interest:dividend:2027Q1:dow:%' order by p.username$$,
  $$values ('kid_d', 1::bigint), ('kid_p', 1::bigint), ('kid_s', 1::bigint)$$,
  'each gets the interest the dividend missed for Jan 4, rounded up: 1¢ each');

-- 10. The whole stretch reconciles ---------------------------------------------------------------

select tests.nobody();
select is(
  (select count(*)::int from generate_series(date '2026-10-05', date '2027-01-06', interval '1 day') d
    where public.reconcile(d::date) ->> 'status' <> 'ok'),
  0, 'the nightly reconciliation finds nothing wrong on any day, the late days included');
select is(tests.err($$select public.correct_fund_price('dow', '2026-12-31', 251, 'x')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a server can''t fix a close either');
select tests.as_parent();
select is(tests.err($$select public.correct_fund_price('dow', '2026-12-31', 251, 'Typo')$$),
  'A dividend was already paid from this close, so it can''t change. Fix it with a correction instead.',
  'a close a dividend was paid from can''t change');

-- 11. A regular change hidden by a running special: the notice says so ----------------------------

savepoint rates;
select tests.clock('2027-01-07 09:00');
select tests.as_parent();
select public.add_rate('savings', null, 5.0, '2027-01-07', 'Winter special', '2027-01-20');
select public.add_rate('savings', null, 2.5, '2027-01-14', null, null);
select results_eq(
  $$select title, body from public.notifications
     where account_id = tests.acct('kid_s') and type = 'rate_change' order by id desc limit 1$$,
  $$values ('Savings rate after the special: 2.5%',
            'The special at 5.0% keeps going until Jan 20. After that, the rate will be 2.5%.')$$,
  'it doesn''t say the rate drops: she keeps the special until it ends');
rollback to savepoint rates;

-- 12. The 7-day rule across midnight ---------------------------------------------------------------

savepoint cut;
select tests.clock('2027-01-07 23:59');
select tests.as_parent();
select lives_ok($$select public.add_rate('savings', null, 1.5, '2027-01-14', null, null)$$,
  'a cut saved at 11:59 pm on Jan 7, starting Jan 14: 7 days'' notice (Jan 7 to 13)');
rollback to savepoint cut;
select tests.clock('2027-01-08 00:01');
select tests.as_parent();
select throws_like($$select public.add_rate('savings', null, 1.5, '2027-01-14', null, null)$$, '%7 days'' notice%',
  'the same cut saved at 12:01 am on Jan 8 is refused: only 6 days');

-- 13. Dad's screens can see more than 200 history lines -------------------------------------------

select tests.nobody();
insert into public.requests (account_id, type, to_vehicle, amount_cents, status, decided_at, parent_note)
select tests.acct('kid_x'), 'deposit', 'savings', 500, 'declined', public.app_now(), 'Not now'
  from generate_series(1, 210);
select tests.as_kid('kid_x');
select is((select count(*)::int from public.my_activity(tests.acct('kid_x'), 100000)), 200,
  'her app gets at most 200 lines at a time');
select tests.as_parent();
select is((select count(*)::int from public.my_activity(tests.acct('kid_x'), 100000)), 211,
  'Dad''s screens can see them all (so Approvals always finds the line a question is about)');

select * from finish();
rollback;
