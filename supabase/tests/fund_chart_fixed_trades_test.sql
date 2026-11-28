-- Stage 12 block 1, item 5: the Graphs tab labels a trade whose close was fixed (Dad, 2026-11-16).
-- fund_chart's trades show the fixed close and what the fix gave her, tagged 'fixed'; a close fixed
-- in a way that changed nothing for her (the old close was in her favour) shows the price she got,
-- tagged 'kept'; a close never fixed (or only confirmed) has no tag. Known answers from the real
-- trades on production (#35, #37), rebuilt with their own closes, as in close_fix_test.sql, and dated
-- 2028, past anything the local demo or end-to-end runs store.
begin;
select plan(11);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2027-01-01');
$$;
create function tests.as_parent() returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000000f', 'role', 'authenticated', 'aal', 'aal2')::text, true);
$$;
-- A trade as settle_trades leaves it: the request, its savings line and its fund line.
create function tests.trade(p_acct uuid, p_fund text, p_day date, p_side text, p_cents bigint, p_units numeric,
                            p_close numeric, p_cost bigint default null, p_sell_all boolean default false)
returns bigint language plpgsql as $$
declare
  v_req bigint;
  v_at timestamptz := public.close_time((select market from public.funds where id = p_fund), p_day);
begin
  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all, status,
                               created_at, decided_at, settled_at)
  values (p_acct, 'move', case when p_side = 'buy' then 'savings' else 'stock' end::public.vehicle,
          case when p_side = 'buy' then 'stock' else 'savings' end::public.vehicle, p_fund,
          case when p_sell_all then null else p_cents end, p_sell_all, 'settled', v_at - interval '6 hours', v_at, v_at)
  returning id into v_req;
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, request_id, posting_key, effective_at, note)
  values (p_acct, 'savings', p_fund, case when p_side = 'buy' then 'transfer_out' else 'transfer_in' end::public.transaction_type,
          case when p_side = 'buy' then -p_cents else p_cents end, v_req, 'trade:' || v_req || ':savings', v_at, 'test');
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                   posting_key, effective_at, note)
  values (p_acct, 'stock', p_fund, case when p_side = 'buy' then 'transfer_in' else 'transfer_out' end::public.transaction_type,
          case when p_side = 'buy' then p_cents else -coalesce(p_cost, p_cents) end,
          case when p_side = 'buy' then p_units else -p_units end, p_close, v_req, 'trade:' || v_req || ':fund', v_at, 'test');
  return v_req;
end;
$$;
create function tests.close(p_fund text, p_day date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close) values (p_fund, p_day, p_close);
$$;
create temp table k (name text primary key, acct uuid);
-- Her trade on a day, as the Graphs tab gets it.
create function tests.trade_on(p_name text, p_fund text, p_day text, p_side text) returns jsonb language sql as $$
  select x from jsonb_array_elements(
           public.fund_chart((select acct from k where name = p_name), p_fund, date '2028-02-01') -> 'trades') x
   where x ->> 'd' = p_day and x ->> 'side' = p_side;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
select tests.clock('2028-02-28 09:00');
do $$
declare v_n text; v_id uuid;
begin
  foreach v_n in array array['a', 'c', 'd', 'e', 'f', 'g', 'h'] loop
    insert into public.accounts (name, is_test) values ('Test chart fix ' || v_n, true) returning id into v_id;
    insert into k values (v_n, v_id);
  end loop;
end;
$$;
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at, note)
select acct, 'savings', 'deposit', 50000, public.edmonton_at('2028-02-28 10:00'), 'test' from k;

