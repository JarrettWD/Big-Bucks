-- Engine security (who may call what) and the read views and functions (stage 2).
begin;
select plan(38);

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
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
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


select tests.clock('2026-10-05 09:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);   -- a test account
select tests.fund('kid_a', 10000);
select tests.fund('kid_b', 20000);
select tests.as_kid('kid_b');
select public.buy_gic(5000, 12);
select tests.nobody();

-- 1. Who may call what ------------------------------------------------------------

create function tests.fn_privs(p_role text, p_names text[]) returns text[] language sql as $$
  select coalesce(array_agg(p.proname::text order by 1), '{}')
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = any (p_names)
     and has_function_privilege(p_role, p.oid, 'EXECUTE');
$$;

select is(tests.fn_privs('authenticated', array['expire_requests', 'accrue_savings_interest', 'post_monthly_interest',
    'mature_gics', 'auto_move_unclaimed_maturities', 'settle_trades', 'pay_quarterly_dividends', 'apply_split',
    'write_market_move_notes', 'send_rate_notices', 'run_daily']),
  '{}'::text[], 'signed-in users (kids and Dad) cannot run the daily jobs');
select is(array_length(tests.fn_privs('service_role', array['expire_requests', 'accrue_savings_interest', 'post_monthly_interest',
    'mature_gics', 'auto_move_unclaimed_maturities', 'settle_trades', 'pay_quarterly_dividends', 'apply_split',
    'write_market_move_notes', 'send_rate_notices', 'run_daily']), 1),
  11, 'the server (service role) can run all eleven');
select is(tests.fn_privs('authenticated', array['notify', 'next_close', 'kid_account', 'require_parent', 'vehicle_cents', 'held_cents',
    'fmt_money', 'round_up_units']),
  '{}'::text[], 'the internal helpers are not callable from the app');

-- A kid calling parent functions
select tests.as_kid('kid_a');
select throws_ok($$select public.approve_request(1)$$, '42501', null, 'a kid cannot approve requests');
select throws_ok($$select public.decline_request(1, 'no')$$, '42501', null, 'a kid cannot decline requests');
select throws_ok($$select public.answer_question(1, 'hi')$$, '42501', null, 'a kid cannot answer questions');
select throws_ok($$select public.add_rate('savings', null, 9.9)$$, '42501', null, 'a kid cannot change rates');
select throws_ok($$select public.set_setting('deposit_cap_cents', '999999')$$, '42501', null, 'a kid cannot change settings');
select throws_ok($$select public.liability_total()$$, '42501', null, 'a kid cannot see the liability total');

-- A parent without the second factor
select tests.as_parent('aal1');
select throws_ok(
  format('select public.approve_request(%s)', (select id from public.requests where account_id = tests.acct('kid_a') limit 1)),
  '42501', null, 'a parent without MFA cannot approve');
select throws_ok($$select public.add_rate('savings', null, 9.9)$$, '42501', null, 'a parent without MFA cannot change rates');
select throws_ok($$select public.set_setting('deposit_cap_cents', '999999')$$, '42501', null, 'a parent without MFA cannot change settings');

-- The parent (or nobody) calling kid functions
select tests.as_parent();
select throws_ok($$select public.request_deposit(1000)$$, '42501', null, 'kid actions need a kid account: the parent is refused');
select tests.nobody();
select throws_ok($$select public.request_deposit(1000)$$, '42501', null, '...and so is a caller with no login');

-- One kid acting on the other's things
select tests.as_kid('kid_a');
select throws_ok(
  format('select public.break_gic(%s)', (select id from public.gic_holdings where account_id = tests.acct('kid_b'))),
  '42501', null, 'kid A cannot break kid B''s GIC');
select throws_ok(
  format('select public.choose_maturity(%s, ''to_savings'')', (select id from public.gic_holdings where account_id = tests.acct('kid_b'))),
  '42501', null, 'kid A cannot choose for kid B''s GIC');
select throws_ok(
  format('select public.ask_question(''Why?'', %s)', (select id from public.transactions where account_id = tests.acct('kid_b') limit 1)),
  '42501', null, 'kid A cannot attach kid B''s ledger line to a question');
select throws_ok(
  format('select * from public.daily_balances(%L, ''2026-10-01'', ''2026-10-05'')', tests.acct('kid_b')),
  '42501', null, 'kid A cannot read kid B''s daily balances');
select is((select count(*) from public.requests where account_id = tests.acct('kid_b')), 2::bigint,
  '(kid B''s rows really exist: her deposit and her GIC purchase)');

-- 2. The read views, as each kid would see them -----------------------------------------

select tests.clock('2026-10-05 10:00');
select tests.as_kid('kid_a');
select public.request_trade('dow', 'buy', 5000);
select public.request_withdrawal(1000);
insert into public.fund_prices (fund_id, price_date, close) values ('dow', '2026-10-05', 400), ('dow', '2026-10-06', 410);
select tests.clock('2026-10-05 16:30');
select 'ran: ' || tests.run('settle_trades', '2026-10-05');

select tests.clock('2026-10-06 16:00');
select tests.as_kid('kid_a');
set local role authenticated;
select is((select count(*) from public.account_balances), 1::bigint, 'a kid sees one row of balances...');
select results_eq(
  $$select account_id, savings_cents, held_cents, available_cents, gic_cents, stock_value_cents, total_worth_cents,
           net_deposits_cents, cap_room_cents
      from public.account_balances$$,
  $$values (tests.acct('kid_a'), 5000::bigint, 1000::bigint, 4000::bigint, 0::bigint, 5125::bigint, 10125::bigint,
            10000::bigint, 90000::bigint)$$,
  '...her own: savings, held, available, GICs, funds (0.125 units × 410), total worth, net deposits and cap room');
select results_eq(
  $$select fund_id, units, held_units, available_units, cost_cents, latest_close, latest_close_date, value_cents, gain_cents, return_pct
      from public.fund_positions$$,
  $$values ('dow', 0.125::numeric, 0::numeric, 0.125::numeric, 5000::bigint, 410::numeric(20,8), date '2026-10-06', 5125::bigint, 125::bigint, 2.50::numeric)$$,
  'her fund: units, average cost, value, gain and return since first purchase (+2.5%)');
select is((select count(*) from public.gic_positions), 0::bigint, 'she sees no GICs (kid B''s are hidden)');
select results_eq(
  $$select balance_date, savings_cents, gic_cents, stock_cents, total_cents, net_flow_cents, (fund_values ->> 'dow')::bigint
      from public.daily_balances(tests.acct('kid_a'), '2026-10-04', '2026-10-06') order by 1$$,
  $$values (date '2026-10-04', 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint, null::bigint),
           (date '2026-10-05', 5000::bigint, 0::bigint, 5000::bigint, 10000::bigint, 10000::bigint, 5000::bigint),
           (date '2026-10-06', 5000::bigint, 0::bigint, 5125::bigint, 10125::bigint, 0::bigint, 5125::bigint)$$,
  'daily balances for the graphs: savings, GICs, each fund''s value, total, and money in or out that day (for the dots)');
select is(public.fund_return(tests.acct('kid_a'), 'dow', '2026-10-05'), 2.50::numeric,
  'the fund''s return since Oct 5, excluding money moved in or out, is +2.5%');
select is(public.next_settlement('dow') , '2026-10-07 14:00-06'::timestamptz,
  'the Buy / Sell screen can ask when a trade made now would settle');
reset role;

select tests.as_kid('kid_b');
set local role authenticated;
select results_eq(
  $$select account_id, savings_cents, gic_cents, total_worth_cents from public.account_balances$$,
  $$values (tests.acct('kid_b'), 15000::bigint, 5000::bigint, 20000::bigint)$$,
  'kid B (a test account) sees only her own balances');
select results_eq(
  $$select principal_cents, rate, balance_cents, interest_at_maturity_cents, interest_so_far_cents, choose_by
      from public.gic_positions$$,
  $$values (5000::bigint, 5.000::numeric(6,3), 5000::bigint, 250::bigint, 1::bigint, null::date)$$,
  'her GIC: balance, interest at maturity ($2.50), and interest so far (1 day: $0.0068, rounded up to $0.01)');
reset role;

-- 3. The parent's view and the liability total -------------------------------------------

select tests.as_parent();
set local role authenticated;
select is((select count(*) from public.account_balances), 2::bigint, 'the parent sees every account''s balances');
select is(public.liability_total(), 10125::bigint, 'the liability total counts kid A ($101.25) and leaves out the test account');
reset role;
select tests.nobody();
select is(public.liability_total(), 10125::bigint, 'the server can read the liability total too');

-- 4. Every new view and function passes the stage 1 safety net -------------------------------

select is(
  array(select c.relname::text from pg_class c
         where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
           and not coalesce('security_invoker=true' = any (c.reloptions), false)),
  '{}'::text[], 'every view runs with the caller''s permissions');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.prosecdef
           and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
  '{}'::text[], 'every SECURITY DEFINER function has a fixed search_path');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'anonymous callers cannot run any function');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.prosecdef
           and p.proname in ('request_deposit', 'request_withdrawal', 'buy_gic', 'break_gic', 'choose_maturity',
                             'request_trade', 'ask_question')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         order by 1),
  array['ask_question', 'break_gic', 'buy_gic', 'choose_maturity', 'request_deposit', 'request_trade', 'request_withdrawal'],
  'the seven kid actions are callable by signed-in users (each checks who is calling)');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.prosecdef
           and p.proname in ('approve_request', 'decline_request', 'answer_question', 'add_rate', 'set_setting')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         order by 1),
  array['add_rate', 'answer_question', 'approve_request', 'decline_request', 'set_setting'],
  'the five parent actions are callable by signed-in users (each requires a parent with MFA)');
select results_eq(
  $$select type::text, vehicle::text, posted_at, effective_at from public.transactions
     where account_id = tests.acct('kid_a') order by id$$,
  $$values ('deposit', 'savings', '2026-10-05 09:00-06'::timestamptz, '2026-10-05 09:00-06'::timestamptz),
           ('transfer_out', 'savings', '2026-10-05 16:30-06'::timestamptz, '2026-10-05 14:00-06'::timestamptz),
           ('transfer_in', 'stock', '2026-10-05 16:30-06'::timestamptz, '2026-10-05 14:00-06'::timestamptz)$$,
  'a deposit counts from when it was approved; a trade written at 4:30 pm counts from the 2:00 pm close');
select ok((select bool_and(effective_at is not null) from public.transactions), 'every ledger row says when its money counts');

select * from finish();
rollback;
