-- Known answers: stock fund trades, settlement times, dividends, splits and
-- market-move notes (stage 2).
begin;
select plan(76);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated, service_role;

-- Freeze the app clock at an Edmonton date and time (works only in local dev).
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
-- A new kid with a login, created at the current app time.
create function tests.new_kid(p_username text, p_is_test boolean default false) returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, p_is_test) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  return v_acct;
end;
$$;
-- Money in the normal way: the kid asks, the parent approves.
create function tests.fund(p_username text, p_cents bigint) returns bigint language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
  return v_req;
end;
$$;
-- Run a daily job for each date in a range; returns the last status.
create function tests.run(p_job text, p_from date, p_to date default null) returns text
language plpgsql as $$
declare
  d date;
  r jsonb;
begin
  perform tests.nobody();
  for d in select generate_series(p_from, coalesce(p_to, p_from), interval '1 day')::date loop
    execute format('select public.%I($1)', p_job) into r using d;
  end loop;
  return r ->> 'status';
end;
$$;
create function tests.bal(p_username text) returns public.account_balances language sql as $$
  select * from public.account_balances where account_id = tests.acct(p_username);
$$;
create function tests.gic(p_username text, p_term int, p_start date) returns bigint language sql as $$
  select id from public.gic_holdings
   where account_id = tests.acct(p_username) and term_months = p_term and start_date = p_start
   order by id limit 1;
$$;
create function tests.gic_balance(p_gic bigint) returns bigint language sql as $$
  select coalesce(sum(amount_cents), 0)::bigint from public.transactions where gic_id = p_gic and vehicle = 'gic';
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');


create function tests.price(p_fund text, p_date date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close) values (p_fund, p_date, p_close);
$$;
create function tests.trade(p_username text, p_fund text, p_created date) returns public.requests language sql as $$
  select * from public.requests
   where account_id = tests.acct(p_username) and fund_id = p_fund
     and public.edmonton_local(created_at)::date = p_created
   order by id desc limit 1;
$$;
create function tests.units(p_username text, p_fund text) returns numeric language sql as $$
  select coalesce(sum(units), 0) from public.transactions
   where account_id = tests.acct(p_username) and fund_id = p_fund and vehicle = 'stock';
$$;
create function tests.edm(p text) returns timestamptz language sql as $$
  select public.edmonton_at(p::timestamp);
$$;

select tests.clock('2026-10-16 09:00');
select tests.new_kid('kid_t1');  -- Friday-evening buy, dividends, a split, sell all
select tests.new_kid('kid_t2');  -- early closes, before 12:00 pm
select tests.new_kid('kid_t3');  -- early close, after 12:00 pm
select tests.new_kid('kid_t4');  -- a missing close
select tests.new_kid('kid_t5');  -- partial sells

-- 1. When trades settle (pure calculation) -------------------------------------------

select is(public.next_settlement('dow', tests.edm('2026-10-16 19:00')), tests.edm('2026-10-19 14:00'),
  'a Friday-evening request settles at Monday''s 2:00 pm close');
select is(public.next_settlement('dow', tests.edm('2026-10-19 13:59')), tests.edm('2026-10-19 14:00'),
  'a request just before the close settles that day');
select is(public.next_settlement('dow', tests.edm('2026-10-19 14:00')), tests.edm('2026-10-20 14:00'),
  'a request at exactly the close waits for the next close');
select is(public.next_settlement('tsx', tests.edm('2027-03-26 10:00')), tests.edm('2027-03-29 14:00'),
  'on Good Friday both markets are closed: the TSX fund settles Monday');
select is(public.next_settlement('dow', tests.edm('2026-11-26 09:00')), tests.edm('2026-11-27 12:00'),
  'US Thanksgiving is closed, and the next day closes early at 12:00 pm Edmonton (1:00 pm Toronto)');
select is(public.next_settlement('tsx', tests.edm('2026-11-26 09:00')), tests.edm('2026-11-26 15:00'),
  'the TSX stays open on US Thanksgiving (each fund follows its own market)');
select is(public.next_settlement('dow', tests.edm('2026-11-27 10:30')), tests.edm('2026-11-27 12:00'),
  'early close (NYSE): a request at 10:30 am settles at that day''s 12:00 pm close');
select is(public.next_settlement('dow', tests.edm('2026-11-27 12:30')), tests.edm('2026-11-30 15:00'),
  'early close (NYSE): a request at 12:30 pm settles at the next trading day''s close');
