-- Stage 8 part A: the parent action log, previews that stay inside the database,
-- and the Approvals screen's reads (parent_inbox, parent_decision_preview).
begin;
select plan(70);

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
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb),
           (v_acct, 1, 'parent', v_user, null); -- Dad's countersignature (pre-launch audit)
  return v_acct;
end;
$$;
-- The message a statement fails with (null if it succeeds; its effects are rolled back either way).
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ran' using errcode = 'BB999';
exception
  when sqlstate 'BB999' then return null;
  when others then return sqlerrm;
end;
$$;
-- Everything a decision preview must leave untouched.
create function tests.footprint() returns text language sql as $$
  select concat_ws('/',
    (select count(*) from public.requests where status = 'pending'),
    (select count(*) from public.questions where status = 'open'),
    (select count(*) from public.transactions), (select count(*) from public.notifications),
    (select count(*) from public.parent_actions),
    (select coalesce(sum(held_cents), 0) from public.requests where status = 'pending'));
$$;
create function tests.last_action() returns public.parent_actions language sql as $$
  select * from public.parent_actions order by id desc limit 1;
$$;
create function tests.inbox() returns jsonb language sql as $$ select public.parent_inbox(); $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- 1. The committed functions are unchanged -----------------------------------------------------
--
-- Each committed parent function (and move_preview) was renamed, not edited. These
-- fingerprints are md5(prosrc) of the committed bodies, taken from the database
-- before the stage 8 migration ran. If a body ever changes, this fails.
-- Stage 8 B1 (request expiry, Dad's decision) changed two on purpose: their new
-- fingerprints are below, and request_expiry_test.sql swaps the old lines back and
-- gets the committed fingerprints, proving nothing else in them changed.

select is(
  (select string_agg(p.proname::text || ' ' || md5(p.prosrc), ', ' order by p.proname::text)
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('approve_request_unlogged', 'decline_request_unlogged', 'answer_question_unlogged',
                        'acknowledge_alert_unlogged', 'add_rate_unlogged', 'set_setting_unlogged',
                        'move_preview_unflagged')),
  'acknowledge_alert_unlogged f799cbab72b3f4c8c5ba9a4d0f906055, add_rate_unlogged 0625ee023bd0b7325f099caec21c512c, '
  || 'answer_question_unlogged fca9682d14eb34d86275dde11a6fe1f0, approve_request_unlogged 8bc03e82aa00f8f603d0c3c7d0f3725f, '
  || 'decline_request_unlogged cb21305de809debe9d85f1fd8980a7f3, move_preview_unflagged 405fbd6fc29c261492392b625ce8f66e, '
  || 'set_setting_unlogged 0f97833200dcaef970a9115b4563c47e',
  'the originals are byte for byte as committed (approve_request_unlogged and set_setting_unlogged as changed on purpose in stage 8 B1; request_expiry_test proves only those lines changed; add_rate_unlogged as changed on purpose in the pre-launch audit, for the notice when a special hides a change: audit_fixes_test checks it)');

select is(
  array(select w.proname::text
          from pg_proc w
          join pg_proc i on i.pronamespace = w.pronamespace
                        and i.proname = w.proname || case when w.proname = 'move_preview' then '_unflagged' else '_unlogged' end
         where w.pronamespace = 'public'::regnamespace
           and (pg_get_function_arguments(w.oid) is distinct from pg_get_function_arguments(i.oid)
                or pg_get_function_result(w.oid) is distinct from pg_get_function_result(i.oid)
                or w.prosecdef is distinct from i.prosecdef
                or w.proconfig is distinct from i.proconfig)),
  '{}'::text[],
  'each new function has the same arguments, defaults, result, SECURITY DEFINER and search_path as the one it wraps');

select is(
  (select count(*)::int from pg_proc w
    where w.pronamespace = 'public'::regnamespace
      and w.proname in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                        'add_rate', 'set_setting', 'move_preview')),
  7, 'all seven names still exist, once each');

