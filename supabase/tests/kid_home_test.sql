-- Kid Home reads (stage 7): fund_overview, my_activity, current_rates, mark_notices_read,
-- and the reworded "Daily change" glossary entry.
begin;
select plan(42);

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
-- Her activity, as a list of kinds (newest first).
create function tests.kinds(p_username text, p_limit int default 50) returns text[] language sql as $$
  select array_agg(a.kind order by a.at desc, a.item_key desc)
    from public.my_activity(tests.acct(p_username), p_limit) a;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Prices: every weekday Aug 17 – Sep 30 flat, then Oct 1 and Oct 2 known closes.
--   Dow 400 → 410 (+2.50%), Nasdaq-100 500 → 490 (−2.00%), TSX 40 → 40.40 (+1.00%).
insert into public.fund_prices (fund_id, price_date, close)
select f.fund_id, d::date, f.flat
  from (values ('dow', 400.0), ('nasdaq100', 500.0), ('tsx', 40.0)) f(fund_id, flat)
 cross join generate_series(date '2026-08-17', date '2026-09-30', interval '1 day') d
 where extract(isodow from d) < 6;
insert into public.fund_prices (fund_id, price_date, close) values
  ('dow', '2026-10-01', 400), ('nasdaq100', '2026-10-01', 500), ('tsx', '2026-10-01', 40),
  ('dow', '2026-10-02', 410), ('nasdaq100', '2026-10-02', 490), ('tsx', '2026-10-02', 40.4);

