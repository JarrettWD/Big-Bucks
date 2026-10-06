-- Notices list and questions (stage 7 part 2b): my_notices and my_questions, with
-- Alberta dates worked out in the database.
begin;
select plan(17);

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
create function tests.new_kid(p_username text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
  return v_acct;
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-30 09:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b');
-- Kid A's deposit, approved, so she has a ledger line to ask about.
select tests.as_kid('kid_a');
select public.request_deposit(5000);
select tests.as_parent();
select public.approve_request((select id from public.requests where account_id = tests.acct('kid_a')));
select tests.nobody();
-- Approving wrote a notice; start the notices from a clean slate for the date tests.
delete from public.notifications;

-- Two notices either side of midnight on Nov 1, 2026: the first night on UTC−6 all year.
-- 23:30 is 05:30 UTC on Nov 2; 00:10 is 06:10 UTC, which the old rule (UTC−7) would call Nov 1.
select tests.clock('2026-11-01 23:30');
select public.notify(tests.acct('kid_a'), 'question', 'One', 'First', 'test:one');
select tests.clock('2026-11-02 00:10');
select public.notify(tests.acct('kid_a'), 'question', 'Two', 'Second', 'test:two');
select public.notify(tests.acct('kid_b'), 'question', 'Not yours', 'Kid B''s', 'test:b');

-- 1. my_notices ------------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select results_eq(
  $$select title, on_day, is_new from public.my_notices(tests.acct('kid_a'))$$,
  $$values ('Two'::text, date '2026-11-02', true), ('One', date '2026-11-01', true)$$,
  'her notices, newest first, each with its Alberta date (00:10 on Nov 2 is Nov 2, not Nov 1)');
select results_eq(
  $$select title from public.my_notices(tests.acct('kid_a'), 1)$$,
  $$values ('Two'::text)$$, 'a page of 1');
select results_eq(
  $$select title from public.my_notices(tests.acct('kid_a'), 1,
      (select id from public.notifications where title = 'Two'))$$,
  $$values ('One'::text)$$, 'and the next page carries on after it');
select public.mark_notices_read(array[(select id from public.notifications where title = 'One')]);
select results_eq(
  $$select title, is_new from public.my_notices(tests.acct('kid_a'))$$,
  $$values ('Two'::text, true), ('One', false)$$, 'once read, a notice is no longer new');

-- 2. my_questions ---------------------------------------------------------------------------------

select tests.clock('2026-11-01 23:50');
select public.ask_question('Is this deposit right?',
  (select id from public.transactions where account_id = tests.acct('kid_a') and type = 'deposit'));
select tests.as_parent();
select tests.clock('2026-11-02 00:20');
select public.answer_question((select id from public.questions where message = 'Is this deposit right?'),
  'Yes, that''s the $50 you gave me.');
select tests.as_kid('kid_a');
select tests.clock('2026-11-02 08:00');
select public.ask_question('What is a dividend?');

select results_eq(
  $$select message, transaction_id is not null, reply, answered, asked_on, answered_on
      from public.my_questions(tests.acct('kid_a'))$$,
  $$values ('What is a dividend?'::text, false, null::text, false, date '2026-11-02', null::date),
           ('Is this deposit right?', true, 'Yes, that''s the $50 you gave me.', true,
            date '2026-11-01', date '2026-11-02')$$,
  'her questions, newest first: the line it''s about, Dad''s answer, and the Alberta dates');
select is((select transaction_id from public.my_questions(tests.acct('kid_a')) where message like 'Is this%'),
  (select id from public.transactions where account_id = tests.acct('kid_a') and type = 'deposit'),
  'a question about a line keeps that line''s ledger id');

-- 3. Who may call them ----------------------------------------------------------------------------------

select tests.as_kid('kid_b');
select results_eq($$select title from public.my_notices(tests.acct('kid_b'))$$, $$values ('Not yours'::text)$$,
  'kid B sees only her own notice');
select throws_ok($$select * from public.my_notices(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'kid B can''t list kid A''s notices');
select throws_ok($$select * from public.my_questions(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'or her questions');
select is((select count(*)::int from public.my_questions(tests.acct('kid_b'))), 0, 'kid B has no questions');
select tests.as_parent('aal1');
select throws_ok($$select * from public.my_notices(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'a parent without the authenticator code can''t list them');
select throws_ok($$select * from public.my_questions(tests.acct('kid_a'))$$, '42501', 'You can only see your own account.',
  'nor her questions');
select tests.as_parent('aal2');
select is((select count(*)::int from public.my_notices(tests.acct('kid_a'))), 3,
  'a parent with the code can (her two notices, plus "Dad answered your question")');
select is((select count(*)::int from public.my_questions(tests.acct('kid_a'))), 2, 'and questions');
select tests.nobody();
select throws_ok($$select * from public.my_notices(null)$$, '42501', 'You can only see your own account.',
  'no account, no notices');
select ok(not has_function_privilege('anon', 'public.my_notices(uuid, integer, bigint)', 'execute')
          and not has_function_privilege('anon', 'public.my_questions(uuid)', 'execute'),
  'signed-out visitors can call neither');
select ok(has_function_privilege('authenticated', 'public.my_notices(uuid, integer, bigint)', 'execute')
          and has_function_privilege('authenticated', 'public.my_questions(uuid)', 'execute'),
  'signed-in users can (each checks whose account it is)');

select * from finish();
rollback;