select is(
  array(select w.proname::text from pg_proc w
         where w.pronamespace = 'public'::regnamespace
           and w.proname in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                             'add_rate', 'set_setting', 'move_preview')
           and (w.prosrc ~* '\m(insert|update|delete|truncate)\M'
                or (select count(*) from regexp_matches(w.prosrc, 'public\.[a-z_]+_(unlogged|unflagged)\(', 'g')) <> 1)),
  '{}'::text[],
  'each wrapper calls the committed function exactly once and writes nothing itself (only through log_parent_action)');

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and (p.proname like '%\_unlogged' or p.proname like '%\_unflagged' or p.proname = 'log_parent_action')
           and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                or has_function_privilege('anon', p.oid, 'EXECUTE')
                or has_function_privilege('service_role', p.oid, 'EXECUTE'))),
  '{}'::text[],
  'nobody can call the unlogged functions or the log writer directly, so nothing skips the log');

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                             'add_rate', 'set_setting', 'move_preview')
           and not (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                    and not has_function_privilege('anon', p.oid, 'EXECUTE')
                    and not has_function_privilege('service_role', p.oid, 'EXECUTE'))),
  '{}'::text[],
  'the wrappers have exactly the grants the committed functions had (signed-in users only)');

-- 2. Setup: kid A (real) and kid B (a test account) ---------------------------------------------

