-- Stage 8 B3: Fix a mistake. A correction is a new savings line linked to the
-- history line (or question) it fixes, never an edit. It carries a note she reads
-- and names what it fixes; rounds in her favour; is never larger than the deposit
-- cap; needs a confirming tap to take money away and the amount typed again to add
-- more than $100; never takes more than its line or her free savings; and counts in
-- the graphs like the line it fixes. Every correction is logged. Known answers,
-- written first (and again for Dad's B3 review).
begin;
select plan(94);

-- Test helpers ----------------------------------------------------------------

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

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
-- A fixed key per test call, so "nothing posts twice" can be checked.
create function tests.key(p_n integer) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- The preview, from loose arguments.
create function tests.pv(p_kid text, p_line text, p_question bigint, p_direction text, p_amount text,
                         p_note text default 'Fixing it', p_counts text default null) returns jsonb language sql as $$
  select public.correction_preview(jsonb_build_object(
    'account_id', tests.acct(p_kid), 'line_key', p_line, 'question_id', p_question,
    'direction', p_direction, 'amount', p_amount, 'note', p_note, 'counts_as', p_counts));
$$;
create function tests.problem(p_kid text, p_line text, p_question bigint, p_direction text, p_amount text,
                              p_note text default 'Fixing it', p_counts text default null) returns text language sql as $$
  select tests.pv(p_kid, p_line, p_question, p_direction, p_amount, p_note, p_counts) ->> 'problem';
$$;
-- Everything a correction (or its preview) could touch.
create function tests.footprint() returns text language sql as $$
  select concat_ws('/', (select count(*) from public.transactions), (select sum(amount_cents) from public.transactions),
                   (select count(*) from public.notifications), (select count(*) from public.parent_actions),
                   (select count(*) from public.questions where status = 'open'));
$$;
create function tests.savings(p_kid text) returns text language sql as $$
  select ab.savings_cents || ' ' || ab.available_cents from public.account_balances ab
   where ab.account_id = tests.acct(p_kid);
$$;
create function tests.interest_key(p_kid text) returns text language sql as $$
  select 'interest:2026-09:' || tests.acct(p_kid);
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);

-- Kid A: $100 in on Oct 1, $0.42 of September interest, a $30 withdrawal waiting
-- (held), a $20 deposit Dad declined, and a $5 deposit waiting. Two questions.
-- Kid B (a test account): $50 in.
select tests.clock('2026-10-01 09:00');
select tests.as_kid('kid_a');
create temporary table ids as select public.request_deposit(10000) as dep_a;
select tests.as_kid('kid_b');
alter table ids add column dep_b bigint;
update ids set dep_b = public.request_deposit(5000);
select tests.as_parent();
select public.approve_request((select dep_a from ids));
select public.approve_request((select dep_b from ids));
select tests.nobody();
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at)
values (tests.acct('kid_a'), 'savings', 'interest', 42, tests.interest_key('kid_a'), public.edmonton_start('2026-10-01'));

select tests.clock('2026-10-03 09:00');
select tests.as_kid('kid_a');
select public.request_withdrawal(3000);
alter table ids add column declined bigint, add column waiting bigint, add column q_line bigint, add column q_req bigint;
update ids set declined = public.request_deposit(2000);
update ids set waiting = public.request_deposit(500);
update ids set q_line = public.ask_question('The interest looks small',
  (select id from public.transactions where posting_key = tests.interest_key('kid_a')));
update ids set q_req = public.ask_question('About "Dad said not this time (money in), $20.00" on Oct 3: why?');
select tests.as_parent();
select public.decline_request((select declined from ids), 'Not this week');

select tests.clock('2026-10-05 10:00');
select tests.as_parent();
create function tests.dep_key() returns text language sql as $$
  select 'request:' || (select dep_a from ids);
$$;
create function tests.fix(p_kid text, p_line text, p_question bigint, p_direction text, p_amount text,
                          p_note text, p_counts text, p_confirm text, p_key integer) returns bigint
