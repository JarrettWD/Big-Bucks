-- Known answers for the second round of pre-launch audit fixes (second audit,
-- 2026-10-08, with Dad's review):
--   1. a new agreement version holds up only new deposits; approving needs Dad's
--      signature on the latest version she signed;
--   2. lockouts escalate, and one device's right PIN doesn't reset the others;
--   3. PIN reset (Dad, authenticator code, logged, a notice to her), the setup script's
--      set_kid_pin, and a new login key;
--   4. confirming a close that isn't final, an unexpected early close, no closure on a
--      day whose dividends are paid, the holiday warning ignoring Dad's rows, and the
--      lock shared by price fixes and settlement;
--   5. reconcile catching late money without its interest, and wrong late interest;
--   6. the seed's production guard.
begin;
select plan(69);

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
create function tests.user_of(p_username text) returns uuid language sql as $$
  select user_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user(tests.user_of(p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
create function tests.new_kid(p_username text) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email, encrypted_password)
    values (v_user, p_username || '@test.invalid', extensions.crypt('x', extensions.gen_salt('bf', 4)));
  insert into public.accounts (name, is_test) values ('Test ' || p_username, false) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb), (v_acct, 1, 'parent', v_user, null);
  return v_acct;
end;
$$;
create function tests.fund(p_username text, p_cents bigint) returns void language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
end;
$$;
create function tests.price(p_fund text, p_date date, p_close numeric, p_fetched timestamptz default null) returns void
language sql as $$
  insert into public.fund_prices (fund_id, price_date, close, fetched_at)
  select p_fund, p_date, p_close,
         coalesce(p_fetched, public.close_time(f.market, p_date) + interval '30 minutes')
    from public.funds f where f.id = p_fund;
$$;
create function tests.edm(p text) returns timestamptz language sql as $$
  select public.edmonton_at(p::timestamp);
$$;
create function tests.problems(p_date date) returns text language sql as $$
  select coalesce(string_agg(e ->> 'message', ' | ' order by e ->> 'message'), '')
    from public.accounts a
   cross join lateral jsonb_array_elements(public.reconcile_account_core(a.id, p_date, p_date, p_date - 1)) e
   where a.name like 'Test kid_r%';
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 09:00');
select tests.new_kid('kid_v');   -- a new agreement version
select tests.new_kid('kid_l');   -- logins
select tests.new_kid('kid_r');   -- reconcile faults
select tests.fund('kid_v', 50000);
select tests.fund('kid_r', 50000);

-- 1. A new agreement version holds up only new deposits -------------------------------------------

select tests.as_kid('kid_v');
create temp table v1dep as select public.request_deposit(1000) as id;  -- asked under version 1
select tests.nobody();
insert into public.agreement_versions (version, intro, rules, promises, sign_line)
values (2, 'Version 2', '[{"icon": "🧪", "title": "New", "text": "A new rule."}]', 'Promises.', 'Sign here.');

select tests.as_kid('kid_v');
select is(tests.err('select public.request_deposit(1000)'),
  'Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed.',
  'a new version: new deposits wait until she signs it');
select lives_ok('select public.request_withdrawal(500)', '...but a withdrawal still works under version 1');
select lives_ok($$select public.request_trade('dow', 'buy', 1000)$$, '...and a fund trade');
select lives_ok('select public.buy_gic(1000, 1)', '...and buying a GIC');
select is((select (s ->> 'needs_signature')::boolean from (select public.onboarding_state(tests.acct('kid_v')) s) x), true,
  'her Home banner asks her to sign (needs_signature)');
select isnt(public.sign_agreement(2), null, 'she signs version 2');
select is(tests.err('select public.request_deposit(1000)'),
  'You signed the new agreement! New deposits wait until Dad signs it too.',
  'new deposits still wait for Dad''s signature on version 2');
select is((select (s ->> 'countersigned')::boolean from (select public.onboarding_state(tests.acct('kid_v')) s) x), false,
  'her Home shows she''s waiting for Dad (countersigned = false)');

select tests.as_parent();
select is(tests.err('select public.approve_request((select id from v1dep))'),
  'Test kid_v signed her agreement and is waiting for you to sign it too. Sign it first (it''s at the top of Approvals), then approve this.',
  'Dad approves only after signing the latest version she signed');
select is((select a ->> 'signed_version' from jsonb_array_elements(public.parent_agreements()) a
            where a ->> 'account_id' = tests.acct('kid_v')::text), '2',
  '...and that''s the version Approvals offers him, so there''s no dead end');
select lives_ok($$select public.countersign_agreement(tests.acct('kid_v'), 2)$$, 'Dad signs version 2');
select lives_ok('select public.approve_request((select id from v1dep))', 'now he can approve');
select tests.as_kid('kid_v');
select lives_ok('select public.request_deposit(1000)', 'and new deposits work again');

-- 2. Lockouts escalate; one device's right PIN doesn't reset the others ----------------------------

select tests.clock('2026-10-06 09:00');
select tests.nobody();
select public.record_login_attempt('kid_l', false, '192.0.2.1') from generate_series(1, 4);
select is((public.record_login_attempt('kid_l', false, '192.0.2.1') ->> 'locked_until')::timestamptz,
  '2026-10-06 09:15-06'::timestamptz, 'the first lock lasts 15 minutes');
select tests.clock('2026-10-06 09:15');
select public.record_login_attempt('kid_l', false, '192.0.2.1') from generate_series(1, 4);
select is((public.record_login_attempt('kid_l', false, '192.0.2.1') ->> 'locked_until')::timestamptz,
  '2026-10-06 10:15-06'::timestamptz, 'a second lock within a day lasts an hour');
select is(
  (select message from public.alerts where kind = 'lockout' and details ->> 'username' = 'kid_l' order by id desc limit 1),
  'kid_l''s login is locked for an hour on one device after 5 wrong PINs in a row.',
  '(still one open alert, now saying how long the latest lock lasts: third audit)');
select tests.clock('2026-10-06 10:15');
select public.record_login_attempt('kid_l', false, '192.0.2.1') from generate_series(1, 4);
select is((public.record_login_attempt('kid_l', false, '192.0.2.1') ->> 'locked_until')::timestamptz,
  '2026-10-07 10:15-06'::timestamptz, 'a third lasts 24 hours');

-- Another device: 4 wrong PINs, then her right PIN on her own device doesn't reset them.
select tests.clock('2026-10-08 12:00');
select public.record_login_attempt('kid_l', false, '198.51.100.9') from generate_series(1, 4);
select public.record_login_attempt('kid_l', true, '203.0.113.50');
select ok((public.record_login_attempt('kid_l', false, '198.51.100.9') ->> 'locked_until') is not null,
  'her right PIN on her own device doesn''t give a stranger''s device fresh tries');
-- Username-wide: a right PIN doesn't reset the day's count either.
select tests.clock('2026-10-10 12:00');
select public.record_login_attempt('kid_l', false, '192.0.2.' || (100 + n)) from generate_series(1, 18) n;
select public.record_login_attempt('kid_l', true, '203.0.113.50');
select is(public.record_login_attempt('kid_l', false, '192.0.2.250') ->> 'locked_until', null,
  '19 wrong PINs today from many devices: not locked yet');
select ok((public.record_login_attempt('kid_l', false, '192.0.2.251') ->> 'locked_until') is not null,
  'the 20th in a day locks the username, even though she signed in in between');
select is(lower(public.login_lock_length('kid_l', '', 'username')::text), '01:00:00',
  'a second username-wide lock that day would last an hour');

-- 3. PIN reset ------------------------------------------------------------------------------------

select tests.clock('2026-10-12 09:00');
insert into auth.sessions (id, user_id) values (gen_random_uuid(), tests.user_of('kid_l'));
create temp table before_pw as select encrypted_password as pw from auth.users where id = tests.user_of('kid_l');
select tests.as_kid('kid_l');
select is(tests.err($$select public.reset_kid_pin(tests.acct('kid_l'))$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t reset a PIN');
select tests.as_parent('aal1');
select is(tests.err($$select public.reset_kid_pin(tests.acct('kid_l'))$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...nor Dad without his code');
select tests.as_parent();
create temp table pin_code as select public.reset_kid_pin(tests.acct('kid_l')) as code;
select ok((select code from pin_code) ~ '^\d{6}$', 'Dad gets a 6-digit one-time code');
select is((select summary from public.parent_actions where action = 'reset_kid_pin'),
  'Reset Test kid_l''s PIN. She chooses a new one at her next sign-in.', 'it''s in his log (the code isn''t)');
select ok(not exists (select 1 from public.parent_actions where action = 'reset_kid_pin'
                       and (summary || details::text) like '%' || (select code from pin_code) || '%'),
  'the code itself is never logged');
select is((select body from public.notifications where account_id = tests.acct('kid_l') and title = 'Dad reset your PIN'),
  'Next time you sign in, type the code Dad gives you instead of your PIN. Then you''ll choose a new PIN.',
  'she gets a notice');
select isnt((select encrypted_password from auth.users where id = tests.user_of('kid_l')), (select pw from before_pw),
  'her old PIN stops working');
select is((select count(*)::int from auth.sessions where user_id = tests.user_of('kid_l')), 0,
  'she is signed out on every device');
select is((select (r ->> 'reset_pending')::boolean from jsonb_array_elements(public.parent_logins()) r
            where r ->> 'account_id' = tests.acct('kid_l')::text), true, 'Settings → Logins shows it waiting');
select tests.nobody();
select is((public.login_precheck('kid_l') ->> 'reset_pending')::boolean, true, 'kid-login sees the reset waiting');
select is(public.check_pin_reset_code(tests.user_of('kid_l'), (select code from pin_code)), true, 'the code works');
select is(public.check_pin_reset_code(tests.user_of('kid_l'),
            case when (select code from pin_code) = '000000' then '111111' else '000000' end), false, 'another code doesn''t');
select is(tests.err($$select public.finish_pin_reset(tests.user_of('kid_l'), (select code from pin_code), (select code from pin_code))$$),
  'Choose a new PIN, not Dad''s code.', 'her new PIN can''t be the code');
select is(tests.err($$select public.finish_pin_reset(tests.user_of('kid_l'), (select code from pin_code), '12345')$$),
  'A PIN is exactly 6 digits.', 'a new PIN is 6 digits');
select lives_ok($$select public.finish_pin_reset(tests.user_of('kid_l'), (select code from pin_code),
                   case when (select code from pin_code) = '246813' then '135792' else '246813' end)$$,
  'with the code she chooses a new PIN');
select ok((select encrypted_password = extensions.crypt(
                    public.kid_auth_password(id, case when (select code from pin_code) = '246813' then '135792' else '246813' end),
                    encrypted_password)
             from auth.users where id = tests.user_of('kid_l')),
  'her Supabase Auth password is now worked out from her new PIN');
select is((public.login_precheck('kid_l') ->> 'reset_pending')::boolean, false, 'and the reset is done');
select is(public.check_pin_reset_code(tests.user_of('kid_l'), (select code from pin_code)), false, 'the code works only once');

-- A code runs out after 7 days.
select tests.as_parent();
create temp table pin_code2 as select public.reset_kid_pin(tests.acct('kid_l')) as code;
select tests.clock('2026-10-19 09:01');
select tests.nobody();
select is(public.check_pin_reset_code(tests.user_of('kid_l'), (select code from pin_code2)), false,
  'a code older than 7 days no longer works');
-- The setup script sets a PIN directly (server only) and clears any reset.
select lives_ok($$select public.set_kid_pin('kid_l', '864209')$$, 'the setup script sets a new PIN');
select ok((select encrypted_password = extensions.crypt(public.kid_auth_password(id, '864209'), encrypted_password)
             from auth.users where id = tests.user_of('kid_l')), '...worked out from that PIN');
select is(
  array(select f || ' ' || r from unnest(array['set_kid_pin(text,text)', 'finish_pin_reset(uuid,text,text)',
                                              'check_pin_reset_code(uuid,text)', 'write_kid_password(uuid,text)',
                                              'new_kid_login_key()', 'reset_kid_pin(uuid)']) f,
                                unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.' || f, 'execute') order by 1),
  array['check_pin_reset_code(uuid,text) service_role', 'finish_pin_reset(uuid,text,text) service_role',
        'reset_kid_pin(uuid) authenticated', 'set_kid_pin(text,text) service_role'],
  'who may call what: Dad resets in the app; kid-login and the setup script are server only; the rest, nobody');
select is(tests.err(format($$update auth.users set encrypted_password = 'x' where id = %L$$, tests.user_of('kid_l'))),
  'A kid''s PIN and login can''t be changed from the app.', 'a direct password change is still refused');

-- 4. Prices -----------------------------------------------------------------------------------------

-- A close fetched before the close time (not final) can be confirmed with the same value.
select tests.clock('2026-11-02 18:00');
select tests.price('dow', '2026-11-02', 500, tests.edm('2026-11-02 13:00'));
select is(public.final_close('dow', '2026-11-02'), null::numeric, 'a close fetched at 1:00 pm isn''t final');
select tests.as_parent();
select lives_ok($$select public.correct_fund_price('dow', '2026-11-02', 500, 'Checked against the exchange')$$,
  'Dad confirms the same value');
select is(public.final_close('dow', '2026-11-02'), 500::numeric, 'now it''s final');
select is((select summary from public.parent_actions where action = 'correct_fund_price' order by id desc limit 1),
  'Confirmed the Dow Jones close for Nov 2: $500.0000 → $500.0000.', 'logged as a confirmation');
select is(tests.err($$select public.correct_fund_price('dow', '2026-11-02', 500, 'Again')$$),
  'That''s the close already stored, and it''s already final.', 'confirming a final close again is refused');

-- An unexpected early close.
select tests.clock('2026-11-04 09:00');
select tests.as_kid('kid_r');
select public.request_trade('nasdaq100', 'buy', 1000);   -- 9:00 am: before the early close
select tests.clock('2026-11-04 13:15');
select tests.as_kid('kid_v');
select public.request_trade('nasdaq100', 'buy', 1000);   -- 1:15 pm: after the 1:00 pm early close
select tests.clock('2026-11-04 14:00');
select tests.price('nasdaq100', '2026-11-04', 100, tests.edm('2026-11-04 13:30'));
select is(public.final_close('nasdaq100', '2026-11-04'), null::numeric,
  'before Dad records it, a 1:30 pm close isn''t final (the usual close is 3:00 pm)');
select tests.as_parent();
select is(tests.err($$select public.record_early_close('nyse', '2026-11-04', '17:00', 'Outage')$$),
  'An early close is between 9:30 am and 4:00 pm, Toronto time.', 'an early close is before 4:00 pm');
select lives_ok($$select public.record_early_close('nyse', '2026-11-04', '14:00', 'Systems outage')$$,
  'Dad records that the NYSE closed at 2:00 pm Toronto time');
select is(public.close_time('nyse', '2026-11-04'), tests.edm('2026-11-04 13:00'), 'its close is now 1:00 pm in Alberta');
select is(public.final_close('nasdaq100', '2026-11-04'), 100::numeric, 'so the 1:30 pm close is final');
select is((select count(*)::int from public.notifications where dedupe_key like 'early_close:nyse:2026-11-04:%'), 1,
  'only the girl whose buy was asked for after the early close is told');
select is((select body from public.notifications where dedupe_key like 'early_close:nyse:2026-11-04:%'),
  'The New York Stock Exchange closed early on Nov 4, before your Nasdaq-100 buy could happen. It will happen at the next close, on Nov 5.',
  'her notice');
select is((select summary from public.parent_actions where action = 'record_early_close'),
  'Recorded that the New York Stock Exchange closed early on Nov 4 at 2:00 pm Toronto time: Systems outage.',
  'it''s in Dad''s log');
select is(tests.err($$select public.record_early_close('nyse', '2026-11-04', '13:00', 'Again')$$),
  'The New York Stock Exchange already has an early close on Nov 4.', 'one early close per day');

-- No closure on a quarter's first trading day whose dividends are paid.
select tests.nobody();
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_r'), 'savings', 'tsx', 'dividend', 1, 'dividend:2027Q1:tsx:' || tests.acct('kid_r'),
        public.edmonton_start('2027-01-04'), 'Test dividend.');
select tests.clock('2027-01-04 18:00');
select tests.as_parent();
select is(tests.err($$select public.record_market_closure('tsx', '2027-01-04', 'Too late')$$),
  'Dividends were already paid on Jan 4, so it can''t be marked closed.', 'a day whose dividends are paid can''t be closed');

-- The holiday warning ignores Dad's own rows.
select tests.clock('2028-11-15 09:00');
select tests.as_parent();
select ok(jsonb_array_length(public.parent_dashboard() -> 'holidays') > 0,
  'near the end of the loaded calendars, the dashboard warns');
select lives_ok($$select public.record_market_closure('nyse', '2029-01-16', 'Announced closure')$$,
  'Dad records a closure in a year whose calendar isn''t loaded');
select ok(exists (select 1 from jsonb_array_elements(public.parent_dashboard() -> 'holidays') h where h ->> 'market' = 'nyse'),
  '...and the NYSE warning stays: his row doesn''t count as the 2029 calendar');

-- Price fixes, settlement and dividends take turns on the same close.
select is(
  (select count(*)::int from pg_proc p
    where p.proname in ('settle_trades', 'pay_quarterly_dividends', 'correct_fund_price')
      and p.pronamespace = 'public'::regnamespace and p.prosrc like '%pg_advisory_xact_lock(hashtext(''close:''%'),
  3, 'all three take the same lock per fund and day');

-- 5. Reconcile catches wrong late money -------------------------------------------------------------

select tests.clock('2026-10-05 18:00');
select tests.nobody();
-- A sale whose money reached savings two days late, without the interest it missed.
insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, status, created_at,
                             settled_at, decided_at)
values (tests.acct('kid_r'), 'move', 'stock', 'savings', 'dow', 10000, 'settled', tests.edm('2026-10-05 09:00'),
        public.close_time('nyse', '2026-10-05'), tests.edm('2026-10-05 09:00'));
select tests.price('dow', '2026-10-05', 100);
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                 posting_key, effective_at, note)
values (tests.acct('kid_r'), 'stock', 'dow', 'transfer_out', -10000, -1, 100,
        (select max(id) from public.requests where account_id = tests.acct('kid_r')),
        'trade:' || (select max(id) from public.requests where account_id = tests.acct('kid_r')) || ':fund',
        public.close_time('nyse', '2026-10-05'), 'Test sale.'),
       (tests.acct('kid_r'), 'savings', 'dow', 'transfer_in', 10000, null, null,
        (select max(id) from public.requests where account_id = tests.acct('kid_r')),
        'trade:' || (select max(id) from public.requests where account_id = tests.acct('kid_r')) || ':savings',
        public.edmonton_start('2026-10-07'), 'Test sale.');
select ok(tests.problems('2026-10-07') like '%A sale''s money reached savings late without the interest it missed.%',
  'a sale that reached savings late without its missed interest is caught');
-- A late-interest line with the wrong amount.
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
values (tests.acct('kid_r'), 'savings', 'interest', 99,
        'late_interest:trade:' || (select max(id) from public.requests where account_id = tests.acct('kid_r')),
        public.edmonton_start('2026-10-07'), 'Wrong.');
select ok(tests.problems('2026-10-07') like '%A late-money interest line isn''t the interest that money missed, rounded up.%',
  'a late-interest line with the wrong amount is caught ($100 × 2% × 2 days ÷ 365 = $0.0110, so 2¢, not 99¢)');

-- 6. The seed's production guard --------------------------------------------------------------------

select lives_ok('select public.assert_not_production()', 'on a local copy the seed may run');
select public.mark_production();
select is(tests.err('select public.assert_not_production()'),
  'This database is production. The local seed never runs here.', 'on marked production it refuses');


-- Last, as they change things for good (the whole file rolls back at the end):
-- A new login key: every PIN needs a reset afterwards.
create temp table old_pw as select public.kid_auth_password(tests.user_of('kid_l'), '864209') as pw;
select is(public.new_kid_login_key(), 'A new login key is in place. Every kid''s PIN now needs a reset (Settings → Logins).',
  'the database owner can put in a new login key');
select isnt(public.kid_auth_password(tests.user_of('kid_l'), '864209'), (select pw from old_pw),
  '...and the same PIN now works out to a different password');

select * from finish();
rollback;
