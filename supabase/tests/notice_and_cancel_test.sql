-- Stage 8 B2, after Dad's review: (1) a rate or dividend yield cut needs 7 days'
-- notice, checked day by day against what the girls expect; raises can start right
-- away. (2) A dividend yield change tells the girls, like a rate change. (3) A
-- change that hasn't started can be cancelled by an appended row; kids who were
-- told get one notice, kids who weren't get none. Known answers, written first.
-- Today is Mon Oct 5, 2026, so the protected week is Oct 5 to Oct 11 and a cut can
-- start on Oct 12 at the earliest.
begin;
select plan(79);

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
create function tests.footprint() returns text language sql as $$
  select concat_ws('/', (select count(*) from public.rates), (select count(*) from public.settings),
                   (select count(*) from public.notifications), (select count(*) from public.parent_actions),
                   (select count(*) from public.cancellations));
$$;
-- kid_a's newest notice whose title matches, as "title | body".
create function tests.notice(p_like text) returns text language sql as $$
  select n.title || ' | ' || n.body from public.notifications n
   where n.account_id = (select account_id from public.profiles where username = 'kid_a') and n.title like p_like
   order by n.id desc limit 1;
$$;
create function tests.count_titled(p_like text) returns integer language sql as $$
  select count(*)::int from public.notifications n where n.title like p_like;
$$;
create function tests.rate(p_vehicle text, p_term integer, p_day text) returns numeric language sql as $$
  select (public.rate_on(p_vehicle::public.vehicle, p_term, p_day::date)).rate;
$$;
create function tests.rate_id(p_vehicle text, p_term integer, p_rate numeric, p_from text) returns bigint language sql as $$
  select id from public.rates where vehicle = p_vehicle::public.vehicle and gic_term is not distinct from p_term
     and rate = p_rate and effective_date = p_from::date order by id desc limit 1;
$$;
create function tests.setting_id(p_key text, p_value text, p_from text) returns bigint language sql as $$
  select id from public.settings where key = p_key and value = p_value and effective_date = p_from::date
   order by id desc limit 1;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 10:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.as_parent();

-- 1. Seven days' notice for a cut --------------------------------------------------------------------

