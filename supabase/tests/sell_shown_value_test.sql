-- Selling a fund by typing what it's shown to be worth (Dad's decision, stage 7 2b review).
--
-- Her units' value is shown rounded to the nearest cent. Typing that amount (or
-- more, up to the exact value, when that is a fraction of a cent higher) sells all
-- of her units; more than that is refused, quoting the shown value. Sell all pays units × the close,
-- rounded up, so at the same price it pays at least the shown value. If the price
-- falls before the close, it pays less: that's the market, and a test says so.
begin;
select plan(21);

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
create function tests.new_kid(p_username text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
  v_req bigint;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb),
           (v_acct, 1, 'parent', v_user, null); -- Dad's countersignature (pre-launch audit)
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(10000);
  perform tests.as_user('00000000-0000-0000-0000-00000000000f', 'aal2');
  perform public.approve_request(v_req);
  perform tests.as_kid(p_username);
  perform public.request_trade('tsx', 'buy', 6000, false);
  perform tests.nobody();
  return v_acct;
end;
$$;
-- Her latest TSX sale request.
create function tests.sale(p_username text) returns public.requests language sql as $$
  select * from public.requests where account_id = tests.acct(p_username) and from_vehicle = 'stock'
   order by id desc limit 1;
$$;
create function tests.proceeds(p_username text) returns bigint language sql as $$
  select amount_cents from public.transactions
   where account_id = tests.acct(p_username) and vehicle = 'savings' and fund_id = 'tsx' and type = 'transfer_in'
   order by id desc limit 1;
$$;
create function tests.units(p_username text) returns numeric language sql as $$
  select public.fund_units(tests.acct(p_username), 'tsx');
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- TSX closes: bought at 41.13, then 39.27 (Oct 2 and 5), 39.20 (Oct 6 and 7), 38.00 (Oct 8).
insert into public.fund_prices (fund_id, price_date, close) values
  ('tsx', '2026-09-30', 41.13), ('tsx', '2026-10-01', 41.13), ('tsx', '2026-10-02', 39.27),
  ('tsx', '2026-10-05', 39.27), ('tsx', '2026-10-06', 39.20), ('tsx', '2026-10-07', 39.20),
  ('tsx', '2026-10-08', 38.00);

-- Six kids each buy $60.00 of the TSX on Oct 1: 60 ÷ 41.13 = 1.45878921 units (rounded up).
select tests.clock('2026-10-01 09:00');
select tests.new_kid(k) from unnest(array['kid_a', 'kid_b', 'kid_c', 'kid_d', 'kid_e', 'kid_f']) k;
select tests.clock('2026-10-01 16:30');
select public.settle_trades('2026-10-01');
select is(tests.units('kid_a'), 1.45878921, 'each kid holds 1.45878921 units');

-- 1. At 39.27: worth 1.45878921 × 39.27 = $57.2866…, shown as $57.29 ---------------------------------

select tests.clock('2026-10-05 09:00');
select tests.as_kid('kid_d');
select is((public.trade_options(tests.acct('kid_d')) -> 'funds' -> 2 ->> 'sellable_cents')::bigint, 5729::bigint,
  'Buy / Sell shows her TSX worth $57.29 (to the nearest cent), the same as Home');
select is((select value_cents from public.fund_positions where account_id = tests.acct('kid_d') and fund_id = 'tsx'),
  5729::bigint, 'and Home''s value is $57.29');
select is(public.move_preview('sell_fund', 5729, 'tsx') ->> 'problem', null, 'typing $57.29: no problem');
select ok(public.move_preview('sell_fund', 5729, 'tsx') -> 'warnings' @> '[{"code": "sells_all"}]',
  'and the preview says it sells all of it');
select ok(not public.move_preview('sell_fund', 5728, 'tsx') -> 'warnings' @> '[{"code": "sells_all"}]',
  'typing $57.28 doesn''t');