select tests.clock('2026-10-01 08:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);

select tests.as_kid('kid_a');
select public.request_deposit(8000);
select tests.as_parent();
select public.approve_request((select max(id) from public.requests), 'Birthday money');

-- 2b. Nothing can skip the log --------------------------------------------------------------------
--
-- The renamed originals (and the log writer) run only inside their logging wrappers.
-- Proved three ways: no role but the owner may execute them; actually calling them
-- as every app role is refused; and nothing else in the database calls them.

select is(
  array(select r.rolname::text || ': ' || p.proname::text
          from pg_proc p cross join pg_roles r
         where p.pronamespace = 'public'::regnamespace
           and (p.proname like '%\_unlogged' or p.proname = 'move_preview_unflagged' or p.proname = 'log_parent_action')
           and not r.rolsuper and r.oid <> p.proowner
           and has_function_privilege(r.oid, p.oid, 'EXECUTE')
         order by 1),
  '{}'::text[],
  'no role but the owner (not anon, authenticated, service_role, authenticator or any Supabase role) may execute them');

select is(
  array(select n.nspname::text || '.' || p.proname::text || ' calls ' || m[1]
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         cross join lateral regexp_matches(p.prosrc,
           '\m(approve_request_unlogged|decline_request_unlogged|answer_question_unlogged|acknowledge_alert_unlogged|add_rate_unlogged|set_setting_unlogged|move_preview_unflagged|log_parent_action)\(', 'g') m
         where n.nspname not in ('pg_catalog', 'information_schema', 'tests')
           and not (n.nspname = 'public' and (
                 p.proname || '_unlogged' = m[1]
              or (p.proname = 'move_preview' and m[1] = 'move_preview_unflagged')
              or (m[1] = 'log_parent_action' and p.proname in ('approve_request', 'decline_request', 'answer_question',
                                                                 'acknowledge_alert', 'add_rate', 'set_setting',
                                                                 -- B2: three new parent actions, logged by themselves.
                                                                 'edit_note', 'edit_glossary', 'cancel_change',
                                                                 -- B3: Fix a mistake, logged by itself.
                                                                 'correct_savings',
                                                                 -- B4: Dad countersigning, logged by itself.
                                                                 'countersign_agreement',
                                                                 -- Pre-launch audit: fixing a close, recording a closure.
                                                                 'correct_fund_price', 'record_market_closure'))))
         order by 1),
  '{}'::text[],
  'nothing in the database calls an original except its own logging wrapper (so no path skips the log)');


-- 3. The log ---------------------------------------------------------------------------------

select results_eq(
  $$select done_by, action, account_id, target_id, summary, done_at, details ->> 'note'
      from public.parent_actions$$,
  $$values ('00000000-0000-0000-0000-00000000000f'::uuid, 'approve_request'::text, tests.acct('kid_a'),
            (select max(id) from public.requests), 'Approved Kid A''s $80.00 deposit.'::text,
            '2026-10-01 08:00-06'::timestamptz, 'Birthday money'::text)$$,
  'approving writes one log row: who, what, which kid, when (the app clock) and the note');

select tests.clock('2026-10-01 09:00');
select tests.as_kid('kid_a');
select public.request_deposit(5000);
select tests.as_parent();
select public.decline_request((select max(id) from public.requests), 'Wait until after Christmas');
select results_eq(
  $$select action, summary, details ->> 'reason', done_at from tests.last_action()$$,
  $$values ('decline_request'::text, 'Declined Kid A''s $50.00 deposit.'::text, 'Wait until after Christmas'::text,
            '2026-10-01 09:00-06'::timestamptz)$$,
  'declining is logged with the reason');

select tests.as_kid('kid_a');
select public.ask_question('Is my deposit right?', (select max(id) from public.transactions));
select tests.as_parent();
select public.answer_question((select max(id) from public.questions), 'Yes, all $80.00 is there.');
select results_eq(
  $$select action, account_id, summary, details ->> 'reply' from tests.last_action()$$,
  $$values ('answer_question'::text, tests.acct('kid_a'), 'Answered Kid A''s question.'::text,
            'Yes, all $80.00 is there.'::text)$$,
  'answering a question is logged with the reply');

insert into public.alerts (kind, account_id, message) values ('test', tests.acct('kid_a'), 'Something to look at');
select public.acknowledge_alert((select max(id) from public.alerts));
select results_eq(
  $$select action, summary from tests.last_action()$$,
  $$values ('acknowledge_alert'::text, 'Acknowledged an alert: Something to look at'::text)$$,
  'acknowledging an alert is logged');

select public.add_rate('savings', null, 1.5, date '2026-10-08', 'The Bank of Canada cut rates');
select public.add_rate('gic', 12, 6, date '2026-10-02', null, date '2026-10-09');
select results_eq(
  $$select action, target_id, summary from public.parent_actions where action = 'add_rate' order by id$$,
  $$values ('add_rate'::text, (select min(id) from public.rates where created_by is not null),
            'Savings rate set to 1.5% from Oct 8.'::text),
           ('add_rate', (select max(id) from public.rates), 'Special: 1-year GIC at 6.0% from Oct 2 to Oct 9.')$$,
  'rate changes and specials are logged, pointing at their rate row');

select public.set_setting('deposit_cap_cents', '150000', null, 'You''re both saving well');
select public.set_setting('feature:wishlist', 'test');
select results_eq(
  $$select summary from public.parent_actions where action = 'set_setting' order by id$$,
  $$values ('Deposit cap set to $1,500.00 from Oct 1.'::text),
           ('Feature "wishlist" switched to test accounts only from Oct 1.')$$,
  'settings changes are logged in plain words');

select is((select count(*)::int from public.parent_actions), 8, 'eight actions, eight log rows');

-- A refused action logs nothing, and gives exactly the message it always did.
select tests.clock('2026-10-01 10:00');
select tests.as_kid('kid_a');
select public.request_withdrawal(2000);
select tests.as_parent();
select is(tests.err('select public.approve_request((select max(id) from public.requests))'),
  'Withdrawals wait 24 hours before they can be approved. This one can be approved from Oct 2 at 10:00 am.',
  'a refused approval gives the committed message, word for word');
select is((select count(*)::int from public.parent_actions), 8, '...and logs nothing');
select is(tests.err('select public.decline_request((select max(id) from public.requests), ''  '')'),
  'Please give a reason, so she knows why.', 'a decline without a reason is refused as before');
select tests.as_parent('aal1');
select is(tests.err('select public.set_setting(''inflation_rate'', ''2.5'')'),
  'Only a parent signed in with the second step (the authenticator code) can do this.',
  'a parent without the code is refused as before');
select tests.as_kid('kid_a');
select is(tests.err('select public.approve_request(1)'),
  'Only a parent signed in with the second step (the authenticator code) can do this.',
  'a kid is refused as before');
select tests.as_parent();
select is((select count(*)::int from public.parent_actions), 8, 'refusals leave no log rows');

-- The log is append-only for everyone, the database owner included.
select tests.nobody();
select is(tests.err('update public.parent_actions set summary = ''changed'''),
  'parent_actions is append-only: update is not allowed. Add a new row instead.', 'no one can change a log row');
select is(tests.err('delete from public.parent_actions'),
  'parent_actions is append-only: delete is not allowed. Add a new row instead.', 'no one can delete a log row');
select is(tests.err('truncate public.parent_actions'),
  'parent_actions is append-only: truncate is not allowed. Add a new row instead.', 'no one can empty the log');

-- Only the parent with the code can read it.
select tests.as_parent('aal1');
set local role authenticated;
select is((select count(*)::int from public.parent_actions), 0, 'a parent without the code sees no log rows');
reset role;
select tests.as_kid('kid_a');
set local role authenticated;
select is((select count(*)::int from public.parent_actions), 0, 'a kid sees no log rows, even about her own account');
select is(tests.err('insert into public.parent_actions (done_by, action, summary) values (gen_random_uuid(), ''add_rate'', ''x'')'),
  'permission denied for table parent_actions', 'a kid can''t write to the log');
reset role;
select tests.as_parent();
set local role authenticated;
select is((select count(*)::int from public.parent_actions), 8, 'the parent with the code reads every row');
reset role;

-- 4. parent_inbox ----------------------------------------------------------------------------

-- Waiting now: kid A's withdrawal (10:00); add kid A's deposit at 11:00 and kid B's at 09:30.
select tests.clock('2026-10-01 09:30');
select tests.as_kid('kid_b');
select public.request_deposit(1500);
select tests.clock('2026-10-01 11:00');
select tests.as_kid('kid_a');
select public.request_deposit(2500);
select public.ask_question('Why is this $80?', (select min(id) from public.transactions));
select tests.clock('2026-10-01 15:30');
select tests.as_parent();

select results_eq(
  $$select r ->> 'kid', r ->> 'type', (r ->> 'amount_cents')::bigint, (r ->> 'is_test')::boolean
      from jsonb_array_elements(tests.inbox() -> 'requests') r$$,
  $$values ('Kid A'::text, 'withdraw'::text, 2000::bigint, false), ('Kid A', 'deposit', 2500, false),
           ('Kid B', 'deposit', 1500, true)$$,
  'waiting deposits and withdrawals: real kids first, oldest first; test accounts after');

select results_eq(
  $$select r ->> 'asked', r ->> 'approve_from', (r ->> 'wait_seconds')::bigint, r ->> 'expires',
           (r ->> 'expires_seconds')::bigint
      from jsonb_array_elements(tests.inbox() -> 'requests') r where r ->> 'kid' = 'Kid A'$$,
  $$values ('Oct 1 at 10:00 am'::text, 'Oct 2 at 10:00 am'::text, 66600::bigint, 'Oct 8 at 10:00 am'::text, 585000::bigint),
           ('Oct 1 at 11:00 am', null, 0, 'Oct 8 at 11:00 am', 588600)$$,
  'known answers at 3:30 pm: the withdrawal unlocks in 18 h 30 min (66,600 s); a deposit has no wait; both expire after 7 days');

select results_eq(
  $$select (r ->> 'cap_cents')::bigint, (r ->> 'net_deposits_cents')::bigint, (r ->> 'pending_deposits_cents')::bigint,
           (r ->> 'cap_room_cents')::bigint, (r ->> 'savings_cents')::bigint, (r ->> 'held_cents')::bigint,
           (r ->> 'available_cents')::bigint, (r ->> 'savings_after_cents')::bigint
      from jsonb_array_elements(tests.inbox() -> 'requests') r where r ->> 'kid' = 'Kid A'$$,
  $$values (150000::bigint, 8000::bigint, 2500::bigint, 139500::bigint, 8000::bigint, 2000::bigint, 6000::bigint, 6000::bigint),
           (150000, 8000, 2500, 139500, 8000, 2000, 6000, 10500)$$,
  'the money behind it: the $1,500 cap, $80 in, $25 waiting, $1,395 room; $80 savings with $20 held; savings after: $60 or $105');

select results_eq(
  $$select q ->> 'kid', q ->> 'message', q ->> 'asked', q -> 'line' ->> 'kind', (q -> 'line' ->> 'amount_cents')::bigint
      from jsonb_array_elements(tests.inbox() -> 'questions') q$$,
  $$values ('Kid A'::text, 'Why is this $80?'::text, 'Oct 1 at 11:00 am'::text, 'deposit'::text, 8000::bigint)$$,
  'open questions, with the history line they''re about (answered ones drop off)');

select results_eq(
  $$select r ->> 'who', r ->> 'when', r ->> 'summary' from jsonb_array_elements(tests.inbox() -> 'recent') r$$,
  $$values ('Parent'::text, 'Oct 1 at 9:00 am'::text, 'Answered Kid A''s question.'::text),
           ('Parent', 'Oct 1 at 9:00 am', 'Declined Kid A''s $50.00 deposit.'),
           ('Parent', 'Oct 1 at 8:00 am', 'Approved Kid A''s $80.00 deposit.')$$,
  'recent decisions: who, when and what, newest first (rates, settings and alerts aren''t decisions here)');

select is(tests.inbox() ->> 'now', 'Oct 1 at 3:30 pm', 'the inbox says when it was read');

select tests.as_parent('aal1');
select is(tests.err('select public.parent_inbox()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a parent needs the code');
select tests.as_kid('kid_a');
select is(tests.err('select public.parent_inbox()'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t read it');
select ok(not has_function_privilege('anon', 'public.parent_inbox()', 'EXECUTE'), 'signed-out visitors can''t call it');

-- 5. parent_decision_preview --------------------------------------------------------------------

select tests.as_parent();
create temporary table before_preview as select tests.footprint() as f;
create temporary table preview_approve as
  select public.parent_decision_preview('approve',
           (select id from public.requests where status = 'pending' and type = 'deposit'
               and account_id = tests.acct('kid_a')), 'Thanks!') as p;
create temporary table preview_answer as
  select public.parent_decision_preview('answer',
           (select id from public.questions where status = 'open'), 'It''s your birthday money.') as p;
create temporary table preview_decline as
  select public.parent_decision_preview('decline',
           (select id from public.requests where status = 'pending' and account_id = tests.acct('kid_b')),
           'Not this week') as p;

select is((select f from before_preview), tests.footprint(),
  'previews leave nothing behind: no decision, notice, ledger line, log row or released hold');
select is((select p ->> 'problem' from preview_approve), null, 'an approval that would go ahead has no problem');

-- The preview shows exactly what the real action writes.
select public.approve_request((select id from public.requests where status = 'pending' and type = 'deposit'
                                and account_id = tests.acct('kid_a')), 'Thanks!');
select is((select p -> 'notices' from preview_approve),
  (select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body)) from public.notifications n
    where n.dedupe_key = 'approved:' || (select max(id) from public.requests where status = 'approved')),
  'the approval preview''s notice is word for word the one she then gets');
select is((select p ->> 'summary' from preview_approve), (tests.last_action()).summary,
  '...and its log line is the one then written');
select is((select p -> 'notices' -> 0 ->> 'title' from preview_approve), 'Your $25.00 deposit is in!',
  'known answer: the approval title');

select public.answer_question((select id from public.questions where status = 'open'), 'It''s your birthday money.');
select is((select p -> 'notices' from preview_answer),
  (select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body)) from public.notifications n
    where n.dedupe_key = 'question:' || (select max(id) from public.questions)),
  'the answer preview matches the real notice');

