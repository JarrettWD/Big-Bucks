-- Buy / Sell reads (stage 7 part 2a): fmt_close, trade_options and move_preview.
begin;
select plan(56);

-- Test helpers ----------------------------------------------------------------

create schema tests;

-- Test closes are stored ahead of the test clock. They count as fetched just after their
-- close, as the real price fetcher only stores a close once the market has closed
-- (settlement uses only final closes: pre-launch audit, 2026-10-08).
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
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb),
           (v_acct, 1, 'parent', v_user, null); -- Dad's countersignature (pre-launch audit)
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
-- The message a statement fails with (null if it succeeds; its effects are rolled back either way).
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ran' using errcode = 'BB999';
exception
  when sqlstate 'BB999' then return null;
  when others then return sqlerrm;
end;
$$;
-- Everything a preview must leave untouched.
create function tests.footprint() returns text language sql as $$
  select concat_ws('/',
    (select count(*) from public.requests), (select count(*) from public.gic_holdings),
    (select count(*) from public.transactions), (select count(*) from public.notifications),
    (select coalesce(sum(held_cents), 0) from public.requests where status = 'pending'),
    (select coalesce(sum(held_units), 0) from public.requests where status = 'pending'),
    (select count(*) from public.gic_holdings where status = 'broken'));
$$;
create function tests.preview(p_kind text, p_amount bigint default null, p_fund text default null,
                              p_gic bigint default null, p_term int default null, p_all boolean default false)
returns jsonb language sql as $$
  select public.move_preview(p_kind, p_amount, p_fund, p_gic, p_term, p_all);
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Prices: flat on every weekday in September and Oct 1, then the Dow drops to 380 on Oct 2.
insert into public.fund_prices (fund_id, price_date, close)
select f.fund_id, d::date, f.flat
  from (values ('dow', 400.0), ('nasdaq100', 500.0), ('tsx', 40.0)) f(fund_id, flat)
 cross join generate_series(date '2026-09-01', date '2026-10-01', interval '1 day') d
 where extract(isodow from d) < 6;
insert into public.fund_prices (fund_id, price_date, close) values
  ('dow', '2026-10-02', 380), ('nasdaq100', '2026-10-02', 500), ('tsx', '2026-10-02', 40);