language sql as $$
  select public.correct_savings(tests.acct(p_kid), p_line, p_question, p_direction, p_amount, p_note,
                                p_counts, p_confirm, tests.key(p_key));
$$;
create function tests.fix_err(p_kid text, p_line text, p_question bigint, p_direction text, p_amount text,
                              p_confirm text) returns text language sql as $$
  select tests.err(format('select tests.fix(%L, %L, %L, %L, %L, %L, null, %L, 99)',
                          p_kid, p_line, p_question, p_direction, p_amount, 'Fixing it', p_confirm));
$$;

-- 1. What the screen shows before anything is typed --------------------------------------------

select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, null, null) - 'line',
  '{"problem": "Choose whether to add to her savings or take from it.", "warning": null, "kid": "Kid A",
    "question": null, "savings_cents": 10042, "held_cents": 3000, "free_cents": 7042,
    "check_over_cents": 10000, "limit_cents": 100000, "line_left_cents": 42, "counts_as": "earned",
    "cents": null, "typed": null, "rounded": false, "needs_check": false, "needs_retype": false,
    "savings_after_cents": null, "free_after_cents": null, "summary": null, "notices": []}'::jsonb,
  'before typing: her savings, held and free; retyping over $100; the $1,000 cap as the ceiling; the line''s $0.42 left to take; earned');
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, null, null) -> 'line',
  jsonb_build_object('key', tests.interest_key('kid_a'), 'words', 'Savings interest', 'on', 'Oct 1', 'amount_cents', 42),
  'the line it fixes, in her history''s words, with its date and amount');
select is(tests.pv('kid_a', null, (select q_line from ids), null, null) -> 'question',
  jsonb_build_object('id', (select q_line from ids), 'message', 'The interest looks small', 'asked_on', 'Oct 3'),
  'from a question: the question...');
select is(tests.pv('kid_a', null, (select q_line from ids), null, null) -> 'line' ->> 'words', 'Savings interest',
  '...and the line she asked about');

-- 2. Amounts round in her favour ---------------------------------------------------------------

select is((select p ->> 'cents' || ' ' || (p ->> 'typed') || ' ' || (p ->> 'rounded')
             from (select tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '1.234') p) x),
  '124 $1.2340 true', 'adding $1.234 rounds UP to $1.24');
select is((select p ->> 'cents' || ' ' || (p ->> 'typed') || ' ' || (p ->> 'rounded')
             from (select tests.pv('kid_a', tests.dep_key(), null, 'take', '1.239') p) x),
  '-123 $1.2390 true', 'taking $1.239 rounds DOWN to $1.23');
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '0.0001') ->> 'cents', '1',
  'adding a hundredth of a cent becomes a whole cent');
select is((select jsonb_build_object('cents', p -> 'cents', 'typed', p -> 'typed', 'rounded', p -> 'rounded',
                                     'after', p -> 'savings_after_cents', 'free', p -> 'free_after_cents')
             from (select tests.pv('kid_a', tests.dep_key(), null, 'add', '2.50') p) x),
  '{"cents": 250, "typed": null, "rounded": false, "after": 10292, "free": 7292}'::jsonb,
  'whole cents need no rounding: $2.50 adds 250 cents');
select is(tests.pv('kid_a', tests.dep_key(), null, 'add', '$1,000') ->> 'cents', '100000',
  'a dollar sign and commas are fine');
select is(tests.problem('kid_a', tests.dep_key(), null, 'take', '0.004'),
  'That rounds down to $0.00 in her favour, so there''s nothing to take.',
  'taking less than a cent rounds to nothing, so it''s refused');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1.23456'),
  'Use at most 4 decimal places.', 'more than 4 decimals is refused');
