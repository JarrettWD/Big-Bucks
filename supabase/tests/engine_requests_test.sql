-- Known answers: deposits, withdrawals, the cap, holds, approvals, declines,
-- expiry and questions (stage 2).
begin;
select plan(48);

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


create function tests.req(p_id bigint) returns public.requests language sql as $$
  select * from public.requests where id = p_id;
$$;
create temp table ids (k text primary key, v bigint);
create function pg_temp.id(p_k text) returns bigint language sql as $$ select v from ids where k = p_k; $$;

select tests.clock('2026-10-05 10:00');
select tests.new_kid('kid_r');
select tests.new_kid('kid_q');

-- 1. Deposits and the cap ---------------------------------------------------------

select tests.as_kid('kid_r');
select throws_like($$select public.request_deposit(499)$$, '%smallest deposit is $5.00%', 'a deposit under $5 is refused');
select throws_like($$select public.request_deposit(100001)$$, '%up to $1,000.00 more%', 'a deposit over the cap is refused, saying how much room is left');
insert into ids select 'd1', public.request_deposit(90000);
select results_eq($$select type::text, status::text, held_cents, to_vehicle::text from public.requests where id = pg_temp.id('d1')$$,
  $$values ('deposit', 'pending', 0::bigint, 'savings')$$, 'a deposit request is pending and holds nothing (the money isn''t in yet)');
select is((tests.bal('kid_r')).savings_cents, 0::bigint, 'nothing lands in savings until Dad approves');
select tests.as_parent();
select lives_ok($$select public.approve_request(pg_temp.id('d1'))$$, 'Dad approves the $900 deposit');
select results_eq($$select status::text, decided_at from public.requests where id = pg_temp.id('d1')$$,
  $$values ('approved', '2026-10-05 10:00-06'::timestamptz)$$, 'the request is approved');
select results_eq(
  $$select type::text, vehicle::text, amount_cents, posting_key from public.transactions where request_id = pg_temp.id('d1')$$,
  $$values ('deposit', 'savings', 90000::bigint, 'request:' || pg_temp.id('d1'))$$,
  'the deposit lands in savings, once');
select is(
  (select title from public.notifications where related_request_id = pg_temp.id('d1')),
  'Your $900.00 deposit is in!', 'she gets a notice');
select throws_like($$select public.approve_request(pg_temp.id('d1'))$$, '%isn''t waiting%', 'a request can''t be approved twice');

select tests.as_kid('kid_r');
insert into ids select 'd2', public.request_deposit(5000);
select throws_like($$select public.request_deposit(5001)$$, '%up to $50.00 more%',
  'the cap counts pending deposits: $900 in + $50 pending leaves $50 of room');
insert into ids select 'd3', public.request_deposit(5000);
select is((tests.bal('kid_r')).cap_room_cents, 0::bigint, 'exactly at the cap: no room left');
select results_eq(
  $$select net_deposits_cents, pending_deposits_cents, cap_cents from public.account_balances where account_id = tests.acct('kid_r')$$,
  $$values (90000::bigint, 10000::bigint, 100000::bigint)$$, 'net deposits, pending deposits and the cap');

-- 2. Declines keep Dad's reason ------------------------------------------------------

select tests.as_parent();
select throws_like($$select public.decline_request(pg_temp.id('d3'), '  ')$$, '%reason%', 'a decline needs a reason');
select lives_ok($$select public.decline_request(pg_temp.id('d3'), 'Wait until after Christmas')$$, 'Dad declines with a reason');
select results_eq($$select status::text, parent_note from public.requests where id = pg_temp.id('d3')$$,
  $$values ('declined', 'Wait until after Christmas')$$, 'the declined request keeps the reason');
select is(
  (select body from public.notifications where related_request_id = pg_temp.id('d3')),
  'Your request to put in $50.00 wasn''t approved. Dad said: "Wait until after Christmas"',
  'her notice shows the reason');
select is((tests.bal('kid_r')).cap_room_cents, 5000::bigint, 'a declined deposit frees its cap room');

-- 3. Withdrawals: holds and the 24-hour wait -------------------------------------------

select tests.as_kid('kid_r');
select throws_like($$select public.request_withdrawal(90001)$$, '%You have $900.00 available%', 'she can''t take out more than she has');
insert into ids select 'w1', public.request_withdrawal(2000);
select results_eq($$select type::text, from_vehicle::text, held_cents from public.requests where id = pg_temp.id('w1')$$,
  $$values ('withdraw', 'savings', 2000::bigint)$$, 'a withdrawal holds the amount in savings');
select is((tests.bal('kid_r')).available_cents, 88000::bigint, 'held money isn''t available');
select throws_like($$select public.buy_gic(88001, 12)$$, '%You have $880.00 available%', '...so it can''t be used twice');
select tests.clock('2026-10-06 09:59');
select tests.as_parent();
select throws_like($$select public.approve_request(pg_temp.id('w1'))$$, '%24 hours%Oct 6 at 10:00 am%',
  'Dad can''t approve a withdrawal before 24 hours have passed');
select tests.clock('2026-10-06 10:00');
select tests.as_parent();
select lives_ok($$select public.approve_request(pg_temp.id('w1'))$$, 'after 24 hours he can');
select results_eq(
  $$select savings_cents, held_cents, available_cents, net_deposits_cents from public.account_balances where account_id = tests.acct('kid_r')$$,
  $$values (88000::bigint, 0::bigint, 88000::bigint, 88000::bigint)$$,
  'the withdrawal leaves savings, the hold is released, and net deposits drop');

