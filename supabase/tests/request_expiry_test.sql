-- Stage 8 B1: request expiry is a parent setting (default 7 days, 3 to 30). Each
-- request's expiry is fixed when she asks; a change applies only to new requests,
-- and the girls are told when it takes effect. Known answers, written first.
begin;
select plan(60);

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
-- A deposit request from kid A, named so the tests can find it.
create temporary table named (label text primary key, id bigint);
create function tests.deposit(p_label text, p_cents bigint) returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  perform tests.as_kid('kid_a');
  v_id := public.request_deposit(p_cents);
  insert into named values (p_label, v_id);
  perform tests.nobody();
  return v_id;
end;
$$;
create function tests.id(p_label text) returns bigint language sql as $$ select id from named where label = p_label; $$;
create function tests.req(p_label text) returns public.requests language sql as $$
  select * from public.requests where id = tests.id(p_label);
$$;
create function tests.expiry_notices() returns table (account text, title text, body text) language sql as $$
  select a.name, n.title, n.body from public.notifications n join public.accounts a on a.id = n.account_id
   where n.type = 'rule_change' order by n.created_at, a.name;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 10:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);

-- 1. The default: 7 days, fixed when she asks ---------------------------------------------------

select is(public.setting_on('request_expiry_days', date '2026-10-05'), '7', 'the starting setting is 7 days');
select tests.deposit('d7', 5000);
select is((tests.req('d7')).expires_at, '2026-10-12 10:00-06'::timestamptz,
  'a deposit asked for at 10:00 am Oct 5 expires at 10:00 am Oct 12 (7 × 24 hours)');
select tests.as_kid('kid_a');
select public.request_deposit(1000);
select tests.nobody();
select is((select expires_at from public.requests order by id desc limit 1), '2026-10-12 10:00-06'::timestamptz,
  'every deposit and withdrawal gets its expiry when she asks');

-- Moves never wait for Dad, so they have no expiry.
select tests.as_parent();
select public.approve_request((select id from public.requests order by id desc limit 1));
select tests.as_kid('kid_a');
select public.buy_gic(1000, 1);
select tests.nobody();
select is((select expires_at from public.requests where type = 'move'), null, 'a move has no expiry');

-- Fixed: nobody can change it, and whatever an insert says is replaced by the rule.
select is(tests.err($$update public.requests set expires_at = expires_at + interval '1 day' where id = tests.id('d7')$$),
  'A request''s expiry is set when she asks and can''t be changed.', 'nobody can move a request''s expiry, not even the owner');
select is(tests.err($$update public.requests set expires_at = null where id = tests.id('d7')$$),
  'A request''s expiry is set when she asks and can''t be changed.', '...or remove it');
insert into public.requests (account_id, type, to_vehicle, amount_cents, expires_at)
  values (tests.acct('kid_b'), 'deposit', 'savings', 500, '2030-01-01');
select is((select expires_at from public.requests order by id desc limit 1), '2026-10-12 10:00-06'::timestamptz,
  'an expiry written by hand is replaced by the rule');
delete from public.requests where id = (select max(id) from public.requests);

-- 2. The setting: 3 to 30 whole days --------------------------------------------------------------

select tests.as_parent();
select is(tests.err($$select public.set_setting('request_expiry_days', '2', date '2026-10-06')$$),
  'Request expiry is a whole number of days from 3 to 30.', '2 days is too short');
select is(tests.err($$select public.set_setting('request_expiry_days', '31', date '2026-10-06')$$),
  'Request expiry is a whole number of days from 3 to 30.', '31 days is too long');
select is(tests.err($$select public.set_setting('request_expiry_days', '7.5', date '2026-10-06')$$),
  'Request expiry is a whole number of days from 3 to 30.', 'whole days only');
select is(tests.err($$select public.set_setting('request_expiry_days', 'ten', date '2026-10-06')$$),
  'Request expiry is a whole number of days from 3 to 30.', 'a number');