select is(array[tests.problem('kid_a', tests.dep_key(), null, 'add', 'ten'),
                tests.problem('kid_a', tests.dep_key(), null, 'add', '-5'),
                tests.problem('kid_a', tests.dep_key(), null, 'add', ''),
                tests.problem('kid_a', tests.dep_key(), null, 'add', '0')],
  array['Type the amount in dollars, like 12.50.', 'Type the amount in dollars, like 12.50.',
        'Type the amount in dollars, like 12.50.', 'Type an amount more than $0.00.'],
  'letters, a minus sign, nothing, or zero are refused');
select is(tests.problem('kid_a', tests.dep_key(), null, 'double', '5'),
  'Choose whether to add to her savings or take from it.', 'the direction is add or take');

-- 3. No single correction larger than the deposit cap (Dad's B3 review, rule 2) ------------------

select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1000.00'), null,
  'adding exactly the $1,000 cap is allowed');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1000.01'),
  'A single correction can''t be more than the deposit limit ($1,000.00). If this is new money, use a normal deposit instead.',
  'adding $1,000.01 is refused, suggesting a normal deposit');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '10000.01'),
  'A single correction can''t be more than the deposit limit ($1,000.00). If this is new money, use a normal deposit instead.',
  'so is $10,000.01');
select is(tests.problem('kid_a', tests.dep_key(), null, 'take', '1000.01'),
  'A single correction can''t be more than the deposit limit ($1,000.00). If she''s taking money out, use a normal withdrawal instead.',
  'taking more than the cap is refused, suggesting a normal withdrawal');

-- 4. The extra checks: a tap for every reduction; retyping for additions over $100 (rule 1) ---------

select is(tests.pv('kid_a', tests.dep_key(), null, 'add', '100.00') ->> 'needs_retype', 'false',
  'adding exactly $100.00 needs no retyping');
select is(tests.pv('kid_a', tests.dep_key(), null, 'add', '100.0001') ->> 'needs_retype', 'true',
  'adding $100.0001 (rounds up to $100.01) needs the amount typed again');
select is((select (p ->> 'needs_check') || ' ' || (p ->> 'needs_retype')
             from (select tests.pv('kid_a', tests.dep_key(), null, 'take', '0.01') p) x),
  'true false', 'taking even $0.01 needs the extra check (a tap), not retyping');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'take', '1.239', null),
  'Taking money away needs the extra check: confirm $1.23 first.', 'a reduction without the extra check is refused');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'take', '1.239', '1.23'),
  'Taking money away needs the extra check: confirm $1.23 first.',
  '...and so is a check for a different amount');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'add', '500', null),
  'Adding more than $100.00 needs the amount typed again to confirm ($500.00).',
  'adding $500 without typing it again is refused');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'add', '500', '50.00'),
  'The amount typed again ($50.00) doesn''t match $500.00. Please type it again.',
  '...and a $50 retyped for a $500 correction is refused');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'add', '500', 'yes'),
  'Adding more than $100.00 needs the amount typed again to confirm ($500.00).',
  '...and so is anything that isn''t an amount');
select is(tests.fix_err('kid_a', tests.dep_key(), null, 'add', '100.0001', '100.00'),
  'The amount typed again ($100.00) doesn''t match $100.0001. Please type it again.',
  'the retyped amount must be exactly what was typed, before rounding');

-- 5. Never more than her free savings ------------------------------------------------------------

select is(tests.problem('kid_a', tests.dep_key(), null, 'take', '70.43'),
  'That''s more than Kid A has free to use ($70.42: $100.42 in savings, $30.00 on hold for her requests). A correction can''t take money she doesn''t have free.',
  'taking $70.43 when $70.42 is free is refused, with the figures');
select is((select coalesce(p ->> 'problem', 'ok') || ' ' || (p ->> 'savings_after_cents') || ' ' || (p ->> 'free_after_cents')
             from (select tests.pv('kid_a', tests.dep_key(), null, 'take', '70.42') p) x),
  'ok 3000 0', 'taking exactly what''s free is allowed: savings $30.00 left, all of it on hold');
