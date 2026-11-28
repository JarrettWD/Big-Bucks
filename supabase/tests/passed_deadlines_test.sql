-- A passed deadline shows straight away (block 1, item 4; Dad 2026-11-24 and 2026-11-27; migration
-- 20261128030000_passed_deadlines.sql). Known answers: a GIC's choice is over from 12:01 am the day
-- after her last day and refused then, while it still waits for the run; a request is expired one
-- minute after expires_at and its approval refused, while it still says waiting; one that runs out
-- after tonight's run is cancelled tomorrow evening, not tonight. Names are made up.
begin;
select plan(29);

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
    values (v_acct, (select max(av.version) from public.agreement_versions av), 'kid', v_user, '{}'::jsonb),
           (v_acct, (select max(av.version) from public.agreement_versions av), 'parent', v_user, null); -- Dad's countersignature (pre-launch audit)
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

-- Like the evening run: the job, and its row in job_runs (what expire_ran_today reads).
create function tests.run_expire(p_date date) returns void language plpgsql as $$
begin
  perform tests.nobody();
  perform public.expire_requests(p_date);
  insert into public.job_runs (job, run_for_date, status, details, finished_at)
  values ('expire', p_date, 'ok', '{}'::jsonb, public.app_now());
end;
$$;
create function tests.waiting(p_username text) returns jsonb language plpgsql as $$
begin
  perform tests.as_kid(p_username);
  return public.trade_options(tests.acct(p_username)) -> 'waiting';
end;
$$;
create function tests.inbox_row(p_req bigint) returns jsonb language plpgsql as $$
begin
  perform tests.as_parent();
  return (select x from jsonb_array_elements(public.parent_inbox() -> 'requests') x
           where (x ->> 'id')::bigint = p_req);
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2027-01-04 09:00');
select tests.new_kid('pd_g');   -- a GIC whose days to choose run out
select tests.new_kid('pd_r');   -- requests that run out of time
select tests.fund('pd_g', 10000);
select tests.fund('pd_r', 5000);

-- 1. A matured GIC's choice ------------------------------------------------------------------------

-- A 1-month GIC from Jan 4 matures Feb 4; her last day to choose is Feb 10 (choice_ends Feb 11).
select tests.as_kid('pd_g');
select public.buy_gic(10000, 1);
create temp table g as select tests.gic('pd_g', 1, '2027-01-04') as id;
grant select on g to authenticated;
select tests.clock('2027-02-04 16:00');
select 'ran: ' || tests.run('mature_gics', '2027-02-04');

select tests.clock('2027-02-10 23:59');
select tests.as_kid('pd_g');
select is((select choose_by from public.gic_positions where gic_id = (select id from g)), date '2027-02-10',
  'her last day to choose is Feb 10');
select is((select choice_over from public.gic_positions where gic_id = (select id from g)), false,
  'at 11:59 pm on her last day, the choice isn''t over');

select tests.clock('2027-02-11 00:01');
select tests.as_kid('pd_g');
select is((select choice_over from public.gic_positions where gic_id = (select id from g)), true,
  'at 12:01 am the next day, choice_over is true...');
select throws_like(format('select public.choose_maturity(%s, %L)', (select id from g), 'renew'),
  '%7 days to choose are over%', '...and a choice is refused (as Dad asked: 12:01 am, before the run)');
select is((select status::text || '/' || coalesce(maturity_choice::text, 'none') from public.gic_holdings where id = (select id from g)),
  'matured/none', '...while the GIC still waits for the evening run');

select tests.clock('2027-02-11 16:00');
select 'ran: ' || tests.run('auto_move_unclaimed_maturities', '2027-02-11');
select tests.as_kid('pd_g');
select is((select choice_over from public.gic_positions where gic_id = (select id from g)), false,
  'after the run moves it to savings, there''s nothing left to be over');
select is((select balance_cents from public.gic_positions where gic_id = (select id from g)), 0::bigint,
  '...and the GIC is empty');