create temporary table fp as select tests.footprint() as f;
select is(tests.err($$select public.add_rate('savings', null, 1.0, date '2026-10-06')$$),
  'This would lower the savings rate on Oct 6, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'Dad''s case: savings 2.0% → 1.0% from tomorrow is refused, and the message explains the rule');
select is(tests.err($$select public.add_rate('savings', null, 1.0, date '2026-10-05')$$),
  'This would lower the savings rate on Oct 5, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a cut from today is refused');
select isnt(tests.err($$select public.add_rate('savings', null, 1.0, date '2026-10-11')$$), null,
  'a cut 6 days out (Oct 11) is refused');
select is(tests.footprint(), (select f from fp), 'a refused cut leaves no rate, notice or log row');
select lives_ok($$select public.add_rate('gic', 24, 5.5, date '2026-10-12')$$, 'a cut exactly 7 days out (Oct 12) is allowed');
select lives_ok($$select public.add_rate('savings', null, 1.5, date '2026-10-13', 'The Bank of Canada cut rates')$$,
  'a savings cut 8 days out (Oct 13) is allowed');
select is(tests.rate('savings', null, '2026-10-12'), 2.000::numeric, '...savings stays 2.0% to Oct 12');
select is(tests.rate('savings', null, '2026-10-13'), 1.500::numeric, '...and is 1.5% from Oct 13');
select lives_ok($$select public.add_rate('gic', 3, 3.5, date '2026-10-05')$$, 'a raise can start today');
select is(tests.rate('gic', 3, '2026-10-05'), 3.500::numeric, '...and applies today');
select is(public.parent_change_preview('add_rate', '{"vehicle": "savings", "rate": "1.0", "effective_date": "2026-10-06"}') ->> 'problem',
  'This would lower the savings rate on Oct 6, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'the preview shows the same refusal');
select is(public.parent_settings() ->> 'cut_from_text', 'Oct 12', 'Settings says the earliest day a cut can start');

-- Day by day: stacked changes and specials.
select isnt(tests.err($$select public.add_rate('savings', null, 1.75, date '2026-10-08')$$), null,
  'stacked: 1.75% from Oct 8 lowers Oct 8–11 (2.0% expected), so it''s refused');
select lives_ok($$select public.add_rate('savings', null, 2.25, date '2026-10-08')$$,
  'stacked: 2.25% from Oct 8 is a raise for Oct 8–11 (the announced 1.5% still starts Oct 13)');
select is(tests.rate('savings', null, '2026-10-13'), 1.500::numeric, '...and the Oct 13 cut still applies');
select is(tests.err($$select public.add_rate('gic', 12, 4.0, date '2026-10-06', null, date '2026-10-09')$$),
  'This would lower the 1-year GIC rate on Oct 6, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a "special" below the regular rate inside the week is a cut');
select lives_ok($$select public.add_rate('gic', 12, 6.0, date '2026-10-06', 'Fall special', date '2026-10-09')$$,
  'a special above the regular rate can start tomorrow');
select is(tests.err($$select public.add_rate('gic', 12, 5.5, date '2026-10-07', null, date '2026-10-08')$$),
  'This would lower the 1-year GIC rate on Oct 7, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a newer special at 5.5% would replace the announced 6.0% on Oct 7–8: refused');
select lives_ok($$select public.add_rate('gic', 12, 4.0, date '2026-10-20', null, date '2026-10-25')$$,
  'a low special 15 days out is allowed (it has notice)');

-- Dividend yields, the same rule.
select is(tests.err($$select public.set_setting('dividend_yield:dow', '1.0', date '2026-10-06')$$),
  'This would lower the Dow Jones fund''s dividend rate on Oct 6, sooner than 7 days from today. A cut needs 7 days'' '
  || 'notice so the girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a dividend yield cut from tomorrow is refused');
select lives_ok($$select public.set_setting('dividend_yield:dow', '1.0', date '2026-10-12', 'Companies are paying less')$$,
  'a dividend yield cut 7 days out is allowed');
select lives_ok($$select public.set_setting('dividend_yield:tsx', '3.0')$$, 'a dividend yield raise can start today');
select is(public.setting_on('dividend_yield:dow', date '2026-10-11') || ' ' || public.setting_on('dividend_yield:dow', date '2026-10-12'),
  '1.8 1.0', 'the Dow Jones yield is 1.8% to Oct 11, 1.0% from Oct 12');

-- 2. Dividend yield notices ---------------------------------------------------------------------------

select is(tests.notice('%Dow Jones fund''s dividend rate%'),
  'The Dow Jones fund''s dividend rate drops from 1.8% to 1.0% on Oct 12 | Companies are paying less. Dividends go into '
  || 'your savings on the first market day of January, April, July and October, using the rate on that day.',
  'a yield cut: told when Dad saves it, with the old and new rate, the day, and his note');
select is(tests.count_titled('The Dow Jones fund''s dividend rate drops%'), 2, 'both kids, the test account too');
select is(tests.notice('%TSX fund''s dividend rate%'),
  'The TSX fund''s dividend rate goes up from 2.8% to 3.0% today | Dividends go into your savings on the first market '
  || 'day of January, April, July and October, using the rate on that day.',
  'a yield raise from today');
select lives_ok($$select public.set_setting('dividend_yield:tsx', '3.0', date '2026-10-20')$$, 'the same yield saved again');
select is(tests.count_titled('The TSX fund''s dividend rate%'), 2, '...tells nobody anything new');

select tests.nobody();
select public.send_rate_notices(date '2026-10-05');
select is(tests.count_titled('The TSX fund''s new dividend rate%'), 0,
  'a yield change saved today gets no "now live" notice (the first one said "today")');
select public.send_rate_notices(date '2026-10-12');
select is(tests.notice('The Dow Jones fund''s new dividend rate%'),
  'The Dow Jones fund''s new dividend rate is now 1.0% | It applies from today.', 'on Oct 12: the yield is now live');
select is(tests.count_titled('The Dow Jones fund''s new dividend rate%'), 2, '...to both kids');
select tests.as_parent();
select is(public.parent_change_preview('set_setting',
    '{"key": "dividend_yield:nasdaq100", "value": "0.8", "effective_date": "2026-10-15"}') -> 'notices',
  '[{"title": "The Nasdaq-100 fund''s dividend rate goes up from 0.6% to 0.8% on Oct 15", "kids": 2, "on": null,
     "body": "Dividends go into your savings on the first market day of January, April, July and October, using the rate on that day."},
    {"title": "The Nasdaq-100 fund''s new dividend rate is now 0.8%", "kids": 2, "on": "Oct 15",
     "body": "It applies from today."}]'::jsonb,
  'the preview shows both yield notices and when');