select is(tests.problem('kid_a', tests.dep_key(), null, 'take', '70.429'), null,
  '$70.429 rounds down to $70.42, so it fits');

-- 6. A reduction can't take more than its line; an addition may, with a warning (rules 3 and 4) ---

select is(tests.problem('kid_a', tests.interest_key('kid_a'), null, 'take', '0.43'),
  'A fix can''t take more than the line it fixes: "Savings interest" on Oct 1 was $0.42.',
  'taking $0.43 from a $0.42 interest line is refused');
select is(tests.problem('kid_a', tests.interest_key('kid_a'), null, 'take', '0.42'), null,
  'taking all $0.42 is allowed');
select is(tests.problem('kid_a', 'req:' || (select declined from ids), null, 'take', '20.01'),
  'A fix can''t take more than the line it fixes: "Dad said not this time (money in)" on Oct 3 was $20.00.',
  'a declined $20 request line limits a reduction to $20');
select is((select coalesce(p ->> 'problem', 'ok') || ' | ' || (p ->> 'warning')
             from (select tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '500') p) x),
  'ok | This is more than the line it fixes ($0.42). Is that right?',
  'adding $500 to a $0.42 line is allowed, with a warning (not a block)');
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '0.42') ->> 'warning', null,
  'no warning when the addition is no more than the line');
select is(tests.pv('kid_a', tests.dep_key(), null, 'take', '5') ->> 'warning', null,
  'no warning on a reduction');
select is(tests.pv('kid_a', null, (select q_req from ids), 'add', '500') ->> 'warning', null,
  'no warning with no line to compare to');

-- 7. Which line or question it fixes ------------------------------------------------------------

select is(tests.problem('kid_a', null, null, 'add', '1'), 'Choose the history line or question this fixes.',
  'a correction must be linked to a line or a question');
select is(tests.problem('kid_a', 'interest:1999-01:nothing', null, 'add', '1'),
  'There''s no line "interest:1999-01:nothing" in Kid A''s history.', 'an unknown line is refused');
select is(tests.problem('kid_a', 'request:' || (select dep_b from ids), null, 'add', '1'),
  'There''s no line "request:' || (select dep_b from ids) || '" in Kid A''s history.',
  'her sister''s line is not in her history');
select is(tests.problem('kid_a', 'req:' || (select waiting from ids), null, 'add', '1'),
  'That request is still waiting: approve or decline it instead.', 'a waiting request can''t be corrected');
select is(tests.pv('kid_a', 'req:' || (select declined from ids), null, 'add', '1') -> 'line',
  jsonb_build_object('key', 'req:' || (select declined from ids), 'words', 'Dad said not this time (money in)',
                     'on', 'Oct 3', 'amount_cents', 2000),
  'a declined request is a line it can fix');
select is(tests.problem('kid_b', null, (select q_line from ids), 'add', '1'),
  'There''s no question #' || (select q_line from ids) || ' from Kid B.', 'her sister''s question is refused');
select is(tests.problem('kid_a', tests.dep_key(), (select q_line from ids), 'add', '1'),
  'That question is about a different line.', 'a question and a different line don''t mix');
select is(tests.pv('kid_a', null, (select q_req from ids), 'add', '1') ->> 'line', null,
  'a question about a request has no ledger line: the correction links to the question');

-- 8. The note she reads -------------------------------------------------------------------------

select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1', '   '),
  'Write a note she can read: what went wrong and what this fixes.', 'a note is required');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1', repeat('a', 301)),
  'Keep the note to 300 letters or fewer.', 'the note is at most 300 letters');

-- 9. How the graphs will count it (rule 6) -----------------------------------------------------------

select is(array[tests.pv('kid_a', tests.dep_key(), null, 'add', '1') ->> 'counts_as',
                tests.pv('kid_a', 'req:' || (select declined from ids), null, 'add', '1') ->> 'counts_as',
                tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '1') ->> 'counts_as'],
  array['money', 'money', 'earned'],
  'a deposit or a deposit request counts as money in; interest counts as earned');
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '1', 'Fixing it', 'money') ->> 'counts_as', 'earned',
  'with a line, the line decides (Dad''s choice is only for a fix with no line)');
