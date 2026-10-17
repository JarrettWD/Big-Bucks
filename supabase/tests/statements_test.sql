-- Stage 11: monthly statements (plan approved by Dad 2026-10-17, with his five additions).
-- A real month, through the real engine (deposit, GIC, fund buy and sell, withdrawal,
-- fixes, the nightly jobs), then known answers for every line; the identity
--   End = Start + In - Out + Interest + Dividends + Fund gains + Fixes
-- for every account and month, AND Start and End equal to the Total worth graph's
-- figures (daily_balances); interest timing (Home, graph and statement agree, and
-- accruing interest is never in total worth); and a mutation test proving the identity
-- check fails when Fund gains is wrong.
begin;
select plan(40);

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
create function tests.closes(p_fund text, p_from date, p_to date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close)
  select p_fund, d::date, p_close
    from generate_series(p_from, p_to, interval '1 day') d
   where public.is_trading_day((select f.market from public.funds f where f.id = p_fund), d::date);
$$;
create function tests.night(p_day date) returns text language plpgsql as $$
begin
  perform tests.nobody();
  return public.run_daily(p_day) ->> 'status';
end;
$$;
-- Her statement for a month, as she reads it.
create function tests.st(p_username text, p_month date) returns jsonb language sql as $$
  select public.kid_statement(tests.acct(p_username), p_month);
$$;
create function tests.n(p jsonb, p_key text) returns bigint language sql as $$
  select (p ->> p_key)::bigint;
$$;
-- The identity check Dad asked for, independent of the statement's own "balanced" flag:
-- the lines add up, AND Start and End are the Total worth graph's figures for those days.
create function tests.identity_ok(p_acct uuid, p_month date) returns boolean language plpgsql as $$
declare
  v_from date := greatest(p_month, (select public.edmonton_local(a.created_at)::date from public.accounts a where a.id = p_acct));
  v_to date := (p_month + interval '1 month' - interval '1 day')::date;
  s jsonb := public.statement_figures(p_acct, v_from, v_to);
  v_start bigint;
  v_end bigint;
begin
  select b.total_cents into v_start from public.daily_balances(p_acct, v_from - 1, v_from - 1) b;
  select b.total_cents into v_end from public.daily_balances(p_acct, v_to, v_to) b;
  return tests.n(s, 'start_cents') = coalesce(v_start, 0)
     and tests.n(s, 'end_cents') = v_end
     and tests.n(s, 'end_cents') = tests.n(s, 'start_cents') + tests.n(s, 'money_in_cents') - tests.n(s, 'money_out_cents')
                                   + tests.n(s, 'interest_cents') + tests.n(s, 'dividends_cents')
                                   + tests.n(s, 'fund_gains_cents') + tests.n(s, 'fixes_cents')
     and tests.n(s, 'uncounted') = 0;
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
insert into public.settings (key, value, effective_date)
values ('feature:statements', 'test', date '2026-01-01');

-- Every fund closes every trading day. The Dow fund: 400 until Oct 26, 440 from Oct 27,
-- 420 from Nov 2. The other two: a steady 100.
select tests.closes('dow', '2026-10-01', '2026-10-26', 400);
select tests.closes('dow', '2026-10-27', '2026-10-30', 440);
select tests.closes('dow', '2026-11-02', '2026-12-02', 420);
select tests.closes('nasdaq100', '2026-10-01', '2026-12-02', 100);
select tests.closes('tsx', '2026-10-01', '2026-12-02', 100);

select tests.clock('2026-10-05 09:00');
select tests.new_kid('st_a');           -- the month with everything
select tests.new_kid('st_b');           -- a ledger line that doesn't add up
select tests.new_kid('st_real', false); -- a real kid: the switch is "test accounts only"
select tests.new_kid('st_sis', false);

-- October: $500 in; a $100 1-month GIC; $100 of the Dow fund; $50 out; $40 of the fund sold;
-- a $2.00 "money" fix out and a $1.00 "earned" fix in.
select tests.fund('st_a', 50000);
select tests.clock('2026-10-05 10:00');
select tests.as_kid('st_a');
select public.buy_gic(10000, 1);
select tests.clock('2026-10-06 10:00');
select public.request_trade('dow', 'buy', 10000);
select tests.clock('2026-10-20 10:00');
select tests.as_kid('st_a');
select public.request_withdrawal(5000);
select tests.clock('2026-10-21 11:00');
select tests.as_parent();
select public.approve_request((select id from public.requests where account_id = tests.acct('st_a') and type = 'withdraw'));
select tests.clock('2026-10-28 09:00');
select 'jobs: ' || tests.night('2026-10-27');
select tests.clock('2026-10-28 10:00');
select tests.as_kid('st_a');
select public.request_trade('dow', 'sell', 4000);
select tests.clock('2026-10-29 10:00');
insert into public.transactions (account_id, vehicle, type, amount_cents, note, counts_as, effective_at)
values (tests.acct('st_a'), 'savings', 'correction', -200, 'Test: a money fix', 'money', public.app_now()),
       (tests.acct('st_a'), 'savings', 'correction', 100, 'Test: an earned fix', 'earned', public.app_now());