select public.decline_request((select id from public.requests where status = 'pending' and account_id = tests.acct('kid_b')),
                              'Not this week');
select is((select p -> 'notices' -> 0 ->> 'body' from preview_decline),
  (select n.body from public.notifications n
    where n.dedupe_key = 'declined:' || (select max(id) from public.requests where status = 'declined')),
  'the decline preview matches the real notice, reason included');

-- Problems come back as the real action's message, not as an error.
select is(public.parent_decision_preview('approve',
            (select id from public.requests where status = 'pending' and type = 'withdraw')) ->> 'problem',
  'Withdrawals wait 24 hours before they can be approved. This one can be approved from Oct 2 at 10:00 am.',
  'a locked withdrawal: the preview gives the real message');
select is(public.parent_decision_preview('decline',
            (select id from public.requests where status = 'pending' and type = 'withdraw'), '') ->> 'problem',
  'Please give a reason, so she knows why.', 'a decline without a reason: the real message');
select is(public.parent_decision_preview('approve',
            (select id from public.requests where status = 'pending' and type = 'withdraw')) -> 'notices',
  '[]'::jsonb, '...with no notices');

select tests.as_kid('kid_a');
select is(tests.err('select public.parent_decision_preview(''approve'', 1)'),
  'Only a parent signed in with the second step (the authenticator code) can do this.',
  'a kid is refused outright, not given a preview');