-- 3. Cancelling a change that hasn't started ------------------------------------------------------------

-- The savings cut announced for Oct 13 (stacked behind the 2.25% raise on Oct 8).
create temporary table fp2 as select tests.footprint() as f;
select is(public.parent_change_preview('cancel_change',
    jsonb_build_object('kind', 'rate', 'id', tests.rate_id('savings', null, 1.5, '2026-10-13'), 'note', 'Changed my mind')),
  '{"problem": null, "summary": "Cancelled: Savings rate set to 1.5% from Oct 13.", "facts": null,
    "notices": [{"title": "The savings rate change on Oct 13 is cancelled", "kids": 2, "on": null,
                 "body": "Changed my mind. On Oct 13 the savings rate will be 2.25%."}]}'::jsonb,
  'previewing a cancellation: the log line and the one notice both kids would get');
select is(tests.footprint(), (select f from fp2), '...leaving nothing behind');
select lives_ok(format($$select public.cancel_change('rate', %s, 'Changed my mind')$$,
                       tests.rate_id('savings', null, 1.5, '2026-10-13')), 'Dad cancels the Oct 13 cut');
select is(tests.rate('savings', null, '2026-10-13'), 2.250::numeric,
  'the cancelled cut no longer counts: Oct 13 gets the 2.25% raise from Oct 8');
select is(tests.notice('The savings rate change on Oct 13%'),
  'The savings rate change on Oct 13 is cancelled | Changed my mind. On Oct 13 the savings rate will be 2.25%.',
  'kids who were told get one notice');
select is(tests.count_titled('The savings rate change on Oct 13 is cancelled'), 2, '...both of them, once');
select is((select summary from public.parent_actions order by id desc limit 1),
  'Cancelled: Savings rate set to 1.5% from Oct 13.', 'it''s logged');
select is((select note from public.cancellations order by id desc limit 1), 'Changed my mind',
  'the cancellation is a new row with its note');
select is((select count(*)::int from public.rates where id = tests.rate_id('savings', null, 1.5, '2026-10-13')), 1,
  '...and the rate row is still there, unchanged');
select is((select r -> 'scheduled' from jsonb_array_elements(public.parent_settings() -> 'rates') r where r ->> 'what' = 'Savings'),
  jsonb_build_array(jsonb_build_object('id', tests.rate_id('savings', null, 2.25, '2026-10-08'),
                                       'text', '2.25% from Oct 8', 'special', false, 'from', 'Oct 8')),
  'Settings no longer shows the cancelled change as scheduled');
select is((select h ->> 'cancelled' from jsonb_array_elements(public.parent_settings() -> 'rate_history') h
            where h ->> 'text' = '1.5% from Oct 13'), 'true', '...and marks it cancelled in the history');
select tests.nobody();
select public.send_rate_notices(date '2026-10-13');
select is(tests.count_titled('The new savings rate is now 1.5%'), 0, 'a cancelled change never says it''s live');
select tests.as_parent();

select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('savings', null, 1.5, '2026-10-13'))),
  'That change is already cancelled.', 'it can''t be cancelled twice');