-- The $5 minimum, unless it empties savings (decision 3).
select tests.fund('kid_q', 1000);
select tests.as_kid('kid_q');
insert into ids select 'q1', public.request_withdrawal(700);
select tests.clock('2026-10-07 10:00');
select tests.as_parent();
select public.approve_request(pg_temp.id('q1'));
select tests.as_kid('kid_q');
select throws_like($$select public.request_withdrawal(200)$$, '%smallest withdrawal is $5.00%', 'a withdrawal under $5 is refused...');
select lives_ok($$select public.request_withdrawal(300)$$, '...unless it takes out everything left ($3.00)');

-- 4. Expiry: 7 days to the minute, then the hold is released (decision 4) ---------------

-- kid_r: d2 (deposit, Oct 5 10:00) is still pending.
select tests.clock('2026-10-07 10:00');
select tests.as_kid('kid_r');
insert into ids select 'w2', public.request_withdrawal(1000);
insert into ids select 'd4', public.request_deposit(1000);
select is((tests.bal('kid_r')).available_cents, 87000::bigint, 'the new withdrawal holds $10');

select tests.clock('2026-10-12 09:00');
select is(tests.run('expire_requests', '2026-10-12'), 'ok', 'at 9:00 am on Oct 12...');
select is((tests.req(pg_temp.id('d2'))).status::text, 'pending', '...the Oct 5, 10:00 am deposit has not expired yet');
select tests.clock('2026-10-12 16:30');
select 'ran: ' || tests.run('expire_requests', '2026-10-12');
select results_eq($$select status::text, decided_at from public.requests where id = pg_temp.id('d2')$$,
  $$values ('expired', '2026-10-12 10:00-06'::timestamptz)$$,
  'an unanswered request expires 7 days after it was made');
select is(
  (select title || ' / ' || body from public.notifications where related_request_id = pg_temp.id('d2')),
  'Your request ran out of time / Your request to put in $50.00 waited 7 days without an answer, so it was cancelled. You can ask again any time.',
  'she gets a kind notice explaining why');

select tests.clock('2026-10-14 08:00');
select 'ran: ' || tests.run('expire_requests', '2026-10-13');
select is((tests.req(pg_temp.id('w2'))).status::text, 'pending', 'catching up Oct 13 doesn''t expire an Oct 7, 10:00 am request early');
select tests.clock('2026-10-14 10:01');
select tests.as_parent();
select throws_like($$select public.approve_request(pg_temp.id('w2'))$$, '%7 days%', 'after 7 days Dad can no longer approve it');
select tests.clock('2026-10-14 16:30');
select 'ran: ' || tests.run('expire_requests', '2026-10-14');
select results_eq(
  $$select status::text from public.requests where id in (pg_temp.id('w2'), pg_temp.id('d4')) order by id$$,
  $$values ('expired'), ('expired')$$, 'both Oct 7 requests expire on day 7');
select is((tests.bal('kid_r')).available_cents, 88000::bigint, 'the expired withdrawal''s hold is released');
select is((tests.bal('kid_r')).held_cents, 0::bigint, 'nothing is held');
select is(tests.run('expire_requests', '2026-10-14'), 'ok', 'running expiry again...');
select is((select count(*) from public.notifications where type = 'request_expired'), 4::bigint,
  '...sends no second notice (one each: kid_r''s three requests and kid_q''s $3 withdrawal)');
select tests.as_parent();
select throws_like($$select public.decline_request(pg_temp.id('w2'), 'Too late')$$, '%isn''t waiting%', 'an expired request can''t be declined');

-- 5. Moves aren't approved by Dad --------------------------------------------------

select tests.as_kid('kid_r');
insert into ids select 't1', public.request_trade('dow', 'buy', 1000);
select tests.as_parent();
select throws_like($$select public.approve_request(pg_temp.id('t1'))$$, '%only deposits and withdrawals%',
  'moves go through on their own; Dad approves only deposits and withdrawals');

-- 6. Questions --------------------------------------------------------------------

select tests.as_kid('kid_r');
select throws_like($$select public.ask_question('   ')$$, '%Write your question%', 'an empty question is refused');
insert into ids select 'x1', (select id from public.transactions where request_id = pg_temp.id('d1'));
insert into ids select 'qn', public.ask_question('Is this right?', pg_temp.id('x1'));
select results_eq($$select status::text, transaction_id, message from public.questions where id = pg_temp.id('qn')$$,
  $$values ('open', pg_temp.id('x1'), 'Is this right?')$$, 'her question is open, with the line attached');
select tests.as_parent();
select lives_ok($$select public.answer_question(pg_temp.id('qn'), 'Yes, that was your birthday money.')$$, 'Dad answers');
select results_eq($$select status::text, parent_reply, answered_at from public.questions where id = pg_temp.id('qn')$$,
  $$values ('answered', 'Yes, that was your birthday money.', '2026-10-14 16:30-06'::timestamptz)$$,
  'the answer is kept with the question');
select is(
  (select count(*) from public.notifications where account_id = tests.acct('kid_r') and type = 'question'),
  1::bigint, 'she gets a notice that Dad answered');
select throws_like($$select public.answer_question(pg_temp.id('qn'), 'Again')$$, '%already answered%', 'a question is answered once');

-- 7. Lowering the cap never takes money away -------------------------------------------

select tests.as_parent();
select public.set_setting('deposit_cap_cents', '50000');
select results_eq(
  $$select savings_cents, cap_cents, cap_room_cents from public.account_balances where account_id = tests.acct('kid_r')$$,
  $$values (88000::bigint, 50000::bigint, 0::bigint)$$,
  'a cap below what she has deposited keeps her money and leaves no room');
select tests.as_kid('kid_r');
select throws_like($$select public.request_deposit(500)$$, '%deposit limit%', '...so new deposits are blocked');

select * from finish();
rollback;