-- 6. Previews never reach outside the database --------------------------------------------------

select tests.nobody();
select is(public.in_preview(), false, 'outside a preview, in_preview() is false');

-- Stand-in for future outside-world code (push notifications, email, HTTP): it refuses
-- to run unless it's inside a preview... so a preview that forgot the flag would fail.
create function tests.must_be_in_preview() returns trigger language plpgsql as $$
begin
  if not public.in_preview() then
    raise exception 'outside preview';
  end if;
  return new;
end;
$$;
create trigger t_preview_requests before insert on public.requests
  for each row execute function tests.must_be_in_preview();
create trigger t_preview_notifications before insert on public.notifications
  for each row execute function tests.must_be_in_preview();
create trigger t_preview_actions before insert on public.parent_actions
  for each row execute function tests.must_be_in_preview();

select tests.as_kid('kid_a');
select is(public.move_preview('deposit', 1000) ->> 'problem', null,
  'Buy / Sell''s preview runs its dry run with in_preview() on');
select is(tests.err('select public.request_deposit(1000)'), 'outside preview',
  '...and the real action runs with it off');
-- Kid A's withdrawal unlocked at 10:00 on Oct 2.
select tests.clock('2026-10-02 11:00');
select tests.as_parent();
select is(public.parent_decision_preview('approve',
            (select id from public.requests where status = 'pending' and type = 'withdraw')) ->> 'problem', null,
  'the Approvals preview runs its dry run (notice and log row included) with in_preview() on');