select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 3, 3.5, '2026-10-05'))),
  'This change has already started, so it can''t be cancelled. Save a new one instead.', 'a change in force can''t be cancelled');
select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('savings', null, 2.25, '2026-10-08'))),
  'Cancelling this would lower the savings rate on Oct 8, sooner than 7 days from today. The girls were promised it, '
  || 'so a raise can only be cancelled 7 or more days before it starts.',
  'cancelling a promised raise inside the week is refused, like a cut');
select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 12, 6.0, '2026-10-06'))),
  'Cancelling this would lower the 1-year GIC rate on Oct 6, sooner than 7 days from today. The girls were promised it, '
  || 'so a raise can only be cancelled 7 or more days before it starts.', '...and so is cancelling a special inside the week');
select lives_ok($$select public.add_rate('gic', 1, 3.0, date '2026-10-20')$$, 'a raise for Oct 20');
select lives_ok(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 1, 3.0, '2026-10-20')),
  '...can be cancelled 7 or more days before it starts');
select lives_ok(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 12, 4.0, '2026-10-20')),
  'a special can be cancelled before it starts');
select is(tests.notice('The 1-year GIC special from Oct 20%'),
  'The 1-year GIC special from Oct 20 to Oct 25 is cancelled | The 1-year GIC rate stays at 5.0%.',
  '...with a notice saying what it stays at');

-- Settings: told or not told.
select public.set_setting('deposit_cap_cents', '120000', date '2026-10-20');
select lives_ok(format($$select public.cancel_change('setting', %s, 'Not yet')$$,
                       tests.setting_id('deposit_cap_cents', '120000', '2026-10-20')), 'Dad cancels a cap change');
select is(tests.notice('The deposit limit change%'),
  'The deposit limit change on Oct 20 is cancelled | Not yet. The deposit limit stays at $1,000.00.',
  'the girls were told about the cap, so they''re told it''s cancelled');
select is(public.setting_on('deposit_cap_cents', date '2026-10-20'), '100000', 'the cap stays $1,000.00 on Oct 20');

select public.set_setting('dividend_yield:nasdaq100', '0.8', date '2026-10-20');
select lives_ok(format($$select public.cancel_change('setting', %s)$$,
                       tests.setting_id('dividend_yield:nasdaq100', '0.8', '2026-10-20')), 'Dad cancels a yield raise (15 days out)');
select is(tests.notice('The Nasdaq-100 fund''s dividend rate change%'),
  'The Nasdaq-100 fund''s dividend rate change on Oct 20 is cancelled | The Nasdaq-100 fund''s dividend rate stays at 0.6%.',
  '...and the girls are told');
select tests.nobody();
select public.send_rate_notices(date '2026-10-20');
select is(tests.count_titled('The Nasdaq-100 fund''s new dividend rate%'), 0, '...and never told it''s live');
select tests.as_parent();

create temporary table quiet as select (select count(*) from public.notifications) as n;
select public.set_setting('inflation_rate', '2.5', date '2026-10-20');
select public.cancel_change('setting', tests.setting_id('inflation_rate', '2.5', '2026-10-20'));
select public.set_setting('request_expiry_days', '10', date '2026-10-20');
select public.cancel_change('setting', tests.setting_id('request_expiry_days', '10', '2026-10-20'));
select public.set_setting('feature:badges', 'everyone', date '2026-10-20');
select public.cancel_change('setting', tests.setting_id('feature:badges', 'everyone', '2026-10-20'));
select is((select count(*) from public.notifications), (select n from quiet),
  'inflation, request expiry and a feature switch: the girls weren''t told, so a cancellation tells them nothing');
select is(public.setting_on('inflation_rate', date '2026-10-20') || ' ' || public.setting_on('request_expiry_days', date '2026-10-20'),
  '2.0 7', 'cancelled settings don''t count');
select tests.nobody();
select public.expire_requests(date '2026-10-20');
select is((select count(*)::int from public.notifications where type = 'rule_change'), 0,
  'on Oct 20 the cancelled expiry change sends no notice');