select tests.fund('st_b', 10000);
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
values (tests.acct('st_b'), 'savings', 'transfer_in', 500, public.app_now()); -- from nowhere: can't add up

-- 1. Interest timing, on the evening of Oct 31 (Dad's addition 2) -----------------------------

select tests.clock('2026-10-31 18:00');
select 'jobs: ' || tests.night('2026-10-31');
select ok((select sum(accrued) from public.interest_accruals where account_id = tests.acct('st_a')
            and accrual_date between '2026-10-01' and '2026-10-30') > 0,
  'October''s savings interest is accruing...');
select is((select total_worth_cents from public.account_balances where account_id = tests.acct('st_a')), 45900::bigint,
  '...but Home''s total worth counts only money paid: $459.00');
create temp table home_oct31 as
  select total_worth_cents as v from public.account_balances where account_id = tests.acct('st_a');
select is((select total_cents from public.daily_balances(tests.acct('st_a'), '2026-10-31', '2026-10-31')), 45900::bigint,
  'the Total worth graph''s Oct 31 point agrees');
select is(public.kid_statement_months(tests.acct('st_a')) -> 'months' -> 0 ->> 'ready', 'false',
  'October''s statement isn''t ready while October is still on');
select is(public.kid_statement_months(tests.acct('st_a')) -> 'months' -> 0 ->> 'ready_on', '2026-11-01',
  '...it''s ready on Nov 1');
select is(tests.st('st_a', '2026-10-01') ->> 'ready', 'false', 'asking for it early gives no numbers');
select is(tests.st('st_a', '2026-10-01') ? 'end_cents', false, '...none at all');

-- November: a 77-cent dividend line on Nov 10, then the nightly jobs through Dec 1.
select tests.clock('2026-11-10 10:00');
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at)
values (tests.acct('st_a'), 'savings', 'dow', 'dividend', 77, 'test:dividend:st_a', public.app_now());
select tests.clock('2026-12-01 18:00');
select 'jobs: ' || tests.night('2026-12-01');

-- 2. October's statement: known answers ------------------------------------------------------------

select is(tests.st('st_a', '2026-10-01') ->> 'ready', 'true', 'October is ready now (it''s over, and its jobs are done)');
select is(tests.st('st_a', '2026-10-01') ->> 'from', '2026-10-05', 'it starts the day her account opened (a partial month)');
select is(tests.st('st_a', '2026-10-01') ->> 'opened_this_month', 'true', '...and says so');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'start_cents'), 0::bigint, 'Starting balance: $0.00');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'money_in_cents'), 50000::bigint, 'Money in: $500.00');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'money_out_cents'), 5200::bigint,
  'Money out: $50.00 withdrawn and the $2.00 "money" fix');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'interest_cents'), 0::bigint,
  'Interest: none (October''s is dated Nov 1, and the GIC finishes Nov 5)');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'dividends_cents'), 0::bigint, 'Dividends: none');
-- 0.25 units bought at $400 for $100.00; $40.00 of them sold at $440; the rest is worth $70.00 at
-- Oct 30's $440. $70.00 - $0 - $100.00 paid + $40.00 got = $10.00 (0.25 units × the $40 rise).
select is(tests.n(tests.st('st_a', '2026-10-01'), 'fund_gains_cents'), 1000::bigint,
  'Fund gains: $10.00 ($70.00 now - $100.00 paid + $40.00 from the sale)');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'fixes_cents'), 100::bigint, 'Fixes from Dad: $1.00');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'end_cents'), 45900::bigint, 'Ending balance: $459.00');
select is(tests.n(tests.st('st_a', '2026-10-01'), 'end_cents'), (select v from home_oct31),
  '...the same figure Home showed on the evening of Oct 31 (Dad''s addition 2)');
select is(tests.st('st_a', '2026-10-01') ->> 'balanced', 'true', 'it says it adds up');
select ok(tests.identity_ok(tests.acct('st_a'), '2026-10-01'),
  'the identity holds, and Start and End are the graph''s figures');

-- 3. November: October's interest is here, with the GIC's and the dividend ---------------------------

select is(tests.n(tests.st('st_a', '2026-11-01'), 'start_cents'), 45900::bigint, 'November starts where October ended');
select is(tests.n(tests.st('st_a', '2026-11-01'), 'interest_cents'),
          (select sum(amount_cents)::bigint from public.transactions where account_id = tests.acct('st_a') and type = 'interest'
             and posting_key in ('interest:2026-10:' || tests.acct('st_a'),
                                 'gic_interest:' || (select id from public.gic_holdings where account_id = tests.acct('st_a')))),
  'Interest: October''s savings interest (paid Nov 1) and the GIC''s');