select is(public.next_settlement('tsx', tests.edm('2026-12-24 12:00')), tests.edm('2026-12-29 15:00'),
  'early close (TSX): a request at exactly the 12:00 pm close on Christmas Eve waits, skips Christmas and Boxing Day (Dec 28) to Dec 29');
select is(public.next_settlement('dow', tests.edm('2026-12-24 12:00')), tests.edm('2026-12-28 15:00'),
  '...while the US fund settles Monday Dec 28');

-- 2. A Friday-evening buy (kid_t1) --------------------------------------------------

select tests.fund('kid_t1', 50000);
select tests.clock('2026-10-16 19:00');
select tests.as_kid('kid_t1');
select throws_like($$select public.request_trade('tsx', 'buy', 999)$$, '%smallest trade is $10.00%',
  'a fund buy under $10 is refused');
select throws_like($$select public.request_trade('dow', 'sell', 1000)$$, '%don''t have any%',
  'she can''t sell a fund she doesn''t own');
select lives_ok($$select public.request_trade('dow', 'buy', 10000)$$, 'she asks to buy $100 of the Dow fund');
select is((tests.bal('kid_t1')).held_cents, 10000::bigint, 'the $100 is held until the trade settles');
select is((tests.bal('kid_t1')).available_cents, 40000::bigint, 'held money isn''t available');
select is((tests.bal('kid_t1')).savings_cents, 50000::bigint, '...but it is still in savings until the close');
select throws_like($$select public.request_trade('dow', 'buy', 1000)$$, '%already traded the Dow Jones fund today%',
  'a second trade in the same fund on the same day is refused');
select throws_like($$select public.request_trade('nasdaq100', 'buy', 40001)$$, '%You have $400.00 available%',
  'a buy bigger than the available money is refused');
select is((select count(*) from public.requests where account_id = tests.acct('kid_t1')), 2::bigint,
  'refused requests leave nothing behind (just the deposit and the buy)');

select tests.price('dow', '2026-10-19', 420);
select tests.clock('2026-10-17 16:30');
select is(tests.run('settle_trades', '2026-10-16'), 'ok', 'nothing is due on Friday...');
select is((tests.trade('kid_t1', 'dow', '2026-10-16')).status::text, 'pending', '...so the buy is still pending over the weekend');
select tests.clock('2026-10-19 16:30');
select is(tests.run('settle_trades', '2026-10-19'), 'ok', 'Monday''s settlement runs');
select results_eq(
  $$select status::text, settled_at from public.requests where id = (tests.trade('kid_t1', 'dow', '2026-10-16')).id$$,
  $$values ('settled', tests.edm('2026-10-19 14:00'))$$,
  'the Friday-evening buy settled at Monday''s close');
select is(tests.units('kid_t1', 'dow'), 0.23809524, 'buying $100 at a close of 420 gives 0.23809524 units (rounded up)');
select results_eq(
  $$select amount_cents, unit_price from public.transactions
     where account_id = tests.acct('kid_t1') and vehicle = 'stock'$$,
  $$values (10000::bigint, 420::numeric(20,8))$$, 'the fund row records the $100 paid and the price');
select is((tests.bal('kid_t1')).savings_cents, 40000::bigint, 'the $100 left savings at the close');
select is((select value_cents from public.fund_positions where account_id = tests.acct('kid_t1') and fund_id = 'dow'),
  10000::bigint,
  'a $100 buy shows $100.00 right after settling: 0.23809524 × 420 = $100.0000008, shown to the nearest cent');
select is((tests.bal('kid_t1')).total_worth_cents, 50000::bigint, '...so her total worth is still exactly $500.00');
select is(
  (select (fund_values ->> 'dow')::bigint from public.daily_balances(tests.acct('kid_t1'), '2026-10-19', '2026-10-19')),
  10000::bigint, '...and the graphs show $100.00 too');
select is((tests.bal('kid_t1')).held_cents, 0::bigint, '...and the hold is released');
select is(
  (select count(*) from public.notifications where account_id = tests.acct('kid_t1') and related_request_id = (tests.trade('kid_t1', 'dow', '2026-10-16')).id),
  1::bigint, 'she gets a notice that the buy happened');

-- 3. A missing close: the trade waits, and never uses another day's price (kid_t4) --