select tests.as_kid('kid_a');
select public.request_trade('tsx', 'sell', 5729, false);
select results_eq($$select sell_all, amount_cents, held_units from tests.sale('kid_a')$$,
  $$values (true, null::bigint, 1.45878921::numeric)$$,
  'kid A types the shown $57.29: it becomes "sell all", holding every unit');

select tests.as_kid('kid_b');
select public.request_trade('tsx', 'sell', 5728, false);
select results_eq($$select sell_all, amount_cents from tests.sale('kid_b')$$,
  $$values (false, 5728::bigint)$$, 'kid B types $57.28 (a cent under): a normal sale by amount');

select tests.as_kid('kid_c');
select throws_ok($$select public.request_trade('tsx', 'sell', 5730, false)$$,
  'Your TSX units are worth about $57.29, so you can sell up to that (or choose "sell all").',
  'kid C types $57.30 (more than the shown $57.29): refused, quoting it');

select tests.nobody();
select tests.clock('2026-10-05 16:30');
select public.settle_trades('2026-10-05');
select is(tests.proceeds('kid_a'), 5729::bigint,
  'at the same price, kid A''s sale pays $57.29: 1.45878921 × $39.27 = $57.2866, rounded up');
select is(tests.units('kid_a'), 0::numeric, 'and she has no units left over');
select ok(tests.units('kid_b') > 0, 'kid B, selling by amount, keeps a sliver of units');

-- 2. At 39.20: worth $57.1845…, shown as $57.18 ----------------------------------------------------------

select tests.clock('2026-10-07 09:00');
select tests.as_kid('kid_d');
select throws_ok($$select public.request_trade('tsx', 'sell', 5719, false)$$,
  'Your TSX units are worth about $57.18, so you can sell up to that (or choose "sell all").',
  'kid D types $57.19 (over the exact $57.1845): refused, quoting the shown $57.18');
select public.request_trade('tsx', 'sell', 5718, false);
select is((tests.sale('kid_d')).sell_all, true, 'then types the shown $57.18: sells all');
select tests.as_kid('kid_e');
select public.request_trade('tsx', 'sell', 5717, false);
select is((tests.sale('kid_e')).sell_all, false, 'kid E types $57.17 (a cent under): a sale by amount');
select tests.nobody();
select tests.clock('2026-10-07 16:30');
select public.settle_trades('2026-10-07');
select is(tests.proceeds('kid_d'), 5719::bigint,
  'at the same price, selling all pays $57.19: 1.45878921 × $39.20 = $57.1845, rounded up, a cent more than shown');
select ok(tests.proceeds('kid_d') >= 5718, 'so selling all never pays less than the shown value at the same price');

-- 3. If the price falls before the close, selling all pays less than was shown ------------------------

select tests.clock('2026-10-08 09:00');
select tests.as_kid('kid_f');
select public.request_trade('tsx', 'sell', null, true);
select tests.nobody();
select tests.clock('2026-10-08 16:30');
select public.settle_trades('2026-10-08');
select is(tests.proceeds('kid_f'), 5544::bigint,
  'shown $57.18 in the morning, the close fell to $38.00: she gets 1.45878921 × $38.00 = $55.434, rounded up to $55.44');

-- 4. The rule itself ----------------------------------------------------------------------------------

select results_eq(
  $$select public.sell_amount_is_all(1.45878921, 39.27, a) from unnest(array[5728, 5729, 5730]::bigint[]) a$$,
  $$values (false), (true), (false)$$,
  'sell_amount_is_all, worth $57.2866: only the shown $57.29 (above the exact value, but it''s what she sees)');
select results_eq(
  $$select public.sell_amount_is_all(1.45878921, 39.20, a) from unnest(array[5717, 5718, 5719]::bigint[]) a$$,
  $$values (false), (true), (false)$$,
  'sell_amount_is_all, worth $57.1845: only the shown $57.18');
select results_eq(
  $$select public.sell_amount_is_all(2, 50, a) from unnest(array[9999, 10000, 10001]::bigint[]) a$$,
  $$values (false), (true), (false)$$,
  'worth exactly $100.00: only $100.00');

select * from finish();
rollback;
