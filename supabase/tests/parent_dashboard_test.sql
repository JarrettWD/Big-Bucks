-- Stage 8 B1: the parent dashboard (parent_dashboard), including the warning when a
-- real kid's request expires within 48 hours. Every date and figure comes from the
-- database. Known answers, written first.
begin;
select plan(19);

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
  insert into public.accounts (name, is_test) values ('Kid ' || upper(right(p_username, 1)), p_is_test) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
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
-- At a time, as a kid, ask for something.
create function tests.ask(p_at text, p_kid text, p_sql text) returns void language plpgsql as $$
begin
  perform tests.clock(p_at);
  perform tests.as_kid(p_kid);
  execute p_sql;
  perform tests.nobody();
end;
$$;
create function tests.dash() returns jsonb language plpgsql as $$
begin
  perform tests.as_parent();
  return public.parent_dashboard();
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Kid A (real): $500 in on Sep 5 and a $20 1-month GIC (matures Oct 5, waiting for her choice).
-- Kid B (a test account): $200 in.
select tests.clock('2026-09-05 09:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.ask('2026-09-05 09:00', 'kid_a', 'select public.request_deposit(50000)');
select tests.ask('2026-09-05 09:00', 'kid_b', 'select public.request_deposit(20000)');
select tests.as_parent();
select public.approve_request(id) from public.requests where status = 'pending' order by id;
select tests.ask('2026-09-05 10:00', 'kid_a', 'select public.buy_gic(2000, 1)');
select tests.clock('2026-10-05 16:30');
select tests.nobody();
select public.mature_gics('2026-10-05');

-- Oct 1: two more GICs (1-month, matures Nov 1; 3-month, matures Jan 1).
select tests.ask('2026-10-01 10:00', 'kid_a', 'select public.buy_gic(10000, 1)');
select tests.ask('2026-10-01 10:05', 'kid_a', 'select public.buy_gic(10000, 3)');

-- Requests waiting for Dad, each 7 days.
select tests.ask('2026-10-03 10:00', 'kid_a', 'select public.request_deposit(5000)');     -- runs out Oct 10 10:00
select tests.ask('2026-10-03 11:30', 'kid_a', 'select public.request_deposit(700)');      -- Oct 10 11:30
select tests.ask('2026-10-04 12:00', 'kid_b', 'select public.request_deposit(1200)');     -- Oct 11 12:00 (test account)
select tests.ask('2026-10-04 15:30', 'kid_a', 'select public.request_withdrawal(2000)');  -- Oct 11 3:30 pm
select tests.ask('2026-10-05 11:00', 'kid_a', 'select public.request_deposit(1000)');     -- Oct 12 11:00
select tests.ask('2026-10-05 11:01', 'kid_a', 'select public.request_deposit(1500)');     -- Oct 12 11:01
select tests.ask('2026-10-05 12:00', 'kid_a', $$select public.ask_question('Is my GIC right?')$$);

-- A rate cut with notice on Oct 6: kid A reads it on Oct 7, kid B doesn't.
select tests.clock('2026-10-06 10:00');
select tests.as_parent();
select public.add_rate('savings', null, 1.5, date '2026-10-17');
select tests.clock('2026-10-07 08:00');
select tests.as_kid('kid_a');
select public.mark_notices_read(array(select id from public.notifications where type = 'rate_change'
                                        and account_id = tests.acct('kid_a')));
-- Alerts: one about kid A, one (quiet) about kid B.
select tests.nobody();
insert into public.alerts (kind, account_id, is_quiet, message) values
  ('test', tests.acct('kid_a'), false, 'Something about Kid A'),
  ('test', tests.acct('kid_b'), true, 'Something about Kid B');

-- The dashboard on Saturday, Oct 10 at 11:00 am ----------------------------------------------------

select tests.clock('2026-10-10 11:00');

-- 1. Each kid, and the liability
select results_eq(
  $$select k ->> 'kid', (k ->> 'is_test')::boolean, (k ->> 'total_worth_cents')::bigint
      from jsonb_array_elements(tests.dash() -> 'kids') k$$,
  $$select a.name, b.is_test, b.total_worth_cents from public.account_balances b
      join public.accounts a on a.id = b.account_id order by b.is_test, a.name$$,
  'each kid''s total worth, real kids first, the same as Home shows');
select is((tests.dash() ->> 'liability_cents')::bigint,
  (select total_worth_cents from public.account_balances where account_id = tests.acct('kid_a')),
  'the liability is the real kids'' total, leaving out test accounts');

-- 2. Waiting for Dad
select is(tests.dash() -> 'waiting', '{"requests": 6, "questions": 1}'::jsonb,
  'six deposits and withdrawals and one question waiting');

-- 3. Expiring within 48 hours: real kids, soonest first, in the database's words
select results_eq(
  $$select e ->> 'text' from jsonb_array_elements(tests.dash() -> 'expiring') e$$,
  $$values ('Kid A''s $50.00 deposit ran out of time today at 10:00 am. Tonight''s run cancels it.'::text),
           ('Kid A''s $7.00 deposit expires today at 11:30 am (in 30 minutes).'),
           ('Kid A''s $20.00 withdrawal expires tomorrow at 3:30 pm (in 28 hours).'),
           ('Kid A''s $10.00 deposit expires Monday at 11:00 am (in 48 hours).')$$,
  'known answers: already run out, 30 minutes, 28 hours 30 minutes (says 28), and exactly 48 hours');
select ok(not exists (select 1 from jsonb_array_elements(tests.dash() -> 'expiring') e where e ->> 'text' like '%$15.00%'),
  '48 hours and 1 minute away isn''t in the warning yet');
select results_eq(
  $$select e ->> 'text' from jsonb_array_elements(tests.dash() -> 'expiring_test') e$$,
  $$values ('Kid B''s $12.00 deposit expires tomorrow at 12:00 pm (in 25 hours).'::text)$$,
  'test accounts'' warnings are kept apart, to be folded away');
select is((select (e ->> 'request_id')::bigint from jsonb_array_elements(tests.dash() -> 'expiring') e limit 1),
  (select id from public.requests where amount_cents = 5000 and status = 'pending'),
  'each warning names its request, for a link to Approvals');
-- An hour exactly, and the 1-minute-past-48 one when it comes into range.
select tests.clock('2026-10-10 11:01');
select is((select e ->> 'text' from jsonb_array_elements(tests.dash() -> 'expiring') e where e ->> 'text' like '%$15.00%'),
  'Kid A''s $15.00 deposit expires Monday at 11:01 am (in 48 hours).', 'it joins at exactly 48 hours left');
select tests.clock('2026-10-11 14:30');
select is((select e ->> 'text' from jsonb_array_elements(tests.dash() -> 'expiring') e where e ->> 'text' like '%$20.00%'),
  'Kid A''s $20.00 withdrawal expires today at 3:30 pm (in 1 hour).', 'one hour: "1 hour"');
select tests.clock('2026-10-10 11:00');

-- 4. Recent automatic moves (last 14 days)
select results_eq(
  $$select m ->> 'kid', m ->> 'to_vehicle', (m ->> 'amount_cents')::bigint, (m ->> 'gic_term')::int, m ->> 'when'
      from jsonb_array_elements(tests.dash() -> 'moves') m$$,
  $$values ('Kid A'::text, 'gic'::text, 10000::bigint, 3, 'Oct 1 at 10:05 am'::text),
           ('Kid A', 'gic', 10000, 1, 'Oct 1 at 10:00 am')$$,
  'the last 14 days of moves, newest first (the Sep 5 GIC is too old)');

-- 5. GICs: waiting for a choice, then maturing within 30 days
select results_eq(
  $$select g ->> 'kid', (g ->> 'amount_cents')::bigint, (g ->> 'interest_cents')::bigint, g ->> 'matures',
           (g ->> 'days_left')::int, (g ->> 'waiting')::boolean, g ->> 'choose_by'
      from jsonb_array_elements(tests.dash() -> 'maturities') g$$,
  $$values ('Kid A'::text, 2000::bigint, 5::bigint, 'Oct 5'::text, -5, true, 'Oct 11'::text),
           ('Kid A', 10000, 21, 'Nov 1', 22, false, null)$$,
  'the matured GIC waiting for her (choose by Oct 11), then Nov 1 in 22 days; the Jan 1 one is too far off');

-- 6. Alerts, with test accounts' quiet ones apart
select results_eq(
  $$select a ->> 'kid', a ->> 'message', a ->> 'since' from jsonb_array_elements(tests.dash() -> 'alerts') a$$,
  $$values ('Kid A'::text, 'Something about Kid A'::text, 'Oct 7 at 8:00 am'::text)$$, 'open alerts');
select results_eq(
  $$select a ->> 'kid' from jsonb_array_elements(tests.dash() -> 'alerts_quiet') a$$,
  $$values ('Kid B'::text)$$, 'test accounts'' alerts kept apart');

-- 7. Has each kid read the rate notice?
select results_eq(
  $$select n ->> 'title', n ->> 'sent', k ->> 'kid', k ->> 'read'
      from jsonb_array_elements(tests.dash() -> 'notices') n, jsonb_array_elements(n -> 'kids') k$$,
  $$values ('Savings rate drops from 2.0% to 1.5% on Oct 17'::text, 'Oct 6 at 10:00 am'::text, 'Kid A'::text, 'Oct 7 at 8:00 am'::text),
           ('Savings rate drops from 2.0% to 1.5% on Oct 17', 'Oct 6 at 10:00 am', 'Kid B', null)$$,
  'rate notices from the last 30 days, and when each kid read them');

-- 8. The holiday table warning
select is(tests.dash() -> 'holidays', '[]'::jsonb, 'Oct 10: no warning (TSX dates are confirmed through Dec 31)');
select tests.clock('2026-10-31 12:00');
select is(tests.dash() -> 'holidays', '[]'::jsonb, 'Oct 31: still 61 days left');
select tests.clock('2026-11-01 12:00');
select is(tests.dash() -> 'holidays',
  '[{"market": "tsx", "through": "Dec 31, 2026", "text": "TSX holiday dates are confirmed only through Dec 31, 2026. When the TSX publishes its 2027 calendar, ask Claude Code to add it."}]'::jsonb,
  'Nov 1: 60 days before the confirmed TSX dates run out (2027 isn''t confirmed yet)');

-- 9. Who may see it
select tests.as_parent('aal1');
select is(tests.err('select public.parent_dashboard()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a parent needs the code');
select tests.as_kid('kid_a');
select is(tests.err('select public.parent_dashboard()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t see it');

select * from finish();
rollback;