select tests.clock('2026-11-02 09:00');
select tests.fund('kid_t4', 20000);
select tests.clock('2026-11-02 15:00');
select tests.as_kid('kid_t4');
select public.request_trade('dow', 'buy', 10000);
select tests.price('dow', '2026-11-04', 430);
select tests.clock('2026-11-04 16:30');
select is(tests.run('settle_trades', '2026-11-03'), 'waiting', 'with Nov 3''s close missing, settlement waits');
select is(tests.run('settle_trades', '2026-11-04'), 'waiting', '...and still waits the next day');
select is((tests.trade('kid_t4', 'dow', '2026-11-02')).status::text, 'pending', 'the trade did not settle on Nov 4''s price');
select tests.price('dow', '2026-11-03', 425);
select is(tests.run('settle_trades', '2026-11-04'), 'ok', 'once Nov 3''s close arrives...');
select results_eq(
  $$select r.settled_at, t.unit_price from public.requests r join public.transactions t on t.request_id = r.id and t.vehicle = 'stock'
     where r.id = (tests.trade('kid_t4', 'dow', '2026-11-02')).id$$,
  $$values (tests.edm('2026-11-03 15:00'), 425::numeric(20,8))$$,
  '...the trade settles at Nov 3''s real close');

-- 4. Early closes, settled for real (kid_t2 before 12:00 pm, kid_t3 after) -----------

select tests.clock('2026-11-27 09:00');
select tests.fund('kid_t2', 30000);
select tests.clock('2026-11-27 10:30');
select tests.as_kid('kid_t2');
select public.request_trade('dow', 'buy', 10000);
select tests.clock('2026-11-27 12:30');
select tests.as_kid('kid_t2');
select public.request_trade('nasdaq100', 'buy', 10000);
select tests.price('dow', '2026-11-27', 400);
select tests.price('nasdaq100', '2026-11-27', 500);
select tests.price('dow', '2026-11-30', 410);
select tests.price('nasdaq100', '2026-11-30', 520);
select tests.clock('2026-11-27 16:30');
select 'ran: ' || tests.run('settle_trades', '2026-11-27');
select results_eq(
  $$select status::text, settled_at from public.requests where id = (tests.trade('kid_t2', 'dow', '2026-11-27')).id$$,
  $$values ('settled', tests.edm('2026-11-27 12:00'))$$,
  'early close: the 10:30 am request settled at the 12:00 pm close the same day');
select is(tests.units('kid_t2', 'dow'), 0.25, '...at that day''s price: $100 ÷ 400 = 0.25 units');
select is((tests.trade('kid_t2', 'nasdaq100', '2026-11-27')).status::text, 'pending',
  'early close: the 12:30 pm request did not settle that day');
select tests.clock('2026-11-30 16:30');
select 'ran: ' || tests.run('settle_trades', '2026-11-30');
select results_eq(
  $$select status::text, settled_at from public.requests where id = (tests.trade('kid_t2', 'nasdaq100', '2026-11-27')).id$$,
  $$values ('settled', tests.edm('2026-11-30 15:00'))$$,
  '...it settled at the next trading day''s close');
select is(tests.units('kid_t2', 'nasdaq100'), 0.19230770, '...at that day''s price: $100 ÷ 520 = 0.19230770 units (rounded up)');

select tests.clock('2026-12-24 08:00');
select tests.fund('kid_t3', 20000);
select tests.clock('2026-12-24 10:00');
select tests.as_kid('kid_t2');
select public.request_trade('tsx', 'buy', 1000);
select tests.clock('2026-12-24 12:00');
select tests.as_kid('kid_t3');
select public.request_trade('tsx', 'buy', 1000);
select tests.price('tsx', '2026-12-24', 40);
select tests.price('tsx', '2026-12-29', 41);
select tests.clock('2026-12-24 16:30');
select 'ran: ' || tests.run('settle_trades', '2026-12-24');
select is((tests.trade('kid_t2', 'tsx', '2026-12-24')).settled_at, tests.edm('2026-12-24 12:00'),
  'TSX early close: a 10:00 am request on Christmas Eve settled at 12:00 pm');
select is((tests.trade('kid_t3', 'tsx', '2026-12-24')).status::text, 'pending',
  'TSX early close: a request at exactly the 12:00 pm close did not');
select tests.clock('2026-12-28 16:30');
select is(tests.run('settle_trades', '2026-12-28'), 'ok', 'Dec 28 is a TSX holiday: nothing is due');
select is((tests.trade('kid_t3', 'tsx', '2026-12-24')).status::text, 'pending', '...so it is still pending');
select tests.clock('2026-12-29 16:30');
select 'ran: ' || tests.run('settle_trades', '2026-12-29');
select results_eq(
  $$select r.settled_at, t.units from public.requests r join public.transactions t on t.request_id = r.id and t.vehicle = 'stock'
     where r.id = (tests.trade('kid_t3', 'tsx', '2026-12-24')).id$$,
  $$values (tests.edm('2026-12-29 15:00'), 0.24390244::numeric(20,8))$$,
  '...it settled at Dec 29''s close: $10 ÷ 41 = 0.24390244 units');