-- Kid A: $1,500 in (Dad raises the cap first); buys three funds and a 12-month GIC on Oct 1 ---
select tests.clock('2026-10-01 07:00');
select tests.as_parent();
select public.set_setting('deposit_cap_cents', '200000');
select tests.nobody();
select tests.clock('2026-10-01 08:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.fund('kid_a', 150000);

select tests.clock('2026-10-01 09:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'buy', 50000, false);       -- 1.25 units at 400
select public.request_trade('nasdaq100', 'buy', 30000, false); -- 0.6 units at 500
select public.request_trade('tsx', 'buy', 20000, false);       -- 5 units at 40
select public.buy_gic(10000, 12);                              -- $100 at 5.0%
select tests.nobody();
select tests.clock('2026-10-01 15:30');
select public.settle_trades('2026-10-01');

-- Oct 2: sells $101 of the TSX (2.5 units at 40.40), then a withdrawal and a deposit Dad declines.
select tests.clock('2026-10-02 09:00');
select tests.as_kid('kid_a');
select public.request_trade('tsx', 'sell', 10100, false);
select tests.nobody();
select tests.clock('2026-10-02 15:30');
select public.settle_trades('2026-10-02');
select tests.clock('2026-10-02 16:00');
select tests.as_kid('kid_a');
select public.request_withdrawal(5000);
select public.request_deposit(20000);
select tests.as_parent();
select tests.clock('2026-10-02 16:10');
select public.decline_request(
  (select id from public.requests where account_id = tests.acct('kid_a') and type = 'deposit' and status = 'pending'),
  'Not this week.');
select tests.nobody();

select tests.clock('2026-10-05 09:00');   -- Monday: the latest close is Friday Oct 2

-- 1. fund_overview ----------------------------------------------------------------------------

select tests.as_kid('kid_a');
select results_eq(
  $$select fund_id, owned, units, value_cents, day_change_pct, mix_pct
      from public.fund_overview(tests.acct('kid_a')) order by sort_order$$,
  $$values ('dow', true, 1.25::numeric, 51250::bigint, 2.50::numeric, 57),
           ('nasdaq100', true, 0.6::numeric, 29400::bigint, -2.00::numeric, 32),
           ('tsx', true, 2.5::numeric, 10100::bigint, 1.00::numeric, 11)$$,
  'each fund: units, value at the latest close, the fund''s daily change, and her mix in whole percents');
select is((select sum(mix_pct) from public.fund_overview(tests.acct('kid_a'))), 100::bigint,
  'the mix adds up to exactly 100% (largest remainder: 56.47 → 57, 32.40 → 32, 11.13 → 11)');
select results_eq(
  $$select name, colour, latest_close, previous_close, latest_close_date
      from public.fund_overview(tests.acct('kid_a')) where fund_id = 'dow'$$,
  $$values ('Dow Jones'::text, '#2F80ED'::text, 410::numeric, 400::numeric, date '2026-10-02')$$,
  'it carries the fund''s name, colour and the two closes behind the daily change');
select results_eq(
  $$select gain_cents, cost_cents from public.fund_overview(tests.acct('kid_a')) where fund_id = 'dow'$$,
  $$values (1250::bigint, 50000::bigint)$$,
  'and her gain since she bought (value − what she paid)');
select is((select jsonb_array_length(spark) from public.fund_overview(tests.acct('kid_a')) where fund_id = 'dow'), 30,
  'the sparkline has the last 30 closes');
select is((select spark -> 29 from public.fund_overview(tests.acct('kid_a')) where fund_id = 'dow'),
  '{"d": "2026-10-02", "c": 410}'::jsonb, 'oldest first, ending with the latest close');
select is((select spark -> 0 ->> 'd' from public.fund_overview(tests.acct('kid_a')) where fund_id = 'dow'),
  '2026-08-24', 'starting 30 market days back');

select tests.as_kid('kid_b');
select results_eq(
  $$select fund_id, owned, units, value_cents, mix_pct, day_change_pct
      from public.fund_overview(tests.acct('kid_b')) order by sort_order$$,
  $$values ('dow', false, 0::numeric, 0::bigint, null::int, 2.50::numeric),
           ('nasdaq100', false, 0::numeric, 0::bigint, null::int, -2.00::numeric),
           ('tsx', false, 0::numeric, 0::bigint, null::int, 1.00::numeric)$$,
  'a kid with no funds still sees all three funds and how they moved (no mix)');
select is((select jsonb_array_length(spark) from public.fund_overview(tests.acct('kid_b')) where fund_id = 'tsx'), 30,
  'and their sparklines');

-- No prices in the future: a close dated after today isn't shown.
select tests.clock('2026-10-01 20:00');
select is((select latest_close_date from public.fund_overview(tests.acct('kid_b')) where fund_id = 'dow'),
  date '2026-10-01', 'only closes up to today count');
select is((select day_change_pct from public.fund_overview(tests.acct('kid_b')) where fund_id = 'dow'),
  0.00::numeric, 'the daily change uses the two latest closes up to today (flat that day)');
select tests.clock('2026-10-05 09:00');

-- 2. my_activity ------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select is(tests.kinds('kid_a'),
  array['request_declined', 'request_pending', 'fund_sell', 'fund_buy', 'fund_buy', 'fund_buy', 'gic_buy', 'deposit'],
  'her history, newest first: each move is one line, plus her pending and declined requests');
select is(
  (select count(*) from public.transactions where account_id = tests.acct('kid_a')), 11::bigint,
  '(11 ledger rows behind those 6 ledger lines)');
select results_eq(
  $$select amount_cents, gic_term, rate, array_length(transaction_ids, 1)
      from public.my_activity(tests.acct('kid_a'), 50) where kind = 'gic_buy'$$,
  $$values (10000::bigint, 12, 5.000::numeric, 2)$$,
  'a GIC purchase: one line with its amount, term and locked rate, and both ledger rows behind it');
select results_eq(
  $$select fund_id, amount_cents, units, unit_price from public.my_activity(tests.acct('kid_a'), 50)
     where kind = 'fund_buy' order by fund_id$$,
  $$values ('dow'::text, 50000::bigint, 1.25::numeric, 400::numeric),
           ('nasdaq100', 30000, 0.6, 500),
           ('tsx', 20000, 5, 40)$$,
  'fund buys: what she paid, the units and the price');
select results_eq(
  $$select fund_id, amount_cents, units, unit_price from public.my_activity(tests.acct('kid_a'), 50)
     where kind = 'fund_sell'$$,
  $$values ('tsx'::text, 10100::bigint, 2.5::numeric, 40.4::numeric)$$,
  'a fund sale: what she got, the units sold and the price');
select results_eq(
  $$select amount_cents, request_type, note from public.my_activity(tests.acct('kid_a'), 50)
     where kind in ('deposit', 'request_pending', 'request_declined') order by at$$,
  $$values (150000::bigint, null::text, null::text),
           (5000, 'withdraw', null),
           (20000, 'deposit', 'Not this week.')$$,
  'the deposit, the waiting withdrawal, and the declined deposit with Dad''s reason');
select is(
  (select at from public.my_activity(tests.acct('kid_a'), 50) where kind = 'fund_sell'),
  '2026-10-02 14:00 America/Edmonton'::timestamptz,
  'a trade is dated at the close it settled at');

-- Paging: 3 at a time, then the rest after the 3rd.
select is(array_length(tests.kinds('kid_a', 3), 1), 3, 'a limit gives the newest few (Home shows 5)');
select is(
  (select array_agg(a.kind order by a.at desc, a.item_key desc)
     from public.my_activity(tests.acct('kid_a'), 50,
            (select at from public.my_activity(tests.acct('kid_a'), 3) order by at, item_key limit 1),
            (select item_key from public.my_activity(tests.acct('kid_a'), 3) order by at, item_key limit 1)) a),
  array['fund_buy', 'fund_buy', 'fund_buy', 'gic_buy', 'deposit'],
  '"See all" continues after the last line it showed, with nothing repeated or missed');

select tests.as_kid('kid_b');
select is(tests.kinds('kid_b'), null::text[], 'a kid with no history has an empty list');

-- 3. Only her own account ------------------------------------------------------------------------

select tests.as_kid('kid_b');
select throws_ok($$select * from public.fund_overview(tests.acct('kid_a'))$$, '42501', null,
  'kid B cannot see kid A''s funds');
select throws_ok($$select * from public.my_activity(tests.acct('kid_a'))$$, '42501', null,
  'kid B cannot see kid A''s history');
select throws_ok($$select * from public.my_activity(null)$$, '42501', null, 'an empty account id is refused');
select tests.as_parent('aal1');
select throws_ok($$select * from public.my_activity(tests.acct('kid_a'))$$, '42501', null,
  'a parent without the authenticator code is refused');
select tests.as_parent();
select is(array_length(tests.kinds('kid_a'), 1), 8, 'the parent with the code can read it');

-- 4. current_rates ------------------------------------------------------------------------------------

select tests.as_parent();
select public.add_rate('savings', null, 1.5, '2026-10-12', 'Rates are coming down.');
select public.add_rate('gic', 1, 3.5, '2026-10-05', 'Fall special!', '2026-10-31');
select tests.as_kid('kid_a');
select results_eq(
  $$select vehicle::text, gic_term, rate, is_special, special_ends, next_rate, next_effective
      from public.current_rates() with ordinality as r order by r.ordinality$$,
  $$values ('savings', null::int, 2.000::numeric, false, null::date, 1.500::numeric, date '2026-10-12'),
           ('gic', 1, 3.500, true, date '2026-10-31', null, null),
           ('gic', 3, 3.000, false, null, null, null),
           ('gic', 6, 4.000, false, null, null, null),
           ('gic', 9, 4.500, false, null, null, null),
           ('gic', 12, 5.000, false, null, null, null),
           ('gic', 24, 6.000, false, null, null, null)$$,
  'today''s rates: a special wins inside its dates, and an announced change shows with its date');
select is((select count(*) from public.current_rates()), 7::bigint, 'savings and all six GIC terms');

-- 5. mark_notices_read ---------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select ok((select count(*) from public.notifications where account_id = tests.acct('kid_a') and read_at is null) >= 3,
  'kid A has unread notices (approved, declined, rate change…)');
create temp table a_notices as select id from public.notifications where account_id = tests.acct('kid_a');

select tests.as_kid('kid_b');
select is(public.mark_notices_read(array(select id from a_notices)), 0,
  'kid B cannot mark kid A''s notices as read');
select tests.as_kid('kid_a');
select is((select count(*) from public.notifications where account_id = tests.acct('kid_a') and read_at is null),
  (select count(*) from a_notices), 'so they are all still unread');

select is(public.mark_notices_read(array(select id from a_notices order by id limit 2)), 2, 'kid A marks two as read');
select is((select read_at from public.notifications where id = (select min(id) from a_notices)),
  '2026-10-05 09:00 America/Edmonton'::timestamptz, 'stamped with the app clock');
select is(public.mark_notices_read(array(select id from a_notices order by id limit 2)), 0,
  'marking them again changes nothing');
select is((select read_at from public.notifications where id = (select min(id) from a_notices)),
  '2026-10-05 09:00 America/Edmonton'::timestamptz, 'and keeps the first time she read it');
select is(public.mark_notices_read('{}'), 0, 'an empty list is fine');

select tests.as_parent();
select throws_ok($$select public.mark_notices_read(array[1::bigint])$$, '42501', null,
  'only a kid marks her own notices (Dad sees whether she has read them)');

-- 6. Grants and safety net -----------------------------------------------------------------------------

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('fund_overview', 'my_activity', 'current_rates', 'mark_notices_read')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE') order by 1),
  array['current_rates', 'fund_overview', 'mark_notices_read', 'my_activity'],
  'signed-in users can call the four (each checks who is calling)');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('fund_overview', 'my_activity', 'current_rates', 'mark_notices_read')
           and has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'anonymous callers cannot');
select ok(
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('fund_overview', 'my_activity', 'mark_notices_read')),
  'the three that touch her account are SECURITY DEFINER with a fixed search_path');

-- 7. The reworded glossary entry -------------------------------------------------------------------------

select is((select kid_text from public.glossary where term = 'Daily change'),
  'How much a fund went up or down since the market''s last day, as a percent. Markets go up and down all the time, and one day doesn''t matter much. What counts is how it does over months and years.',
  'the "Daily change" explanation says one day doesn''t matter much');
select is((select count(*) from public.glossary), 52::bigint, 'still 52 glossary terms');

select * from finish();
rollback;
