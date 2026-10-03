-- is_parent(), my_account_id() and feature_enabled(feature, account_id).
begin;
select plan(20);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'kid-a@test.invalid'),
  ('00000000-0000-0000-0000-00000000000b', 'kid-b@test.invalid'),
  ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.accounts (id, name, is_test) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Test Kid A', false),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Test Kid B', true);
insert into public.profiles (user_id, role, account_id, username, display_name) values
  ('00000000-0000-0000-0000-00000000000a', 'investor', 'aaaaaaaa-0000-0000-0000-000000000001', 'test_kid_a', 'Kid A'),
  ('00000000-0000-0000-0000-00000000000b', 'investor', 'bbbbbbbb-0000-0000-0000-000000000002', 'test_kid_b', 'Kid B'),
  ('00000000-0000-0000-0000-00000000000f', 'parent',   null,                                   'test_parent', 'Parent');

create function pg_temp.claims(p_user text, p_aal text) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;

-- Who is calling
select pg_temp.claims('00000000-0000-0000-0000-00000000000a', 'aal1');
select is(public.my_account_id(), 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'my_account_id() is the kid''s own account');
select is(public.is_parent(), false, 'a kid is not a parent');
select pg_temp.claims('00000000-0000-0000-0000-00000000000a', 'aal2');
select is(public.is_parent(), false, 'a kid is not a parent, even at aal2');

select pg_temp.claims('00000000-0000-0000-0000-00000000000f', 'aal2');
select is(public.is_parent(), true, 'the parent with MFA (aal2) is a parent');
select is(public.my_account_id(), null::uuid, 'the parent has no account of their own');
select pg_temp.claims('00000000-0000-0000-0000-00000000000f', 'aal1');
select is(public.is_parent(), false, 'the parent without MFA (aal1) is not treated as a parent');

select set_config('request.jwt.claims', '', true);
select is(public.is_parent(), false, 'nobody signed in: not a parent');
select is(public.my_account_id(), null::uuid, 'nobody signed in: no account');

-- Feature switches (asked as the server: nobody signed in)
select is(public.feature_enabled('demo', 'aaaaaaaa-0000-0000-0000-000000000001'), false,
  'a feature with no setting is off');

insert into public.settings (key, value, effective_date) values ('feature:demo', 'test', public.app_today());
select is(public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002'), true, '"test": on for a test account');
select is(public.feature_enabled('demo', 'aaaaaaaa-0000-0000-0000-000000000001'), false, '"test": off for a real kid');

insert into public.settings (key, value, effective_date) values ('feature:demo', 'everyone', public.app_today() + 1);
select is(public.feature_enabled('demo', 'aaaaaaaa-0000-0000-0000-000000000001'), false,
  'a switch dated tomorrow has not taken effect yet');

insert into public.settings (key, value, effective_date) values ('feature:demo', 'everyone', public.app_today());
select is(public.feature_enabled('demo', 'aaaaaaaa-0000-0000-0000-000000000001'), true, '"everyone": on for a real kid');
select is(public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002'), true, '"everyone": on for a test account');

insert into public.settings (key, value, effective_date) values ('feature:demo', 'off', public.app_today());
select is(public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002'), false, '"off": off even for a test account');

insert into public.settings (key, value, effective_date) values ('feature:demo', 'maybe', public.app_today());
select is(public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002'), false, 'an unknown value counts as off');

-- Who may ask
insert into public.settings (key, value, effective_date) values ('feature:demo', 'everyone', public.app_today());
select pg_temp.claims('00000000-0000-0000-0000-00000000000a', 'aal1');
set local role authenticated;
select is(public.feature_enabled('demo', 'aaaaaaaa-0000-0000-0000-000000000001'), true, 'a kid can check her own account');
select throws_ok($$select public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002')$$,
  '42501', null, 'a kid cannot check her sister''s account');
reset role;

select pg_temp.claims('00000000-0000-0000-0000-00000000000f', 'aal2');
set local role authenticated;
select is(public.feature_enabled('demo', 'bbbbbbbb-0000-0000-0000-000000000002'), true, 'the parent can check any account');
reset role;

set local role anon;
select throws_ok($$select public.feature_enabled('demo', null)$$, '42501', null, 'anonymous callers cannot run it');
reset role;

select * from finish();
rollback;