select is(tests.err('select public.approve_request((select id from public.requests where status = ''pending'' and type = ''withdraw''))'),
  'outside preview', '...and the real approval runs with it off');
select is(public.in_preview(), false, 'after a preview, the flag is back off');

drop trigger t_preview_requests on public.requests;
drop trigger t_preview_notifications on public.notifications;
drop trigger t_preview_actions on public.parent_actions;

-- The rule for future code (pre-launch audit, 2026-10-08): nothing in the database calls
-- out directly. Anything for the outside world goes through queue_outside(), which does
-- nothing in a preview; only the named sender (stage 4, run by pg_cron, never inside a
-- preview) may call pg_net, the http extension, dblink or an Edge Function, and it must
-- check in_preview() too. Checked over every function we own, in any schema, so a helper
-- hidden in another schema is caught as well.
create temp table outside_pattern (re text);
insert into outside_pattern values
  ('(net\.http_|net\._http|http_request|http_post|http_get|http_put|http_delete|http_patch|extensions\.http'
   || '|dblink|/functions/v1|supabase_functions\.)');
create temp table outside_senders (fn text);
insert into outside_senders values ('public.send_outbox()');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where pg_get_userbyid(p.proowner) = current_user
           and p.pronamespace <> 'tests'::regnamespace
           and p.prosrc ~* (select re from outside_pattern)
           and p.oid::regprocedure::text not in (select fn from outside_senders)),
  '{}'::text[],
  'no function calls outside the database except the named sender (CLAUDE.md, "Previews")');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where p.oid::regprocedure::text in (select fn from outside_senders)
           and p.prosrc !~ 'if public\.in_preview\(\) then\s+return'),
  '{}'::text[],
  'the sender, once it exists, stops at once in a preview');