select is(tests.err($$select public.set_setting('request_expiry_days', '3', date '2026-10-06')$$), null, '3 days is allowed');
select is(tests.err($$select public.set_setting('request_expiry_days', '30', date '2026-10-06')$$), null, '30 days is allowed');
select is(tests.err($$select public.set_setting('request_expiry_days', '010', date '2026-10-06')$$),
  'Request expiry is a whole number of days from 3 to 30.', 'no padded numbers');
select tests.as_parent('aal1');
select is(tests.err($$select public.set_setting('request_expiry_days', '10', date '2026-10-06')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'parent with the code only');

-- Dad lengthens it to 10 days, starting tomorrow.
select tests.as_parent();
select public.set_setting('request_expiry_days', '10', date '2026-10-06', 'Busy week at work');
select is((select summary from public.parent_actions order by id desc limit 1),
  'Request expiry set to 10 days from Oct 6.', 'logged in plain words');
select is((select value from public.settings where key = 'request_expiry_days' order by id desc limit 1), '10',
  'stored as a whole number of days');
select is((select count(*)::int from tests.expiry_notices()), 0, 'nothing is sent yet: it starts tomorrow');

-- A request made today still gets 7 days.
select tests.clock('2026-10-05 15:00');
select tests.deposit('d7b', 2000);
select is((tests.req('d7b')).expires_at, '2026-10-12 15:00-06'::timestamptz, 'asked today: 7 days, the setting in force today');

-- 3. The notice, sent when the change takes effect ------------------------------------------------

select tests.clock('2026-10-06 16:30');
select is((public.expire_requests('2026-10-06')) ->> 'status', 'ok', 'the nightly expiry job runs for Oct 6');
select results_eq($$select * from tests.expiry_notices()$$,
  $$values ('Kid A'::text, 'Dad now has up to 10 days to answer your requests'::text,
            'If he hasn''t said yes or no to a deposit or withdrawal by then, it''s cancelled and you can ask again. Requests you''ve already made keep the time they had.'::text),
           ('Kid B', 'Dad now has up to 10 days to answer your requests',
            'If he hasn''t said yes or no to a deposit or withdrawal by then, it''s cancelled and you can ask again. Requests you''ve already made keep the time they had.')$$,
  'on the day it takes effect, every kid is told');
select public.expire_requests('2026-10-06');
select is((select count(*)::int from tests.expiry_notices()), 2, 'running the night again sends nothing new');

-- 4. New requests get 10 days; old ones keep 7 -----------------------------------------------------

select tests.clock('2026-10-06 10:00');
select tests.deposit('d10a', 3000);
select tests.deposit('d10b', 4000);
select is((tests.req('d10a')).expires_at, '2026-10-16 10:00-06'::timestamptz, 'asked on Oct 6: 10 days (240 hours)');
select is((tests.req('d7')).expires_at, '2026-10-12 10:00-06'::timestamptz, 'the Oct 5 request still has its 7 days');

-- Day 7: the two Oct 5 requests expire, at their own times, saying 7 days.
select tests.clock('2026-10-12 16:30');
select public.expire_requests('2026-10-12');
select results_eq($$select status::text, decided_at from public.requests where id in (tests.id('d7'), tests.id('d7b')) order by id$$,
  $$values ('expired'::text, '2026-10-12 10:00-06'::timestamptz), ('expired', '2026-10-12 15:00-06'::timestamptz)$$,
  'the 7-day requests expire on Oct 12, each at its own expiry time');
select is((select body from public.notifications where dedupe_key = 'expired:' || tests.id('d7')),
  'Your request to put in $50.00 waited 7 days without an answer, so it was cancelled. You can ask again any time.',
  'her notice says 7 days');
select is((tests.req('d10a')).status::text, 'pending', 'the 10-day requests are still waiting');

-- Dad can approve up to the minute before the expiry, not at it.
select tests.clock('2026-10-16 09:59');
select tests.as_parent();
select public.approve_request(tests.id('d10a'));
select is((tests.req('d10a')).status::text, 'approved', 'approving at 9:59 am Oct 16 works');
select tests.clock('2026-10-16 10:00');
select is(tests.err($$select public.approve_request(tests.id('d10b'))$$),
  'This request ran out of time on Oct 16 at 10:00 am (after 10 days), so it has expired. She can make a new one.',
  'at 10:00 am it has run out of time, and the message says when');
select tests.clock('2026-10-16 16:30');
select public.expire_requests('2026-10-16');
select results_eq($$select status::text, decided_at from public.requests where id = tests.id('d10b')$$,
  $$values ('expired'::text, '2026-10-16 10:00-06'::timestamptz)$$, 'it expires after 10 days');
select is((select body from public.notifications where dedupe_key = 'expired:' || tests.id('d10b')),
  'Your request to put in $40.00 waited 10 days without an answer, so it was cancelled. You can ask again any time.',
  'her notice says 10 days');

-- A withdrawal's hold is released after its own expiry.
select tests.clock('2026-10-17 08:00');
select tests.as_kid('kid_a');
select public.request_withdrawal(500);
select tests.nobody();
select is((select expires_at from public.requests order by id desc limit 1), '2026-10-27 08:00-06'::timestamptz,
  'a withdrawal gets 10 days too');

-- 5. A change that starts today is told right away -----------------------------------------------

select tests.clock('2026-10-17 09:00');
select tests.as_parent();
select public.set_setting('request_expiry_days', '14');
select is((select count(*)::int from tests.expiry_notices() where title like '%14 days%'), 2,
  'starting today: every kid is told when Dad saves');
select tests.clock('2026-10-17 16:30');
select public.expire_requests('2026-10-17');
select is((select count(*)::int from tests.expiry_notices() where title like '%14 days%'), 2,
  '...and the nightly job doesn''t tell them twice');
select tests.clock('2026-10-17 17:00');
select tests.as_parent();
select public.set_setting('request_expiry_days', '14');
select is((select count(*)::int from tests.expiry_notices()), 4, 'saving the same number again tells nobody');
select is((select summary from public.parent_actions order by id desc limit 1), 'Request expiry set to 14 days from Oct 17.',
  '(but it is still logged)');
select tests.deposit('d14', 1000);
select is((tests.req('d14')).expires_at, '2026-10-31 17:00-06'::timestamptz, 'a request after the change: 14 days');

-- A catch-up night (a missed day) still tells them, once, on the right day.
select tests.as_parent();
select public.set_setting('request_expiry_days', '12', date '2026-10-19');
select tests.clock('2026-10-20 16:30');
select public.expire_requests('2026-10-19');
select public.expire_requests('2026-10-20');
select is((select count(*)::int from tests.expiry_notices() where title like '%12 days%'), 2,
  'a change on a missed night is told when the catch-up runs, once');
-- A change back to the same value as before isn't news.
select tests.as_parent();
select public.set_setting('request_expiry_days', '12', date '2026-10-22');
select tests.clock('2026-10-22 16:30');
select public.expire_requests('2026-10-22');
select is((select count(*)::int from tests.expiry_notices()), 6, 'no notice when the number doesn''t change');

-- 6. Approvals screen and the 48-hour warning use each request's own expiry -----------------------

select tests.clock('2026-10-30 18:00');
select tests.as_parent();
select results_eq(
  $$select r ->> 'expires', (r ->> 'expires_seconds')::bigint from jsonb_array_elements(public.parent_inbox() -> 'requests') r
     where (r ->> 'id')::bigint = tests.id('d14')$$,
  $$values ('Oct 31 at 5:00 pm'::text, 82800::bigint)$$,
  'the Approvals screen shows the request''s own expiry: 23 hours left');

-- 7. Only the expiry lines of the two Part A originals changed -----------------------------------
--
-- Swap the new lines back for the committed ones: the fingerprint is the committed one.

select is(md5(replace(
  (select prosrc from pg_proc where proname = 'approve_request_unlogged'),
  $new$  if v_now >= v_req.expires_at then
    raise exception 'This request ran out of time on % (after % days), so it has expired. She can make a new one.',
      public.fmt_moment(v_req.expires_at), public.request_days(v_req);
  end if;$new$,
  $old$  if v_now >= v_req.created_at + interval '168 hours' then
    raise exception 'This request is more than 7 days old, so it has expired. She can make a new one.';
  end if;$old$)),
  '758c6bc96c34b8c623881ebf65e2cf92', 'approve_request_unlogged: only the expiry check changed');

select is(md5(replace(replace(
  (select prosrc from pg_proc where proname = 'set_setting_unlogged'),
  $new$  elsif v_key = 'request_expiry_days' then
    if v_value !~ '^[1-9]\d?$' or v_value::integer not between 3 and 30 then
      raise exception 'Request expiry is a whole number of days from 3 to 30.';
    end if;
  elsif v_key = 'launched_at' then$new$,
  $old$  elsif v_key = 'launched_at' then$old$),
  $new$  if v_key = 'request_expiry_days' and v_effective = v_today then
    perform public.send_expiry_notices(v_id);
  end if;
  return v_id;$new$,
  $old$  return v_id;$old$)),
  'c9802e47266c30251f14d12ed1de6d23', 'set_setting_unlogged: only the new key and its notice were added');

-- 8. The nightly check: nothing waits past its expiry ---------------------------------------------

select tests.clock('2026-11-05 16:30');
insert into public.job_runs (job, run_for_date, status, finished_at)
  select j::public.job_name, d::date, 'ok', public.app_now()
    from unnest(array['expire', 'splits', 'settle', 'gic_maturity', 'auto_move', 'dividends', 'monthly', 'rate_notices']) j
   cross join generate_series(date '2026-10-05', date '2026-11-05', interval '1 day') d;
insert into public.job_runs (job, run_for_date, status, finished_at)
  select 'interest', d::date, 'ok', public.app_now() from generate_series(date '2026-10-05', date '2026-11-04', interval '1 day') d;
-- The Oct 17 withdrawal ran out of time on Oct 27: the job expires it (up to the end of Oct 27 only).
select public.expire_requests('2026-10-27');
-- d14 ran out of time on Oct 31 but nothing expired it (the job "ran" without doing so).
select ok(exists (select 1 from jsonb_array_elements(public.reconcile_account(tests.acct('kid_a'), date '2026-11-05',
                    date '2026-11-05', date '2026-11-04')) p where p ->> 'code' = 'expiry'),
  'a request still waiting after its expiry, once the job has run, is a problem');
select is((select p -> 'details' ->> 'request_id' from jsonb_array_elements(public.reconcile_account(tests.acct('kid_a'),
             date '2026-11-05', date '2026-11-05', date '2026-11-04')) p where p ->> 'code' = 'expiry'),
  tests.id('d14')::text, '...naming the request');
select ok(not exists (select 1 from jsonb_array_elements(public.reconcile_account(tests.acct('kid_a'), date '2026-10-30',
                        date '2026-10-30', date '2026-10-29')) p where p ->> 'code' = 'expiry'),
  'before its expiry it''s fine');
select ok(not exists (select 1 from jsonb_array_elements(public.reconcile_account(tests.acct('kid_a'), date '2026-11-05',
                        date '2026-10-30', date '2026-10-29')) p where p ->> 'code' = 'expiry'),
  'and it isn''t a problem while the expiry job hasn''t caught up');
select public.expire_requests('2026-11-05');
select ok(not exists (select 1 from jsonb_array_elements(public.reconcile_account(tests.acct('kid_a'), date '2026-11-05',
                        date '2026-11-05', date '2026-11-04')) p where p ->> 'code' = 'expiry'),
  'once expired, all clear');
select is(public.recon_alert_message('expiry'),
  'A request was still waiting after it ran out of time. Her figures show "Updating…" until a later check finds them right.',
  'the alert says what''s wrong');

-- 9. Who may call the new helpers ------------------------------------------------------------------

select ok(not has_function_privilege('authenticated', 'public.send_expiry_notices(bigint, boolean)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.send_expiry_notices(bigint, boolean)', 'EXECUTE'),
  'only the database itself sends expiry notices');
select ok(not has_function_privilege('authenticated', 'public.reconcile_account_core(uuid, date, date, date)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.reconcile_account_core(uuid, date, date, date)', 'EXECUTE')
          and not has_function_privilege('service_role', 'public.reconcile_account_core(uuid, date, date, date)', 'EXECUTE'),
  'the wrapped nightly check is internal');
select is(public.request_days(tests.req('d14')), 14, 'request_days: how long a request had');

-- 10. The Settings screen: what's set, and a preview before saving ----------------------------------

select tests.as_parent();
select is(public.parent_settings() -> 'expiry' ->> 'days', '12', 'Settings shows the rule in force today (12 days)');
select results_eq(
  $$select h ->> 'days', h ->> 'from', h ->> 'who' from jsonb_array_elements(public.parent_settings() -> 'expiry' -> 'history') h$$,
  $$values ('12'::text, 'Oct 22'::text, 'Parent'::text), ('12', 'Oct 19', 'Parent'), ('14', 'Oct 17', 'Parent'),
           ('14', 'Oct 17', 'Parent'), ('10', 'Oct 6', 'Parent'), ('7', 'Jan 1', 'Starting rule')$$,
  'the history, newest change first, with who changed it');

create temporary table before_preview as
  select (select count(*) from public.settings) as s, (select count(*) from public.notifications) as n,
         (select count(*) from public.parent_actions) as a;
create temporary table preview_future as
  select public.parent_change_preview('set_setting',
    '{"key": "request_expiry_days", "value": "20", "effective_date": "2026-11-10", "note": "Holidays"}') as p;
select is((select p from preview_future),
  '{"problem": null, "summary": "Request expiry set to 20 days from Nov 10.",
    "facts": {"before": "12 days", "after": "20 days", "from": "Nov 10"},
    "notices": [{"title": "Dad now has up to 20 days to answer your requests", "kids": 2, "on": "Nov 10",
                 "body": "If he hasn''t said yes or no to a deposit or withdrawal by then, it''s cancelled and you can ask again. Requests you''ve already made keep the time they had."}]}'::jsonb,
  'a change for Nov 10: the log line, and the notice both kids will get on Nov 10');