select is(array[tests.pv('kid_a', null, (select q_req from ids), null, null) ->> 'counts_as',
                tests.pv('kid_a', null, (select q_req from ids), 'add', '1') ->> 'counts_as',
                tests.pv('kid_a', null, (select q_req from ids), 'add', '1', 'Fixing it', 'money') ->> 'counts_as'],
  array[null, 'earned', 'money'],
  'with no line, Dad chooses: earned by default, or money in');
select is(tests.problem('kid_a', null, (select q_req from ids), 'add', '1', 'Fixing it', 'gift'),
  'Choose how the graphs count it: money in or out, or earned.', 'nothing else');

-- 10. The preview: exactly what will happen, and nothing left behind ----------------------------

create temporary table fp as select tests.footprint() as f;
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, 'add', '1.234', 'September interest was short') - 'line',
  '{"problem": null, "warning": "This is more than the line it fixes ($0.42). Is that right?", "kid": "Kid A",
    "question": null, "savings_cents": 10042, "held_cents": 3000, "free_cents": 7042,
    "check_over_cents": 10000, "limit_cents": 100000, "line_left_cents": 42, "counts_as": "earned",
    "cents": 124, "typed": "$1.2340", "rounded": true, "needs_check": false, "needs_retype": false,
    "savings_after_cents": 10166, "free_after_cents": 7166,
    "summary": "Corrected Kid A''s savings: +$1.24, fixing \"Savings interest\" on Oct 1.",
    "notices": [{"title": "A correction · fixes Savings interest on Oct 1",
                 "body": "Dad added $1.24 to your savings. Dad said: \"September interest was short\""}]}'::jsonb,
  'the preview: the amount after rounding, the warning, savings before and after, the log line, and her notice naming the line');
select is(tests.pv('kid_a', null, (select q_req from ids), 'take', '20', 'That $20 was counted twice') -> 'notices',
  '[{"title": "A correction · about your question from Oct 3",
     "body": "Dad took $20.00 out of your savings. Dad said: \"That $20 was counted twice\""}]'::jsonb,
  'a reduction from a question: her notice');
select is(tests.pv('kid_a', null, (select q_req from ids), 'take', '20', 'That $20 was counted twice') ->> 'summary',
  'Corrected Kid A''s savings: -$20.00, about her question from Oct 3.', '...and the log line');
select is(tests.footprint(), (select f from fp), 'previews leave no ledger line, notice, log row or answer behind');

-- 11. Saving it for real ------------------------------------------------------------------------

create temporary table fix1 as
  select tests.fix('kid_a', tests.interest_key('kid_a'), null, 'add', '1.234', 'September interest was short',
                   null, null, 1) as id;
select results_eq(
  $$select account_id, vehicle::text, type::text, amount_cents, note, corrects_id, corrects_request_id, question_id,
           counts_as, posting_key, effective_at
      from public.transactions where id = (select id from fix1)$$,
  $$select tests.acct('kid_a'), 'savings', 'correction', 124::bigint, 'September interest was short',
           (select id from public.transactions where posting_key = tests.interest_key('kid_a')),
           null::bigint, null::bigint, 'earned', 'correction:' || tests.key(1)::text, public.app_now()$$,
  'a new savings line: +124 cents, her note, linked to the interest line, earned, posted now');
select is((select amount_cents from public.transactions where posting_key = tests.interest_key('kid_a')), 42::bigint,
  'the interest line itself is untouched');
select is(tests.savings('kid_a'), '10166 7166', 'her savings: $101.66, $71.66 free');
select results_eq(
  $$select title, body from public.notifications where account_id = tests.acct('kid_a') and type = 'correction'$$,
  $$values ('A correction · fixes Savings interest on Oct 1',
            'Dad added $1.24 to your savings. Dad said: "September interest was short"')$$,
  'her notice, word for word what the preview showed');