-- 5. Dividends (kid_t1 holds 0.23809524 Dow units) -----------------------------------

select tests.price('dow', '2026-12-31', 430);
select tests.price('nasdaq100', '2026-12-31', 510);
select tests.price('tsx', '2026-12-31', 42);
select tests.clock('2027-01-01 16:00');
select is(tests.run('pay_quarterly_dividends', '2027-01-01'), 'ok', 'Jan 1 is a holiday, not a business day...');
select is((select count(*) from public.transactions where type = 'dividend'), 0::bigint, '...so no dividend yet');
select tests.clock('2027-01-04 16:00');
select is(tests.run('pay_quarterly_dividends', '2027-01-04'), 'ok', 'Jan 4 is the first business day of the quarter');
select results_eq(
  $$select amount_cents, vehicle::text, fund_id, effective_at from public.transactions
     where posting_key = 'dividend:2027Q1:dow:' || tests.acct('kid_t1')$$,
  $$values (47::bigint, 'savings', 'dow', tests.edm('2027-01-04 00:00'))$$,
  'dividend: 0.23809524 units × $430 (Dec 31 close) × 1.8% ÷ 4 = $0.4607, rounded up to $0.47, into savings');
select is(
  (select note from public.transactions where posting_key = 'dividend:2027Q1:dow:' || tests.acct('kid_t1')),
  '0.23809524 units × $430.00 × 1.8% ÷ 4 = $0.4607, rounded up to $0.47', 'the dividend line shows its working');
select is(
  (select amount_cents from public.transactions where posting_key = 'dividend:2027Q1:tsx:' || tests.acct('kid_t3')),
  8::bigint, 'TSX dividend: 0.24390244 units × $42 × 2.8% ÷ 4 = $0.0717, rounded up to $0.08');
select is((select count(*) from public.transactions where type = 'dividend'), 6::bigint,
  'one dividend per fund held at the Dec 31 close: kid_t1 Dow; kid_t2 Dow, Nasdaq-100, TSX; kid_t3 TSX; kid_t4 Dow');

-- 6. A split keeps her holding's value; then she sells everything (kid_t1) ------------

select tests.clock('2027-01-04 17:00');
select is((select value_cents from public.fund_positions where account_id = tests.acct('kid_t1') and fund_id = 'dow'),
  10238::bigint,
  'a value shown is rounded to the nearest cent: 0.23809524 × 430 = $102.3809532 shows as $102.38');
select tests.as_kid('kid_t1');
select lives_ok($$select public.request_trade('dow', 'sell', null, true)$$, 'she asks to sell all her Dow units');
select is((tests.trade('kid_t1', 'dow', '2027-01-04')).held_units, 0.23809524::numeric(20,8), 'sell-all holds every unit');
insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to) values ('dow', '2027-01-05', 1, 2);
select tests.clock('2027-01-05 08:00');
select 'ran: ' || tests.run('apply_split', '2027-01-05');
select is(tests.units('kid_t1', 'dow'), 0.47619048, 'a 2-for-1 split doubles her units');
select results_eq(
  $$select amount_cents, units from public.transactions where account_id = tests.acct('kid_t1') and type = 'split_adjust'$$,
  $$values (0::bigint, 0.23809524::numeric(20,8))$$, '...with a $0 split_adjust line');
select is((tests.trade('kid_t1', 'dow', '2027-01-04')).held_units, 0.47619048::numeric(20,8), 'the pending sale''s hold doubles too');
select tests.price('dow', '2027-01-05', 215);
select is(ceil(tests.units('kid_t1', 'dow') * 215 * 100), ceil(0.23809524 * 430 * 100),
  'her holding is worth the same after the split ($102.39)');
select tests.clock('2027-01-05 16:30');
select 'ran: ' || tests.run('settle_trades', '2027-01-05');
select results_eq(
  $$select amount_cents, note from public.transactions
     where request_id = (tests.trade('kid_t1', 'dow', '2027-01-04')).id and vehicle = 'savings'$$,
  $$values (10239::bigint, '0.47619048 units × $215.00 = $102.3810, rounded up to $102.39')$$,
  'sale proceeds round up to the cent: $102.3809532 pays $102.39, into savings');