select tests.clock('2026-10-20 10:00');
select is(public.feature_enabled('badges', (select account_id from public.profiles where username = 'kid_a')), false,
  'a cancelled feature switch doesn''t switch on');
select tests.clock('2026-10-05 10:00');

-- 4. The deposit cap: the same 7-day rule (a cut shrinks her room to deposit) ---------------------------

select tests.as_parent();
create temporary table fp3 as select tests.footprint() as f;
select is(tests.err($$select public.set_setting('deposit_cap_cents', '80000', date '2026-10-06')$$),
  'This would lower the deposit limit on Oct 6, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a cap cut from tomorrow is refused, with the rule');
select is(tests.err($$select public.set_setting('deposit_cap_cents', '80000')$$),
  'This would lower the deposit limit on Oct 5, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'a cap cut from today (the default day) is refused');
select is(tests.footprint(), (select f from fp3), 'a refused cap cut leaves no setting, notice or log row');
select is(public.parent_change_preview('set_setting', '{"key": "deposit_cap_cents", "value": "80000", "effective_date": "2026-10-11"}') ->> 'problem',
  'This would lower the deposit limit on Oct 11, sooner than 7 days from today. A cut needs 7 days'' notice so the '
  || 'girls have time to react: start it on Oct 12 or later. A raise can start right away.',
  'the preview shows the refusal for 6 days out');
select lives_ok($$select public.set_setting('deposit_cap_cents', '80000', date '2026-10-12')$$,
  'a cap cut exactly 7 days out is allowed');
select is(public.setting_on('deposit_cap_cents', date '2026-10-11') || ' ' || public.setting_on('deposit_cap_cents', date '2026-10-12'),
  '100000 80000', '...$1,000.00 to Oct 11, $800.00 from Oct 12');
select is(tests.notice('The deposit limit goes down%'),
  'The deposit limit goes down from $1,000.00 to $800.00 on Oct 12 | This is the most you can put in, minus what you take '
  || 'out. Interest and gains don''t count. If you''ve already put in more than that, nothing is taken away. You just can''t add more for now.',
  '...and the girls are told a week ahead');
select lives_ok($$select public.set_setting('deposit_cap_cents', '150000')$$, 'a cap raise can start today');
select is(public.setting_on('deposit_cap_cents', date '2026-10-05'), '150000', '...and applies today');
select lives_ok($$select public.set_setting('deposit_cap_cents', '160000', date '2026-10-08')$$, 'a cap raise for Oct 8');
select is(tests.err(format($$select public.cancel_change('setting', %s)$$, tests.setting_id('deposit_cap_cents', '160000', '2026-10-08'))),
  'Cancelling this would lower the deposit limit on Oct 8, sooner than 7 days from today. The girls were promised it, '
  || 'so a raise can only be cancelled 7 or more days before it starts.',
  'cancelling a promised cap raise inside the week is refused');

-- Refusals and who may call.
select tests.as_parent();
select is(tests.err('select public.cancel_change(''rate'', 999999)'), 'There''s no rate change #999999.', 'an unknown change');
select is(tests.err('select public.cancel_change(''request'', 1)'), 'Only a rate or a setting change can be cancelled.',
  'only rates and settings');
select tests.as_kid('kid_a');
select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 1, 3.0, '2026-10-20'))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t cancel');
select tests.as_parent('aal1');
select is(tests.err(format($$select public.cancel_change('rate', %s)$$, tests.rate_id('gic', 1, 3.0, '2026-10-20'))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...nor a parent without the code');
select tests.nobody();
select is(tests.err('update public.cancellations set note = ''x'''),
  'cancellations is append-only: update is not allowed. Add a new row instead.', 'cancellations can''t be edited');
select is(tests.err('delete from public.cancellations'),
  'cancellations is append-only: delete is not allowed. Add a new row instead.', '...or removed, even by the owner');

select * from finish();
rollback;