select is((select amount_cents from public.transactions where posting_key = 'gic_interest:'
            || (select id from public.gic_holdings where account_id = tests.acct('st_a')))::bigint, 21::bigint,
  '...the GIC''s is $100.00 × 2.5% × 1/12 = $0.21, rounded up');
select is((select amount_cents from public.transactions where posting_key = 'interest:2026-10:' || tests.acct('st_a')),
          (select ceil(sum(accrued))::bigint from public.interest_accruals where account_id = tests.acct('st_a')
             and accrual_date between '2026-10-01' and '2026-10-31'),
  '...October''s savings interest is October''s accruals, rounded up');
select is(tests.n(tests.st('st_a', '2026-11-01'), 'dividends_cents'), 77::bigint, 'Dividends: $0.77');
-- The units left: $70.00 at Oct 30's $440, $66.82 at Nov 30's $420 (66.818... rounds to the cent).
select is(tests.n(tests.st('st_a', '2026-11-01'), 'fund_gains_cents'), -318::bigint, 'Fund gains: -$3.18 (the price fell)');
select ok(tests.identity_ok(tests.acct('st_a'), '2026-11-01'), 'November''s identity holds against the graph too');
select is(public.kid_statement_months(tests.acct('st_a')) -> 'months' -> 2 ->> 'ready', 'false',
  'December isn''t ready on Dec 1');

-- 4. Every account and month ---------------------------------------------------------------------

select is((select count(*) from public.accounts a, generate_series(date '2026-10-01', date '2026-11-01', interval '1 month') m
            where a.id <> tests.acct('st_b') and public.feature_enabled('statements', a.id)
              and (public.kid_statement(a.id, m::date) ->> 'ready')::boolean
              and not tests.identity_ok(a.id, m::date)), 0::bigint,
  'every ready statement for every account adds up exactly and matches the graph');
select is(tests.identity_ok(tests.acct('st_b'), '2026-10-01'), false,
  'a ledger line from nowhere breaks the identity, and the check catches it');
select is(public.statement_figures(tests.acct('st_b'), '2026-10-05', '2026-10-31') ->> 'balanced', 'false',
  '...the statement''s own check says it doesn''t add up');
select is(tests.st('st_b', '2026-10-01') ? 'money_in_cents', false,
  '...and shows no numbers (the app says it''s being checked), never wrong ones');

-- 5. Who can see them ---------------------------------------------------------------------------------

select tests.as_kid('st_a');
select is(public.kid_statement(public.my_account_id(), '2026-10-01') ->> 'end_cents', '45900', 'she reads her own');
select tests.as_kid('st_sis');
select is(tests.err(format('select public.kid_statement(%L, %L)', tests.acct('st_a'), '2026-10-01')),
  'You can only see your own statements.', 'another kid can''t read hers');
select tests.as_kid('st_real');
select is(public.kid_statement_months(public.my_account_id()), '{"on": false}'::jsonb,
  'with Statements off for her (a real kid, "test accounts only"), there are none');
select tests.as_parent();
select is(public.parent_view(tests.acct('st_a'), 'kid_statement', '{"p_month": "2026-10-01"}'::jsonb),
          public.kid_statement(tests.acct('st_a'), '2026-10-01'), '"View as" reads exactly what she reads');
select tests.nobody();
select is((select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc ilike '%statement%'
            and p.proname in ('post_monthly_interest', 'accrue_savings_interest', 'mature_gics', 'settle_trades',
                              'pay_quarterly_dividends', 'run_daily', 'reconcile', 'approve_request', 'request_trade')),
  0::bigint, 'no money function knows about statements');

-- 6. The mutation test: a wrong Fund gains must fail the identity check (Dad's addition 1) -----------

select ok(tests.identity_ok(tests.acct('st_a'), '2026-10-01'), 'before: October adds up');
create or replace function public.statement_fund_gains(p_account uuid, p_from date, p_to date)
returns bigint language sql stable set search_path = '' as $$
  -- A deliberately wrong version: it forgets the money her sales brought in.
  select coalesce(sum(public.fund_value_at(p_account, f.id, p_to) - public.fund_value_at(p_account, f.id, p_from - 1)
           + coalesce((select sum(t.amount_cents) from public.transactions t
                        where t.account_id = p_account and t.fund_id = f.id and t.vehicle = 'savings'
                          and t.type = 'transfer_out'
                          and t.effective_at >= public.edmonton_start(p_from)
                          and t.effective_at < public.edmonton_start(p_to + 1)), 0)), 0)::bigint
    from public.funds f;
$$;
select is(tests.identity_ok(tests.acct('st_a'), '2026-10-01'), false,
  'with Fund gains wrong (sales forgotten), the identity check fails: the test isn''t empty');

select * from finish();
rollback;