select results_eq(
  $$select done_by, action, account_id, target_id, summary, done_at,
           details ->> 'cents', details ->> 'typed', details ->> 'note', details ->> 'line_key', details ->> 'counts_as'
      from public.parent_actions where action = 'correct_savings'$$,
  $$select '00000000-0000-0000-0000-00000000000f'::uuid, 'correct_savings', tests.acct('kid_a'), (select id from fix1),
           'Corrected Kid A''s savings: +$1.24, fixing "Savings interest" on Oct 1.', public.app_now(),
           '124', '$1.2340', 'September interest was short', tests.interest_key('kid_a'), 'earned'$$,
  'one log row: who, when, the kid, the line, the summary (word for word the preview) and what was typed');
select is(tests.err($$select tests.fix('kid_a', tests.interest_key('kid_a'), null, 'add', '1.234',
                       'September interest was short', null, null, 1)$$),
  'This correction is already saved.', 'the same correction sent twice (a double tap) is refused...');
select is((select count(*)::int from public.transactions where type = 'correction'), 1, '...and posts once');

-- A reduction from a question about a request, counted as money out (Dad's choice).
create temporary table fix2 as
  select tests.fix('kid_a', null, (select q_req from ids), 'take', '20', 'That $20 was counted twice',
                   'money', '20', 2) as id;
select results_eq(
  $$select amount_cents, corrects_id, corrects_request_id, question_id, counts_as
      from public.transactions where id = (select id from fix2)$$,
  $$select -2000::bigint, null::bigint, null::bigint, (select q_req from ids), 'money'$$,
  'a reduction: −2000 cents, linked to her question, counted as money out');
select is(tests.savings('kid_a'), '8166 5166', 'her savings: $81.66, $51.66 free');
select is((select status::text from public.questions where id = (select q_req from ids)), 'open',
  'fixing a mistake doesn''t answer her question: Dad still answers it');

-- From the declined deposit, over $100: typed again.
create temporary table fix3 as
  select tests.fix('kid_a', 'req:' || (select declined from ids), null, 'add', '150',
                   'The $20 was really $150 of birthday money', null, '150.00', 3) as id;
select results_eq(
  $$select amount_cents, corrects_request_id, counts_as from public.transactions where id = (select id from fix3)$$,
  $$select 15000::bigint, (select declined from ids), 'money'$$,
  'over $100 with the amount typed again: linked to the declined deposit, counted as money in');

-- Two reductions against the same interest line: together, never more than the line.
create temporary table fix4 as
  select tests.fix('kid_a', tests.interest_key('kid_a'), null, 'take', '0.30', 'Some interest was counted twice',
                   null, '0.30', 4) as id;
select is(tests.pv('kid_a', tests.interest_key('kid_a'), null, 'take', '0.13') ->> 'problem',
  'A fix can''t take more than the line it fixes: "Savings interest" on Oct 1 was $0.42, and earlier fixes already took $0.30, so at most $0.12 is left.',
  'after taking $0.30 from the $0.42 line, $0.13 more is refused');
select is((select coalesce(p ->> 'problem', 'ok') || ' ' || (p ->> 'line_left_cents')
             from (select tests.pv('kid_a', tests.interest_key('kid_a'), null, 'take', '0.12') p) x),
  'ok 12', '...and $0.12 is what''s left');

-- A test account works the same way.
select isnt(tests.fix('kid_b', 'request:' || (select dep_b from ids), null, 'add', '1', 'Test fix', null, null, 5),
  null, 'a test account can be corrected too');

-- 12. Her history names what each correction fixes (rule 5) ---------------------------------------

select tests.as_kid('kid_a');
select results_eq(
  $$select kind, amount_cents, note, fixes from public.my_activity(tests.acct('kid_a'), 50)
     where kind = 'correction' order by at, item_key$$,
  $$values ('correction'::text, 124::bigint, 'September interest was short'::text, 'Savings interest on Oct 1'::text),
           ('correction', -2000, 'That $20 was counted twice', 'your question from Oct 3'),
           ('correction', 15000, 'The $20 was really $150 of birthday money', 'Dad said not this time (money in) on Oct 3'),
           ('correction', -30, 'Some interest was counted twice', 'Savings interest on Oct 1')$$,
  'her history: each correction with its note and the line (or question) it fixes');
select is((select count(*)::int from public.my_activity(tests.acct('kid_a'), 50) where fixes is not null and kind <> 'correction'),
  0, 'only corrections say what they fix');

-- 13. The graphs count each correction like the line it fixes (rule 6) ------------------------------
-- Oct 5: +$1.24 and −$0.30 (interest fixes, earned); −$20.00 (money, Dad's choice) and
-- +$150.00 (the declined deposit, money). Savings end the day at $231.36.

select is((select net_flow_cents || ' ' || savings_cents
             from public.daily_balances(tests.acct('kid_a'), '2026-10-05', '2026-10-05')),
  '13000 23136', 'money in on Oct 5 is the two money fixes ($150.00 − $20.00), not the earned ones');
select is((select net_deposits_cents || ' ' || total_cents || ' ' || earned_cents
             from public.money_in_vs_earned(tests.acct('kid_a')) where day = '2026-10-05'),
  '23000 23136 136', 'money in vs earned: $100 + $130 in; earned $1.36 = $0.42 interest + $1.24 − $0.30');
select is((select flow_cents || ' ' || earned_cents
             from public.growth_by_option(tests.acct('kid_a'), '2026-10-04', '2026-10-05')
            where option = 'savings' and day = '2026-10-05'),
  '13000 94', 'growth: the money fixes are money moved, the interest fixes are growth ($1.24 − $0.30)');

-- 14. Dad's list of her corrections --------------------------------------------------------------

select tests.as_parent();
select is((select jsonb_agg(jsonb_build_object('cents', c -> 'cents', 'fixes', c -> 'fixes', 'counts_as', c -> 'counts_as',
                                               'who', c -> 'who', 'when', c -> 'when'))
             from jsonb_array_elements(public.parent_corrections(tests.acct('kid_a'))) c),
  '[{"cents": -30, "fixes": "Savings interest on Oct 1", "counts_as": "earned", "who": "Parent", "when": "Oct 5 at 10:00 am"},
    {"cents": 15000, "fixes": "Dad said not this time (money in) on Oct 3", "counts_as": "money", "who": "Parent", "when": "Oct 5 at 10:00 am"},
    {"cents": -2000, "fixes": "your question from Oct 3", "counts_as": "money", "who": "Parent", "when": "Oct 5 at 10:00 am"},
    {"cents": 124, "fixes": "Savings interest on Oct 1", "counts_as": "earned", "who": "Parent", "when": "Oct 5 at 10:00 am"}]'::jsonb,
  'Dad''s list: newest first, what each fixes, how it counts, who and when');
select tests.as_kid('kid_a');
select is(tests.err($$select public.parent_corrections(tests.acct('kid_a'))$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.',
  'a kid can''t read Dad''s list');

-- 15. Who may correct ----------------------------------------------------------------------------

select is(tests.err($$select tests.fix('kid_a', tests.dep_key(), null, 'add', '1', 'Mine', null, null, 9)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t correct');
select is(tests.err($$select public.correction_preview('{}'::jsonb)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or preview one');
select tests.as_parent('aal1');
select is(tests.err($$select tests.fix('kid_a', tests.dep_key(), null, 'add', '1', 'Fix', null, null, 9)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.',
  'a parent without the code can''t');
select tests.nobody();
set local role anon;
select is(tests.err($$select public.correct_savings(null, null, null, null, null, null, null, null, null)$$),
  'permission denied for function correct_savings', 'signed-out visitors can''t call it at all');
reset role;
select tests.as_parent();
select is(tests.err($$select public.correct_savings(gen_random_uuid(), 'x', null, 'add', '1', 'Fix', null, null, tests.key(9))$$),
  'There''s no such account.', 'an unknown account is refused');
select is(tests.err($$select public.correct_savings(tests.acct('kid_a'), tests.dep_key(), null, 'add', '1',
                       'Fix', null, null, null)$$),
  'Missing the correction''s key. Please try again.', 'the key that stops double posting is required');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('correct_savings', 'correction_preview', 'parent_corrections', 'correction_context',
                             'correction_cents', 'correction_dollars', 'line_words')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         order by 1),
  array['correct_savings', 'correction_preview', 'parent_corrections'],
  'only the action, its preview and Dad''s list are callable (each checks for the code); the helpers are internal');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('correct_savings', 'correction_preview', 'parent_corrections')
           and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('service_role', p.oid, 'EXECUTE'))),
  '{}'::text[], 'signed-out visitors and the server role can''t call them');

-- 16. The preview runs with in_preview() on; the real thing with it off -------------------------

create function tests.must_be_in_preview() returns trigger language plpgsql as $$
begin
  if not public.in_preview() then
    raise exception 'outside preview';
  end if;
  return new;
end;
$$;
create trigger t_preview_tx before insert on public.transactions for each row execute function tests.must_be_in_preview();
create trigger t_preview_notices before insert on public.notifications for each row execute function tests.must_be_in_preview();
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '1'), null,
  'the correction preview runs its dry run (ledger line, notice and log) with in_preview() on');