-- A GIC still growing is never "over".
select tests.as_kid('pd_g');
select is((select count(*) from public.gic_positions where choice_over and account_id = tests.acct('pd_g')), 0::bigint,
  'no GIC of hers says choice_over now');

-- 2. A deposit that runs out of time before the run --------------------------------------------------

select tests.clock('2027-01-05 10:00');
select tests.as_kid('pd_r');
create temp table r (name text primary key, id bigint);
grant select on r to authenticated;
insert into r values ('dep', public.request_deposit(1000));
select tests.clock('2027-01-05 20:00');
select tests.as_kid('pd_r');
insert into r values ('wd', public.request_withdrawal(2000));

select tests.clock('2027-01-12 09:59');
select is(tests.waiting('pd_r') -> 0 ->> 'expired', 'false', 'a minute before its 7 days are up, the deposit isn''t expired');
select is(tests.inbox_row((select id from r where name = 'dep')) ->> 'expired', 'false', '...on Dad''s Approvals either');

select tests.clock('2027-01-12 10:01');
select is(tests.waiting('pd_r') -> 0 ->> 'expired', 'true', 'a minute after, her waiting list says it ran out of time...');
select is(tests.waiting('pd_r') -> 0 ->> 'cancels_tonight', 'true', '...and it''s cancelled tonight (tonight''s run hasn''t happened)');
select is(tests.inbox_row((select id from r where name = 'dep')) ->> 'expired', 'true', 'Dad''s Approvals says so too...');
select is(tests.inbox_row((select id from r where name = 'dep')) ->> 'cancels_tonight', 'true', '...cancelled tonight');
select tests.as_parent();
select throws_like(format('select public.approve_request(%s)', (select id from r where name = 'dep')),
  '%ran out of time%', 'approving it now is refused...');
select is((select status::text from public.requests where id = (select id from r where name = 'dep')), 'pending',
  '...while the request still says waiting, until the run');
select is(tests.waiting('pd_r') -> 1 ->> 'expired', 'false', 'the withdrawal asked at 8 pm still has until 8 pm');

-- Tonight's run (4:30 pm) cancels the deposit.
select tests.clock('2027-01-12 16:30');
select tests.run_expire('2027-01-12');
select is((select status::text from public.requests where id = (select id from r where name = 'dep')), 'expired',
  'tonight''s run cancels the deposit');

-- 3. A withdrawal that runs out of time after tonight's run -------------------------------------------

select tests.clock('2027-01-12 20:01');
select is(jsonb_array_length(tests.waiting('pd_r')), 1, 'only the withdrawal is still waiting');
select is(tests.waiting('pd_r') -> 0 ->> 'expired', 'true', 'at 8:01 pm the withdrawal has run out of time...');
select is(tests.waiting('pd_r') -> 0 ->> 'cancels_tonight', 'false',
  '...but tonight''s run is done, so it''s cancelled tomorrow evening, not "tonight"');
select is(tests.inbox_row((select id from r where name = 'wd')) ->> 'cancels_tonight', 'false', 'Dad''s Approvals says the same');
select is((tests.bal('pd_r')).held_cents, 2000::bigint, 'its $20.00 is still on hold until then');

select tests.clock('2027-01-13 16:30');
select is(tests.waiting('pd_r') -> 0 ->> 'cancels_tonight', 'true', 'the next day, before the run: tonight');
select tests.run_expire('2027-01-13');
select is((select status::text from public.requests where id = (select id from r where name = 'wd')), 'expired',
  'the next evening''s run cancels it...');
select is((tests.bal('pd_r')).held_cents, 0::bigint, '...and its money is no longer on hold');

-- 4. Buys and sells never expire, and who can read ---------------------------------------------------

select is(public.expire_ran_today(), true, 'expire_ran_today: true once tonight''s run has expired requests');
select tests.clock('2027-01-14 09:00');
select is(public.expire_ran_today(), false, '...and false the next morning');

select tests.as_kid('pd_g');
select throws_ok(format('select public.trade_options(%L)', tests.acct('pd_r')), '42501', null,
  'one kid can''t read the other''s waiting list');

select * from finish();
rollback;