select is(
  array(select p.oid::regprocedure::text from pg_proc p
         where pg_get_userbyid(p.proowner) = current_user
           and p.pronamespace <> 'tests'::regnamespace
           and p.prolang = (select oid from pg_language where lanname = 'plpgsql')
           and p.prosrc ~* '\mexecute\M'
           and p.prosrc ~* '(\mnet\M|http|dblink|functions)'
           and p.oid::regprocedure::text not in (select fn from outside_senders)),
  '{}'::text[],
  'no dynamic SQL that could build a call to the outside');
select is(
  array(select t.tgrelid::regclass::text || ': ' || t.tgname::text from pg_trigger t
          join pg_proc p on p.oid = t.tgfoid join pg_namespace n on n.oid = p.pronamespace
         where not t.tgisinternal
           and (n.nspname in ('supabase_functions', 'net', 'extensions') or p.prosrc ~* (select re from outside_pattern))),
  '{}'::text[],
  'no table has a database webhook (it would call out without checking in_preview())');
-- pg_cron jobs, once pg_cron is installed (stage 4).
do $$
begin
  if to_regclass('cron.job') is not null then
    execute $q$
      create temp table cron_out as
      select jobname from cron.job
       where command ~* (select re from outside_pattern) and command !~ 'send_outbox\(\)'$q$;
  else
    create temp table cron_out (jobname text);
  end if;
end;
$$;
select is(array(select jobname from cron_out), '{}'::text[],
  'no pg_cron job calls outside the database except through the sender');

-- queue_outside() by what it does: nothing in a preview, one queued message otherwise.
select tests.nobody();
select set_config('bigbucks.preview', 'on', true);
select is(public.queue_outside('email', '{"to": "parent"}'), null::bigint, 'in a preview, nothing is queued');
select is((select count(*)::int from public.outbox), 0, '...and the outbox stays empty');
select set_config('bigbucks.preview', '', true);
select isnt(public.queue_outside('email', '{"to": "parent"}'), null::bigint, 'outside a preview, it is queued');
select is((select count(*)::int from public.outbox where sent_at is null), 1, '...once');
select is(
  array(select r from unnest(array['anon', 'authenticated', 'service_role']) r
         where has_function_privilege(r, 'public.queue_outside(text, jsonb)', 'execute')),
  '{}'::text[], 'no app sign-in can queue anything itself');