select is(tests.err($$select tests.fix('kid_a', tests.dep_key(), null, 'add', '1', 'Fix', null, null, 6)$$),
  'outside preview', '...and the real correction runs with it off');
select is(public.in_preview(), false, 'the flag is off again afterwards');
drop trigger t_preview_tx on public.transactions;
drop trigger t_preview_notices on public.notifications;

-- 17. Corrections stay corrections ----------------------------------------------------------------

select tests.nobody();
select is(tests.err($$update public.transactions set amount_cents = 1 where id = (select id from fix1)$$) is not null,
  true, 'a correction can''t be edited either');
select is(tests.err($$insert into public.transactions (account_id, vehicle, type, amount_cents, corrects_id)
                      values (tests.acct('kid_a'), 'savings', 'interest', 5, (select id from fix1))$$) is not null,
  true, 'only a correction can point at the line it fixes');
select is(tests.err($$insert into public.transactions (account_id, vehicle, type, amount_cents, counts_as)
                      values (tests.acct('kid_a'), 'savings', 'interest', 5, 'money')$$) is not null,
  true, 'only a correction says how the graphs count it');
select is(tests.err($$insert into public.transactions (account_id, vehicle, type, amount_cents, note, corrects_id)
                      values (tests.acct('kid_b'), 'savings', 'correction', 5, 'x', (select id from fix1))$$) is not null,
  true, 'a correction can''t point at another kid''s line');
select is(tests.err($$insert into public.transactions (account_id, vehicle, type, amount_cents, note, corrects_id)
                      values (tests.acct('kid_a'), 'gic', 'correction', 5, 'x', (select id from fix1))$$) is not null,
  true, 'a linked correction is always in savings');

-- 18. A lower cap lowers the ceiling --------------------------------------------------------------

insert into public.settings (key, value, effective_date) values ('deposit_cap_cents', '5000', date '2026-01-01');
select tests.as_parent();
select is(tests.pv('kid_a', tests.dep_key(), null, 'add', '50.00') ->> 'limit_cents', '5000',
  'with a $50 cap, no single correction may be more than $50.00');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '50.01'),
  'A single correction can''t be more than the deposit limit ($50.00). If this is new money, use a normal deposit instead.',
  '...so adding $50.01 is refused');
select is(tests.problem('kid_a', tests.dep_key(), null, 'add', '50.00'), null, '...and $50.00 is allowed');

select * from finish();
rollback;