select ok((select s = (select count(*) from public.settings) and n = (select count(*) from public.notifications)
              and a = (select count(*) from public.parent_actions) from before_preview),
  'the preview leaves no setting, notice or log row behind');
select is(public.parent_change_preview('set_setting', '{"key": "request_expiry_days", "value": "2"}') ->> 'problem',
  'Request expiry is a whole number of days from 3 to 30.', 'a bad number: the real message');
select is(public.parent_change_preview('set_setting', '{"key": "request_expiry_days", "value": "12"}') -> 'notices',
  '[]'::jsonb, 'the same number as now: nobody would be told');
select tests.as_kid('kid_a');
select is(tests.err($$select public.parent_change_preview('set_setting', '{"key": "request_expiry_days", "value": "9"}')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t preview');
select is(tests.err('select public.parent_settings()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or see Settings');

-- The dry run runs with in_preview() on (a stand-in for future outside-world code).
create function tests.must_be_in_preview() returns trigger language plpgsql as $$
begin
  if not public.in_preview() then
    raise exception 'outside preview';
  end if;
  return new;
end;
$$;
create trigger t_preview_settings before insert on public.settings
  for each row execute function tests.must_be_in_preview();
select tests.as_parent();
select is(public.parent_change_preview('set_setting', '{"key": "request_expiry_days", "value": "9"}') ->> 'problem', null,
  'the settings preview runs its dry run with in_preview() on');
drop trigger t_preview_settings on public.settings;

select * from finish();
rollback;