-- 7. Nothing can skip the log: calling the originals directly ---------------------------------------
--
-- Something for each original to act on: a waiting deposit, an open question and an open alert.
select tests.clock('2026-10-02 12:00');
select tests.as_kid('kid_a');
select public.request_deposit(1000);
select public.ask_question('Direct-call test', null);
select tests.nobody();
insert into public.alerts (kind, account_id, message) values ('test', tests.acct('kid_a'), 'Direct-call test');

-- Each original (and the log writer), called directly: the message each call fails with
-- (null would mean it ran).
create function tests.direct_calls(p_req bigint, p_q bigint, p_alert bigint) returns text[]
language plpgsql as $$
declare
  v_sql text;
  v_out text[] := '{}';
begin
  foreach v_sql in array array[
    format('select public.approve_request_unlogged(%s, null)', p_req),
    format('select public.decline_request_unlogged(%s, %L)', p_req, 'skip the log'),
    format('select public.answer_question_unlogged(%s, %L)', p_q, 'skip the log'),
    format('select public.acknowledge_alert_unlogged(%s)', p_alert),
    'select public.add_rate_unlogged(''savings'', null, 1.0, null, null, null)',
    'select public.set_setting_unlogged(''inflation_rate'', ''3.0'', null, null)',
    'select public.move_preview_unflagged(''deposit'', 1000, null, null, null, false)',
    'select public.log_parent_action(''add_rate'', null, null, ''fake'', ''{}''::jsonb)']
  loop
    v_out := v_out || tests.err(v_sql);
  end loop;
  return v_out;
end;
$$;
create function tests.denied() returns text[] language sql as $$
  select array['permission denied for function approve_request_unlogged',
               'permission denied for function decline_request_unlogged',
               'permission denied for function answer_question_unlogged',
               'permission denied for function acknowledge_alert_unlogged',
               'permission denied for function add_rate_unlogged',
               'permission denied for function set_setting_unlogged',
               'permission denied for function move_preview_unflagged',
               'permission denied for function log_parent_action'];
$$;
-- Everything the originals could touch, as one line.
create function tests.state(p_req bigint, p_q bigint, p_alert bigint) returns text language sql as $$
  select concat_ws('/', tests.footprint(),
    (select status::text from public.requests where id = p_req),
    (select status::text from public.questions where id = p_q),
    (select coalesce(resolved_at::text, 'open') from public.alerts where id = p_alert),
    (select count(*) from public.rates), (select count(*) from public.settings));
$$;
grant usage on schema tests to anon;
create temporary table direct_ids as
  select (select max(id) from public.requests where status = 'pending' and account_id = tests.acct('kid_a')) as req,
         (select max(id) from public.questions where status = 'open') as q,
         (select max(id) from public.alerts where resolved_at is null) as alert;
grant select on direct_ids to anon, authenticated, service_role;
create temporary table direct_before as
  select tests.state(req, q, alert) as s from direct_ids;

select tests.as_parent();
set local role authenticated;
select is(tests.direct_calls(req, q, alert), tests.denied(),
  'a parent WITH the authenticator code is refused every original and the log writer') from direct_ids;
reset role;
select tests.as_kid('kid_a');
set local role authenticated;
select is(tests.direct_calls(req, q, alert), tests.denied(), 'a kid is refused every one') from direct_ids;
reset role;
select tests.nobody();
set local role anon;
select is(tests.direct_calls(req, q, alert), tests.denied(), 'a signed-out visitor is refused every one')
  from direct_ids;
reset role;
set local role service_role;
select is(tests.direct_calls(req, q, alert), tests.denied(), 'the server role is refused every one too')
  from direct_ids;
reset role;

select is((select tests.state(req, q, alert) from direct_ids), (select s from direct_before),
  'and nothing changed: the request still waits, the question and alert are still open, no ledger line, notice, log row, rate or setting');
select is((select tests.state(req, q, alert) from direct_ids) ~ '/pending/open/open/', true,
  '(the deposit, question and alert really were waiting, so a call that got through would have shown)');

select * from finish();
rollback;