-- The closes as stored (all fetched after 9:00 pm, so final), and the trades that used them.
select tests.clock('2028-03-14 21:30');
select tests.close('tsx', '2028-02-28', 50.00);
select tests.close('dow', '2028-03-02', 500.00);
select tests.close('nasdaq100', '2028-03-06', 648.58);   -- like Nov 5, 2026 (#35)
select tests.close('dow', '2028-03-08', 523.36);         -- like Nov 9, 2026 (#37)
select tests.close('tsx', '2028-03-09', 56.70);
select tests.close('tsx', '2028-03-10', 56.70);
select tests.close('nasdaq100', '2028-03-13', 600.00);
select tests.close('tsx', '2028-03-14', 58.00);
select tests.trade((select acct from k where name = 'a'), 'nasdaq100', '2028-03-06', 'buy', 1000, 0.01541830, 648.58);
select tests.trade((select acct from k where name = 'c'), 'dow', '2028-03-08', 'buy', 1000, 0.01910731, 523.36);
-- d: $20.00 of the TSX fund at $50.00 (0.4 units), then a $10.00 sale at $56.70 (0.17636684 units).
select tests.trade((select acct from k where name = 'd'), 'tsx', '2028-02-28', 'buy', 2000, 0.40000000, 50.00);
select tests.trade((select acct from k where name = 'd'), 'tsx', '2028-03-09', 'sell', 1000, 0.17636684, 56.70, 882);
-- e: $50.00 at $50.00 (1 unit), then all of it sold at $56.70: $56.70.
select tests.trade((select acct from k where name = 'e'), 'tsx', '2028-02-28', 'buy', 5000, 1.00000000, 50.00);
select tests.trade((select acct from k where name = 'e'), 'tsx', '2028-03-10', 'sell', 5670, 1.00000000, 56.70, 5000, true);
-- f: a buy at $600.00 when the right close was $605.00: she already got more units.
select tests.trade((select acct from k where name = 'f'), 'nasdaq100', '2028-03-13', 'buy', 1000, 0.01666667, 600.00);
-- g: 1 unit at $50.00, all sold at $58.00 when the right close was $57.00: she already got more money.
select tests.trade((select acct from k where name = 'g'), 'tsx', '2028-02-28', 'buy', 5000, 1.00000000, 50.00);
select tests.trade((select acct from k where name = 'g'), 'tsx', '2028-03-14', 'sell', 5800, 1.00000000, 58.00, 5000, true);
-- h: a buy at a close that was only ever confirmed, never changed.
select tests.trade((select acct from k where name = 'h'), 'dow', '2028-03-02', 'buy', 1000, 0.02000000, 500.00);
insert into public.fund_price_corrections (fund_id, price_date, old_close, new_close, note, corrected_by)
values ('dow', '2028-03-02', 500.00, 500.00, 'Confirmed', '00000000-0000-0000-0000-00000000000f');

-- Dad fixes the closes.
select tests.clock('2028-03-16 12:00');
select tests.as_parent();
select public.correct_fund_price('nasdaq100', date '2028-03-06', 647.05, 'Official close');
select public.correct_fund_price('dow', date '2028-03-08', 523.33, 'Official close');
select public.correct_fund_price('tsx', date '2028-03-09', 56.75, 'Official close');
select public.correct_fund_price('tsx', date '2028-03-10', 56.75, 'Official close');
select public.correct_fund_price('nasdaq100', date '2028-03-13', 605.00, 'Official close');
select public.correct_fund_price('tsx', date '2028-03-14', 57.00, 'Official close');
create temp table lines_before as select count(*)::int as n from public.transactions;

-- 1. A fixed buy: the fixed close, her units with the added ones, what she paid --------------------------

select is(tests.trade_on('a', 'nasdaq100', '2028-03-06', 'buy'),
  '{"d": "2028-03-06", "side": "buy", "price": 647.05, "units": 0.01545476, "amount_cents": 1000, "fixed": "fixed"}'::jsonb,
  '#35: "You bought $10.00 at $647.05 · price fixed" (0.01541830 + 0.00003646 units)');
select is(tests.trade_on('c', 'dow', '2028-03-08', 'buy'),
  '{"d": "2028-03-08", "side": "buy", "price": 523.33, "units": 0.01910841, "amount_cents": 1000, "fixed": "fixed"}'::jsonb,
  '#37: "You bought $10.00 at $523.33 · price fixed", though the fix was worth less than 1¢');

-- 2. A fixed sale by amount: the units it really used; she got the $10.00 she asked for -----------------

select is(tests.trade_on('d', 'tsx', '2028-03-09', 'sell'),
  '{"d": "2028-03-09", "side": "sell", "price": 56.75, "units": 0.17621145, "amount_cents": 1000, "fixed": "fixed"}'::jsonb,
  '"You sold $10.00 at $56.75 · price fixed" (0.17636684 − 0.00015539 units put back)');
select is(tests.trade_on('d', 'tsx', '2028-02-28', 'buy'),
  '{"d": "2028-02-28", "side": "buy", "price": 50, "units": 0.4, "amount_cents": 2000}'::jsonb,
  'her earlier buy, at a close never fixed: no tag');

-- 3. A fixed sale of everything: the money the fix added, without its interest ---------------------------

select is(tests.trade_on('e', 'tsx', '2028-03-10', 'sell'),
  '{"d": "2028-03-10", "side": "sell", "price": 56.75, "units": 1, "amount_cents": 5675, "fixed": "fixed"}'::jsonb,
  '"You sold $56.75 at $56.75 · price fixed": $56.70 plus the 5¢ missing (the 1¢ of interest isn''t part of the sale)');

-- 4. Fixed, but already in her favour: the price she got ---------------------------------------------

select is(tests.trade_on('f', 'nasdaq100', '2028-03-13', 'buy'),
  '{"d": "2028-03-13", "side": "buy", "price": 600, "units": 0.01666667, "amount_cents": 1000, "fixed": "kept"}'::jsonb,
  'a buy at a close that was too low: "You bought $10.00 at $600.00 · price fixed, you kept the better price"');
select is(tests.trade_on('g', 'tsx', '2028-03-14', 'sell'),
  '{"d": "2028-03-14", "side": "sell", "price": 58, "units": 1, "amount_cents": 5800, "fixed": "kept"}'::jsonb,
  'a sale at a close that was too high: "You sold $58.00 at $58.00 · price fixed, you kept the better price"');
select is((select x -> 'c' from jsonb_array_elements(
             public.fund_chart((select acct from k where name = 'g'), 'tsx', date '2028-02-01') -> 'closes') x
            where x ->> 'd' = '2028-03-14'), '57'::jsonb,
  '...while the graph''s line shows the fixed close');

-- 5. A close only confirmed: no tag -------------------------------------------------------------------

select is(tests.trade_on('h', 'dow', '2028-03-02', 'buy') ->> 'fixed', null,
  'a close confirmed at the same value isn''t a fix: no tag');

-- 6. Read-only, and the ? -----------------------------------------------------------------------------

select is((select count(*)::int from public.transactions), (select n from lines_before),
  'the Graphs tab changes nothing');
select is((select kid_text from public.glossary where term = 'Price fixed'),
  'The price Big Bucks first used for this day was wrong. Mom and Dad fixed it, and you got everything you were owed. Your notice has the details.',
  'the label''s ? explains it');

select * from finish();
rollback;