select is(tests.units('kid_t1', 'dow'), 0::numeric, 'she has no Dow units left');
select is((select cost_cents from public.fund_positions where account_id = tests.acct('kid_t1') and fund_id = 'dow'), 0::bigint,
  '...and no cost left on the books');

-- 7. Partial sells (kid_t5) ------------------------------------------------------

select tests.clock('2027-02-01 09:00');
select tests.fund('kid_t5', 30000);
select tests.clock('2027-02-01 10:00');
select tests.as_kid('kid_t5');
select public.request_trade('dow', 'buy', 10000);
select tests.price('dow', '2027-02-01', 420);
select tests.clock('2027-02-01 16:30');
select 'ran: ' || tests.run('settle_trades', '2027-02-01');
select tests.clock('2027-02-01 16:00');
select tests.as_kid('kid_t5');
select throws_like($$select public.request_trade('dow', 'sell', 5000)$$, '%already traded%',
  'a sell on the same day as a buy in that fund is refused (one trade per fund per day)');

select tests.clock('2027-02-02 09:00');
select tests.as_kid('kid_t5');
select throws_like($$select public.request_trade('dow', 'sell', 10001)$$, '%worth about $100.00%',
  'she can''t sell more than her units are worth');
select lives_ok($$select public.request_trade('dow', 'sell', 5000)$$, 'the next day she sells $50');
select is((tests.trade('kid_t5', 'dow', '2027-02-02')).held_units, 0.11904762::numeric(20,8),
  'the units for $50 at the latest close (420) are held');
select tests.price('dow', '2027-02-02', 430);
select tests.clock('2027-02-02 16:30');
select 'ran: ' || tests.run('settle_trades', '2027-02-02');
select is(tests.units('kid_t5', 'dow'), 0.12181618,
  'at 430 she sold 0.11627906 units ($50 ÷ 430, rounded down so she keeps more) and kept 0.12181618');
select is((tests.bal('kid_t5')).savings_cents, 25000::bigint, 'exactly $50.00 went into savings');
select is((select cost_cents from public.fund_positions where account_id = tests.acct('kid_t5') and fund_id = 'dow'), 5116::bigint,
  'average cost: $100 × 0.11627906 ÷ 0.23809524 = $48.84 left the books; $51.16 remains for the units she kept');

-- The price falls before the close: she sells everything she has (decision 2).
select tests.clock('2027-02-03 09:00');
select tests.as_kid('kid_t5');
select public.request_trade('dow', 'sell', 5200);
select tests.price('dow', '2027-02-03', 400);
select tests.clock('2027-02-03 16:30');
select 'ran: ' || tests.run('settle_trades', '2027-02-03');
select is(tests.units('kid_t5', 'dow'), 0::numeric, 'when $52 needs more units than she has, she sells all of them');
select results_eq(
  $$select amount_cents, note like '%sold all%' from public.transactions
     where request_id = (tests.trade('kid_t5', 'dow', '2027-02-03')).id and vehicle = 'savings'$$,
  $$values (4873::bigint, true)$$,
  '...for 0.12181618 × 400 = $48.73 (rounded up), with a note explaining why');

-- 8. Market-move notes ----------------------------------------------------------

select tests.price('nasdaq100', '2027-02-01', 500);
select tests.price('nasdaq100', '2027-02-02', 489);
select tests.price('nasdaq100', '2027-02-03', 499);
select tests.price('nasdaq100', '2027-02-04', 508);
select tests.price('dow', '2027-02-04', 401);
select tests.clock('2027-02-04 16:00');
select is(tests.run('write_market_move_notes', '2027-02-02'), 'waiting', 'the TSX close for Feb 2 is missing, so the note job will look again');
select results_eq(
  $$select fund_id, body from public.notes where note_date = '2027-02-02' order by fund_id$$,
  $$values ('dow', (select value from public.settings where key = 'market_move_note_up' order by id desc limit 1)),
           ('nasdaq100', (select value from public.settings where key = 'market_move_note_down' order by id desc limit 1))$$,
  'Feb 2: the Dow rose 2.4% and the Nasdaq-100 fell 2.2%, so each gets the standard note');
select 'ran: ' || tests.run('write_market_move_notes', '2027-02-02');
select is((select count(*) from public.notes where note_date = '2027-02-02'), 2::bigint, 'running it again adds nothing');
select 'ran: ' || tests.run('write_market_move_notes', '2027-02-04');
select is((select count(*) from public.notes where note_date = '2027-02-04'), 0::bigint,
  'moves of 1.8% and 0.25% get no note (it takes more than 2%)');

select * from finish();
rollback;