-- Kid A: $800 in; buys $500 of the Dow (1.25 units at 400) and a $100 1-year GIC on Oct 1.
-- Kid B (a test account): $50 in and a $10 1-month GIC.
select tests.clock('2026-10-01 08:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.fund('kid_a', 80000);
select tests.fund('kid_b', 5000);
select tests.clock('2026-10-01 09:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'buy', 50000, false);
select public.buy_gic(10000, 12);
select tests.as_kid('kid_b');
select public.buy_gic(1000, 1);
select tests.nobody();
select tests.clock('2026-10-01 16:30');
select public.settle_trades('2026-10-01');

-- 1. fmt_close: when a trade settles, in words ------------------------------------------------

select tests.clock('2026-10-02 18:00');   -- Friday evening
select is(public.fmt_close(public.next_settlement('dow')), 'Monday''s 2:00 pm close (Oct 5)',
  'a Friday-evening trade settles at Monday''s close (2:00 pm in Alberta in summer)');
select is(public.fmt_close(timestamptz '2026-10-02 20:00+00'), 'today''s 2:00 pm close',
  'a close earlier today is "today''s"');
select tests.clock('2026-10-03 10:00');
select is(public.fmt_close(timestamptz '2026-10-02 20:00+00'), 'yesterday''s 2:00 pm close',
  'and yesterday''s close is "yesterday''s"');
select tests.clock('2026-10-05 15:00');   -- Monday, after the close
select is(public.fmt_close(public.next_settlement('dow')), 'tomorrow''s 2:00 pm close',
  'after the close, the next one is tomorrow''s');
select tests.clock('2026-10-09 18:00');   -- Friday before Canadian Thanksgiving
select is(public.fmt_close(public.next_settlement('tsx')), 'Tuesday''s 2:00 pm close (Oct 13)',
  'the TSX is closed on Thanksgiving Monday, so a TSX trade waits for Tuesday');
select is(public.fmt_close(public.next_settlement('dow')), 'Monday''s 2:00 pm close (Oct 12)',
  'while the US markets are open that Monday');
select tests.clock('2026-11-02 09:00');   -- the first Monday on Alberta's all-year time
select is(public.fmt_close(public.next_settlement('dow')), 'today''s 3:00 pm close',
  'from November, the 4:00 pm Toronto close is 3:00 pm in Alberta');
select tests.clock('2026-11-26 10:00');   -- US Thanksgiving; the next day closes early
select is(public.fmt_close(public.next_settlement('dow')), 'tomorrow''s 12:00 pm close',
  'an early close (1:00 pm in Toronto) is 12:00 pm in Alberta in winter');

-- 2. trade_options ------------------------------------------------------------------------------

select tests.clock('2026-10-05 09:00');   -- Monday morning; the Dow's latest close is 380
select tests.as_kid('kid_a');

select results_eq(
  $$select (o ->> 'savings_cents')::bigint, (o ->> 'available_cents')::bigint, (o ->> 'cap_room_cents')::bigint,
           (o ->> 'today')::date, (o ->> 'updating')::boolean
      from public.trade_options(tests.acct('kid_a')) o$$,
  $$values (20000::bigint, 20000::bigint, 20000::bigint, date '2026-10-05', false)$$,
  'savings $200.00, all free to use; $200.00 of room under the $1,000 cap ($800 deposited)');
select results_eq(
  $$select f ->> 'fund_id', (f ->> 'units')::numeric, (f ->> 'value_cents')::bigint, (f ->> 'cost_cents')::bigint,
           (f ->> 'gain_cents')::bigint, (f ->> 'sellable_cents')::bigint, (f ->> 'traded_today')::boolean
      from jsonb_array_elements(public.trade_options(tests.acct('kid_a')) -> 'funds') f$$,
  $$values ('dow'::text, 1.25::numeric, 47500::bigint, 50000::bigint, -2500::bigint, 47500::bigint, false),
           ('nasdaq100', 0, 0, 0, 0, 0, false),
           ('tsx', 0, 0, 0, 0, 0, false)$$,
  'each fund, owned or not: units, value at 380, what she paid, gain, what she can sell, traded today');
select is(public.trade_options(tests.acct('kid_a')) -> 'funds' -> 0 ->> 'settles', 'today''s 2:00 pm close',
  'each fund says when a trade made now would settle');
select results_eq(
  $$select (g ->> 'term_months')::int, (g ->> 'balance_cents')::bigint, (g ->> 'interest_so_far_cents')::bigint,
           (g ->> 'interest_at_maturity_cents')::bigint, (g ->> 'maturity_date')::date, (g ->> 'can_break')::boolean
      from jsonb_array_elements(public.trade_options(tests.acct('kid_a')) -> 'gics') g$$,
  $$values (12, 10000::bigint, 6::bigint, 500::bigint, date '2027-10-01', true)$$,
  'her GIC, and what breaking it today gives up: $5.00 × 4/365 days = $0.0548, rounded up to $0.06');
select is(jsonb_array_length(public.trade_options(tests.acct('kid_a')) -> 'gic_rates'), 6, 'all six GIC rates');
select is((public.trade_options(tests.acct('kid_a')) -> 'gic_rates' -> 4 ->> 'rate')::numeric, 5.0,
  'the 1-year rate is 5.0%');
select is(public.trade_options(tests.acct('kid_a')) -> 'waiting', '[]'::jsonb, 'nothing waiting yet');

-- 3. move_preview: the same answers as the real actions --------------------------------------

create temp table before_previews as select tests.footprint() as f;

select is(tests.preview('deposit', 400) ->> 'problem', 'The smallest deposit is $5.00.',
  'deposit under $5: the deposit minimum');
select is(tests.preview('deposit', 400) ->> 'problem', tests.err('select public.request_deposit(400)'),
  'word for word what request_deposit says');
select is(tests.preview('deposit', 20001) ->> 'problem',
  'That''s over your deposit limit. You can put in up to $200.00 more.', 'over the deposit room');
select is(tests.preview('deposit', 20001) ->> 'problem', tests.err('select public.request_deposit(20001)'),
  'the same as the real deposit');
select is(tests.preview('deposit', 5000), '{"kind": "deposit", "problem": null, "settles": null, "warnings": [{"code": "deposit_wait"}], "gic_quotes": []}'::jsonb,
  'a deposit that fits: no problem, and a reminder that Dad approves it');

select is(tests.preview('withdraw', 20001) ->> 'problem', 'You have $200.00 available to take out.',
  'withdrawing more than is free to use');
select is(tests.preview('withdraw', 20001) ->> 'problem', tests.err('select public.request_withdrawal(20001)'),
  'the same as the real withdrawal');
select is(tests.preview('withdraw', 5000) -> 'warnings',
  '[{"code": "withdraw_wait", "approve_from": "Oct 6 at 9:00 am"}]'::jsonb,
  'a withdrawal: Dad can approve it from 24 hours later');

select is(tests.preview('buy_gic', 999) ->> 'problem', 'The smallest GIC is $10.00.', 'GIC under $10');
select is(tests.preview('buy_gic', 999) ->> 'problem', tests.err('select public.buy_gic(999, 12)'),
  'the same as the real GIC purchase');
select is(tests.preview('buy_gic', 10000, p_term => 7) ->> 'problem',
  'A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.', 'a term that doesn''t exist');
select is(tests.preview('buy_gic', 20001) ->> 'problem', 'You have $200.00 available.',
  'more than is free, before a term is chosen');
select ok(tests.preview('buy_gic', 10000) -> 'problem' = 'null'::jsonb, 'a $100 GIC is fine, before a term is chosen');
select results_eq(
  $$select (q ->> 'term_months')::int, (q ->> 'interest_cents')::bigint, (q ->> 'maturity_date')::date
      from jsonb_array_elements(tests.preview('buy_gic', 10000) -> 'gic_quotes') q$$,
  $$values (1, 21::bigint, date '2026-11-05'), (3, 75::bigint, date '2027-01-05'), (6, 200::bigint, date '2027-04-05'),
           (9, 338::bigint, date '2027-07-05'), (12, 500::bigint, date '2027-10-05'), (24, 1200::bigint, date '2028-10-05')$$,
  'what $100 earns at each term: 1 month $0.21 (0.2083 rounded up), 9 months $3.38 (3.375 rounded up), 1 year $5.00, 2 years $12.00');

select ok(tests.preview('break_gic', p_gic => (select id from public.gic_holdings where account_id = tests.acct('kid_a')))
          -> 'problem' = 'null'::jsonb, 'breaking her GIC is allowed');
select is(tests.preview('break_gic', p_gic => (select id from public.gic_holdings where account_id = tests.acct('kid_a')))
          -> 'warnings',
  '[{"code": "early_break", "lost_cents": 6, "back_cents": 10000, "maturity_date": "2027-10-01", "at_maturity_cents": 500}]'::jsonb,
  'the early-break warning: $0.06 earned so far is given up, $100.00 comes back, $5.00 if she waits');
select is(tests.preview('break_gic', p_gic => (select id from public.gic_holdings where account_id = tests.acct('kid_b')))
          ->> 'problem', 'That GIC isn''t yours.', 'another kid''s GIC: refused, with the real message');
select is(tests.preview('break_gic', p_gic => (select id from public.gic_holdings where account_id = tests.acct('kid_b')))
          -> 'warnings', '[]'::jsonb, 'and nothing about that GIC is shown');

select is(tests.preview('buy_fund', 20001, 'dow') ->> 'problem', 'You have $200.00 available.', 'fund buy over what''s free');
select is(tests.preview('buy_fund', 999, 'dow') ->> 'problem', 'The smallest trade is $10.00.', 'fund buy under $10');
select is(tests.preview('buy_fund', 1000, 'nasdaq100'),
  '{"kind": "buy_fund", "problem": null, "settles": "today''s 2:00 pm close", "warnings": [{"code": "market_price", "settles": "today''s 2:00 pm close"}], "gic_quotes": []}'::jsonb,
  'a fund buy that''s fine: it settles at today''s close, at a price nobody knows yet');
select is(tests.preview('sell_fund', 50000, 'dow') ->> 'problem',
  'Your Dow Jones units are worth about $475.00, so you can sell up to that (or choose "sell all").',
  'selling more than her units are worth');
select is(tests.preview('sell_fund', 50000, 'dow') ->> 'problem',
  tests.err($$select public.request_trade('dow', 'sell', 50000, false)$$), 'the same as the real sale');
select is(tests.preview('sell_fund', 1000, 'tsx') ->> 'problem', 'You don''t have any TSX units to sell.',
  'selling a fund she doesn''t own');
select is(tests.preview('sell_fund', 5000, 'dow', p_all => true) ->> 'problem', null,
  '"sell all" ignores any amount the screen still had');
select is(tests.preview('sell_fund', null, 'dow', p_all => true) -> 'warnings' -> 1,
  '{"code": "fund_below_cost", "loss_cents": 2500, "cost_cents": 50000, "value_cents": 47500}'::jsonb,
  'selling below what she paid: worth $475.00, paid $500.00');
select is(jsonb_array_length(tests.preview('buy_fund', 1000, 'dow') -> 'warnings'), 1,
  'buying a fund that''s down doesn''t get the "worth less than you paid" warning');

select is(tests.footprint(), (select f from before_previews),
  'no preview left anything behind: no request, hold, GIC, ledger line, notice or broken GIC');

-- 4. After real actions: traded today, and waiting requests ------------------------------------

select public.request_trade('dow', 'buy', 1000, false);
select public.request_withdrawal(5000);
select ok((public.trade_options(tests.acct('kid_a')) -> 'funds' -> 0 ->> 'traded_today')::boolean,
  'after a Dow trade, the Dow shows "traded today"');
select is(tests.preview('buy_fund', 1000, 'dow') ->> 'problem',
  'You''ve already traded the Dow Jones fund today. You can trade it again tomorrow.',
  'and a second Dow trade is refused with the real message');
select is((public.trade_options(tests.acct('kid_a')) ->> 'available_cents')::bigint, 14000::bigint,
  'both requests hold their money: $200.00 − $10.00 − $50.00 = $140.00 free');
select results_eq(
  $$select w ->> 'type', w ->> 'fund_id', (w ->> 'amount_cents')::bigint, w ->> 'settles', w ->> 'approve_from',
           (w ->> 'on_day')::date
      from jsonb_array_elements(public.trade_options(tests.acct('kid_a')) -> 'waiting') w$$,
  $$values ('move'::text, 'dow'::text, 1000::bigint, 'today''s 2:00 pm close'::text, null::text, date '2026-10-05'),
           ('withdraw', null, 5000, null, 'Oct 6 at 9:00 am', date '2026-10-05')$$,
  'her waiting requests, oldest first: when the trade settles, and when Dad can approve the withdrawal');
select tests.nobody();
select tests.clock('2026-10-06 10:00');
select tests.as_kid('kid_a');
select is(public.trade_options(tests.acct('kid_a')) -> 'waiting' -> 1 ->> 'approve_from', null,
  'once the 24 hours have passed, the withdrawal just waits for Dad');

-- 5. Who may call them ------------------------------------------------------------------------------

select tests.as_kid('kid_b');
select throws_ok($$select public.trade_options(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'kid B can''t see kid A''s options');
select tests.as_parent('aal1');
select throws_ok($$select public.trade_options(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'nor can a parent without the authenticator code');
select tests.as_parent('aal2');
select lives_ok($$select public.trade_options(tests.acct('kid_a'))$$, 'a parent with the code can');
select throws_ok($$select public.move_preview('deposit', 5000)$$, '42501', 'Only a kid''s account can do this.',
  'previews are for kids only');
select tests.as_kid('kid_a');
select throws_ok($$select public.move_preview('lend', 5000)$$, 'Choose what to do first.', 'an unknown kind of move');
select tests.nobody();
select ok(not has_function_privilege('anon', 'public.trade_options(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.move_preview(text, bigint, text, bigint, integer, boolean)', 'execute'),
  'signed-out visitors can call neither');
select ok(has_function_privilege('authenticated', 'public.move_preview(text, bigint, text, bigint, integer, boolean)', 'execute')
          and not has_function_privilege('service_role', 'public.move_preview(text, bigint, text, bigint, integer, boolean)', 'execute'),
  'move_preview: signed-in users only (it checks for a kid itself)');
select ok(not has_function_privilege('authenticated', 'public.fmt_close(timestamptz)', 'execute'),
  'fmt_close is internal');

select * from finish();
rollback;
