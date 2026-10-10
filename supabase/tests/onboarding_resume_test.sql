-- Stage 8 B4, after Dad's review: she resumes onboarding where she left it (step
-- and tour card, on any device), and a deposit asked for during her first decision
-- shows as waiting. Known answers.
begin;
select plan(28);

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
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
  insert into public.accounts (name, is_test) values ('Kid ' || upper(right(p_username, 1)), false) returning id into v_acct;
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
create function tests.place() returns text language sql as $$
  select (s ->> 'resume_step') || ' ' || (s ->> 'resume_card')
    from (select public.onboarding_state(tests.acct('kid_a')) s) x;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
select tests.clock('2026-10-07 10:00');
select tests.new_kid('kid_a');

select tests.as_kid('kid_a');
select is(tests.place(), 'welcome 0', 'a new kid starts at the welcome');
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'pending_deposit_cents', null, 'with nothing asked for');

-- Her place is saved as she goes.
select lives_ok($$select public.save_onboarding_step('tour', 3)$$, 'on to the fourth tour card');
select is(tests.place(), 'tour 3', 'she comes back to the tour, on that card');
select lives_ok($$select public.save_onboarding_step('agreement')$$, 'on to the agreement');
select is(tests.place(), 'agreement 0', 'she comes back to the agreement');
select lives_ok($$select public.save_onboarding_step('tour', 1)$$, 'back to the tour is fine');
select is(tests.place(), 'tour 1', '...and remembered');

-- Only her own steps, and not past the agreement before she signs.
select is(tests.err($$select public.save_onboarding_step('rockets')$$), 'There''s no "rockets" step in your setup.',
  'only real steps');
select is(tests.err($$select public.save_onboarding_step('wish')$$), 'There''s no "wish" step in your setup.',
  'not a step whose feature is off for her');
select is(tests.err($$select public.save_onboarding_step('tour', -1)$$), 'There''s no card -1 in the tour.',
  'only real tour cards');
select is(tests.err($$select public.save_onboarding_step('decision')$$), 'Sign your Big Bucks agreement with Dad first.',
  'not to her first decision before she signs');

-- Once she signs, her place is her first decision, wherever she says she is.
select public.sign_agreement(1);
select is(tests.place(), 'decision 0', 'after signing she resumes at her first decision');
select public.save_onboarding_step('tour', 2);
select is(tests.place(), 'decision 0', '...even if she looks back at the tour');

-- Her first deposit, asked for during her first decision.
create temporary table dep as select public.request_deposit(2000) as id;
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'pending_deposit_cents', '2000',
  'the deposit she asked for shows as waiting');
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'unlocked', 'false', 'still locked: nothing is in yet');

-- Dad declines it: she sees why, and asks again from the same step.
select tests.as_parent();
select public.decline_request((select id from dep), 'Let''s start with $10');
select tests.as_kid('kid_a');
select is(public.onboarding_state(tests.acct('kid_a')) -> 'last_answer',
  '{"status": "declined", "amount_cents": 2000, "reason": "Let''s start with $10"}'::jsonb,
  'a declined first deposit comes back with Dad''s reason');
select is(tests.place(), 'decision 0', '...and she stays at her first decision');
delete from dep;
insert into dep select public.request_deposit(1000);
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'last_answer', null,
  'once she asks again, the old answer is gone');

-- Unlocking needs both signatures AND her first deposit in.
select tests.as_parent();
select is(tests.err('select public.approve_request((select id from dep))'),
  'Kid A signed her agreement and is waiting for you to sign it too. Sign it first (it''s at the top of Approvals), then approve this.',
  'Dad can''t approve her first deposit before he signs her agreement (pre-launch audit)');
select tests.as_kid('kid_a');
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'unlocked', 'false',
  'Dad hasn''t signed yet: still locked');
select tests.as_parent();
select public.countersign_agreement(tests.acct('kid_a'), 1);
select public.approve_request((select id from dep));
select tests.as_kid('kid_a');
select is((select (s ->> 'unlocked') || ' ' || (s ->> 'done') from (select public.onboarding_state(tests.acct('kid_a')) s) x),
  'true false', 'both signed and her first deposit in: unlocked, before she has even chosen');

-- Finished: nothing to resume.
select public.finish_onboarding();
select is(tests.place(), null, 'once onboarding is done there''s nothing to resume');
select is(public.onboarding_state(tests.acct('kid_a')) ->> 'unlocked', 'true', 'and the app stays unlocked');
select lives_ok($$select public.save_onboarding_step('tour', 1)$$, 'saving after that changes nothing (and doesn''t fail)');

select tests.as_parent();
select is(tests.err($$select public.save_onboarding_step('tour', 1)$$), 'Only a kid''s account can do this.',
  'Dad can''t move her place');
-- Dad's agreements: oldest signature first, real kids before test accounts.
select tests.new_kid('kid_b');
select tests.new_kid('kid_c');
update public.accounts set is_test = true where id = tests.acct('kid_c');
select tests.clock('2026-10-07 09:00');
select tests.as_kid('kid_c');
select public.sign_agreement(1);
select tests.clock('2026-10-07 11:00');
select tests.as_kid('kid_b');
select public.sign_agreement(1);
select tests.as_parent();
select is((select jsonb_agg(k ->> 'kid') from jsonb_array_elements(public.parent_agreements()) k),
  '["Kid A", "Kid B", "Kid C"]'::jsonb,
  'real kids by when they signed (A at 10:00, B at 11:00), then the test account (C signed first, at 9:00)');

select is(
  array(select r.rolname::text from pg_roles r
         where has_function_privilege(r.oid, 'public.save_onboarding_step(text, integer)', 'EXECUTE')
           and r.rolname in ('anon', 'authenticated', 'service_role') order by 1),
  array['authenticated'], 'signed-in users only (it checks she is a kid inside)');

select * from finish();
rollback;
