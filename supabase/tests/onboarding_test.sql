-- Stage 8 B4: onboarding, the account agreement and What's new. Known answers:
-- the house-rule numbers (from the settings in force, and fixed rules that match
-- the engine), version 1 word for word (Dad's reviewed wording), signing before the
-- first deposit, the frozen copy, Dad's countersignature, a new version, finishing
-- onboarding, and What's new.
begin;
select plan(85);

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
-- A kid who has NOT signed the agreement (unlike the other test files' kids).
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
-- A version's rules as one line each: "icon title|text".
create function tests.rule_lines(p_doc jsonb) returns text language sql as $$
  select string_agg((r ->> 'icon') || ' ' || (r ->> 'title') || '|' || (r ->> 'text'), E'\n' order by n)
    from jsonb_array_elements(p_doc -> 'rules') with ordinality x(r, n);
$$;
create function tests.footprint() returns text language sql as $$
  select concat_ws('/', (select count(*) from public.agreement_signatures), (select count(*) from public.notifications),
                   (select count(*) from public.parent_actions), (select count(*) from public.requests));
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 10:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.new_kid('kid_c');
-- The Wish List is on for test accounts only (kid B).
insert into public.settings (key, value, effective_date) values ('feature:wishlist', 'test', date '2026-01-01');

-- 1. The numbers in the house rules, from the settings in force ----------------------------------

select tests.nobody();
select is(public.house_rules(),
  '{"cap": "$1,000.00", "expiry_days": "7", "savings_rate": "2.0%", "gic_lowest": "2.5%", "gic_highest": "6.0%",
    "cut_notice_days": "7", "withdraw_wait_hours": "24", "min_savings": "$5.00", "min_invest": "$10.00",
    "gic_choice_days": "7", "goal_wait_days": "7"}'::jsonb,
  'every number the wording uses, today');

-- 2. The fixed rules are the engine's own --------------------------------------------------------

select is(position((public.house_rules() ->> 'gic_choice_days') || '' in
                   (select substring(p.prosrc from 'maturity_date \+ ([0-9]+) \+ greatest')
                      from pg_proc p where p.proname = 'mature_gics')), 1,
  'a matured GIC moves to savings after the same number of days the agreement says');
select tests.as_parent();
select is((select public.parent_change_preview('add_rate', jsonb_build_object('vehicle', 'savings', 'rate', '1.0',
             'effective_date', public.app_today() + (public.house_rules() ->> 'cut_notice_days')::int - 1)) ->> 'problem')
          like '%sooner than ' || (public.house_rules() ->> 'cut_notice_days') || ' days from today%', true,
  'a cut one day inside the notice period is refused...');
select is(public.parent_change_preview('add_rate', jsonb_build_object('vehicle', 'savings', 'rate', '1.0',
             'effective_date', public.app_today() + (public.house_rules() ->> 'cut_notice_days')::int)) ->> 'problem',
  null, '...and one exactly that many days out is allowed');

-- 3. Version 1 is Dad's reviewed wording, word for word -----------------------------------------

select is(public.agreement_render(1, tests.acct('kid_a')) - 'rules',
  '{"version": 1, "title": "Your Big Bucks agreement",
    "intro": "These are the house rules. Read them with Dad, and ask about anything that doesn''t make sense. When you both agree, you each sign. A copy stays in your history.",
    "promises": "Dad keeps your cash safe, answers your requests, and fixes any mistake openly, with a note, rounding in your favour.",
    "sign_line": "I''ve read these rules with Dad, and I agree.", "name": "Kid A"}'::jsonb,
  'the title, intro, Dad''s promises and her signature line');
select is(tests.rule_lines(public.agreement_render(1, tests.acct('kid_a'))),
  $$💵 The money is real.|Dad keeps the cash, and Big Bucks keeps track of every cent he owes you.
🐷 New money goes into savings first.|You can put in up to $1,000.00 altogether. Taking money out gives you room again. Interest and growth don't count, so your money can grow past $1,000.00.
🎁 Birthday money and allowance can go in too.|Ask for a deposit the usual way, and it has to fit under your deposit cap.
🙋 Dad says yes first|when money goes in or out, because real cash changes hands. Dad has up to 7 days to answer. If he hasn't answered by then, the request is cancelled and you can ask again.
😴 Sleep on it.|When you ask to take money out, Dad waits at least 24 hours before he can say yes, so you have time to think it over.
✋ Money on hold.|While a request is waiting, its money is on hold, so you can't use the same money twice.
🔢 The smallest amounts|are $5.00 for savings, and $10.00 for a GIC or a stock fund.
🔒 A GIC is a promise.|You leave the money for the whole term. If you break the promise early, you get your money back but you lose all its interest. When a GIC finishes, you have 7 days to choose what's next, or it moves to your savings.
📉 Stock funds go up and down, and losses are real.|If a fund is worth less when you sell, you get less. A big drop can turn $100 into $80, and sometimes less, for a while. Markets have usually come back, but it can take a long time.
📈 One trade per fund each day.|You can buy or sell each fund once a day. Buys and sells happen at the next market close.
📣 Rates can change|, like at a real bank. If a rate or your deposit cap is going down, Big Bucks tells you at least 7 days before. Good news, like a higher rate, can start right away. A GIC you already have keeps its rate.
⚖️ Fair for both of you.|You and your sister get the same rates and the same rules.
🔍 Ask any time.|If something ever looks wrong, tap "Something looks wrong?" and Dad will answer. If there's a mistake, Dad fixes it openly, with a note you can read, and rounding always goes your way.
🔑 Your PIN is yours.|Don't share it, not even with your sister. If you think someone knows it, tell Dad.
👀 Mom and Dad can see your account.|They can look at your Big Bucks screens any time.$$,
  'the 15 rules with today''s numbers, including "Your PIN is yours" and "Big Bucks tells you"; no Wish List, so rule 15 ends at "any time."');
select is((select r ->> 'text' from jsonb_array_elements(public.agreement_render(1, tests.acct('kid_b')) -> 'rules') r
            where r ->> 'icon' = '👀'),
  'They can look at your Big Bucks screens any time, just like your wish list.',
  'with her Wish List on, rule 15 mentions it');
select is((select r ->> 'glossary' from jsonb_array_elements(public.agreement_render(1, tests.acct('kid_a')) -> 'rules') r
            where r ->> 'icon' = '✋'), 'On hold', '"on hold" has its ? explanation');

-- 4. She can look around before signing, but can't put money in -------------------------------

select tests.as_kid('kid_a');
-- resume_step, resume_card, pending_deposit_cents, unlocked and last_answer: see onboarding_resume_test.sql.
select is((select s - 'agreement' - 'rules' - 'resume_step' - 'resume_card' - 'pending_deposit_cents' - 'unlocked' - 'last_answer'
             from (select public.onboarding_state(tests.acct('kid_a')) s) x),
  jsonb_build_object('name', 'Kid A', 'done', false, 'current_version', 1, 'signed_version', null,
    'countersigned', false, 'needs_signature', true, 'steps', '["welcome", "tour", "agreement", "decision"]'::jsonb,
    'first_deposit_cents', null, 'free_cents', 0, 'min_invest_cents', 1000),
  'before anything: not signed, nothing in, and the steps (no Wish List or Make it yours for her)');
select is(public.onboarding_state(tests.acct('kid_a')) -> 'agreement', public.agreement_render(1, tests.acct('kid_a')),
  'the agreement she reads is version 1 with today''s numbers');
create temporary table fp as select tests.footprint() as f;
select is(tests.err('select public.request_deposit(1000)'),
  'Before you can put money in, sign your Big Bucks agreement with Dad.',
  'a deposit before she signs is refused');
select is(public.move_preview('deposit', 1000) ->> 'problem',
  'Before you can put money in, sign your Big Bucks agreement with Dad.',
  'Buy / Sell''s preview says so too');
select is(tests.footprint(), (select f from fp), 'nothing was asked for or held');
select is(tests.err('select public.finish_onboarding()'), 'Sign your Big Bucks agreement with Dad first.',
  'onboarding can''t finish before she signs');
select tests.as_kid('kid_b');
select is(public.onboarding_state(tests.acct('kid_b')) -> 'steps', '["welcome", "tour", "wish", "agreement", "decision"]'::jsonb,
  'with the Wish List on for her, her onboarding includes the first-wish step');

-- 5. Signing -------------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select is(tests.err('select public.sign_agreement(2)'),
  'That isn''t the latest agreement. Please go back and read the latest one.', 'only the latest version can be signed');
create temporary table sig_a as select public.sign_agreement(1) as id;
select results_eq(
  $$select account_id, version, signer, signed_by, signed_at, copy from public.agreement_signatures where id = (select id from sig_a)$$,
  $$select tests.acct('kid_a'), 1, 'kid', (select user_id from public.profiles where username = 'kid_a'), public.app_now(),
           public.agreement_render(1, tests.acct('kid_a'))$$,
  'her signature: who, when, and a copy of exactly what she read');
select is((select agreement_signed_at from public.accounts where id = tests.acct('kid_a')), public.app_now(),
  'her account remembers when she signed');
select is(tests.err('select public.sign_agreement(1)'), 'You''ve already signed this agreement.', 'once is enough');
select isnt(public.request_deposit(1000), null, 'now she can ask to put money in');
select is((select s ->> 'needs_signature' from (select public.onboarding_state(tests.acct('kid_a')) s) x), 'false',
  'she doesn''t need to sign again');
select tests.as_parent();
select is(tests.err('select public.sign_agreement(1)'), 'Only a kid''s account can do this.', 'Dad can''t sign for her');
select tests.as_kid('kid_b');
select isnt(public.sign_agreement(1), null, 'kid B (a test account) signs too');

-- 6. Her copy is frozen; numbers that change reach her by notice ----------------------------------

insert into public.settings (key, value, effective_date) values ('deposit_cap_cents', '125000', date '2026-10-05');
insert into public.settings (key, value, effective_date) values ('request_expiry_days', '10', date '2026-10-05');
select tests.as_kid('kid_a');
select is((select r ->> 'text' from jsonb_array_elements(public.onboarding_state(tests.acct('kid_a')) -> 'agreement' -> 'rules') r
            where r ->> 'icon' = '🐷'),
  'You can put in up to $1,250.00 altogether. Taking money out gives you room again. Interest and growth don''t count, so your money can grow past $1,250.00.',
  'the agreement as read today has the new cap...');
select is((select r ->> 'text' from jsonb_array_elements(public.my_agreements(tests.acct('kid_a')) -> 0 -> 'copy' -> 'rules') r
            where r ->> 'icon' = '🐷'),
  'You can put in up to $1,000.00 altogether. Taking money out gives you room again. Interest and growth don''t count, so your money can grow past $1,000.00.',
  '...but the copy she signed keeps the cap of the day she signed');
select is((select r ->> 'text' from jsonb_array_elements(public.my_agreements(tests.acct('kid_a')) -> 0 -> 'copy' -> 'rules') r
            where r ->> 'icon' = '🙋') like '%up to 7 days%', true, '...and the 7 days Dad had then');
select is((select s ->> 'needs_signature' from (select public.onboarding_state(tests.acct('kid_a')) s) x), 'false',
  'a changed number doesn''t need a new signature');

-- 7. Dad countersigns on his own phone ------------------------------------------------------------

select tests.as_parent();
select is(public.agreement_preview(tests.acct('kid_c'), 1) ->> 'problem', 'Kid C hasn''t signed this agreement yet.',
  'Dad can''t sign before she does');
delete from fp;
insert into fp select tests.footprint();
select is(public.agreement_preview(tests.acct('kid_a'), 1) - 'copy',
  '{"problem": null, "summary": "Signed Kid A''s Big Bucks agreement.",
    "notices": [{"title": "Your agreement is signed!", "body": "Dad signed it too. You can read it any time in your history."}]}'::jsonb,
  'the preview: the log line and her notice');
select is(public.agreement_preview(tests.acct('kid_a'), 1) -> 'copy',
  (select copy from public.agreement_signatures where id = (select id from sig_a)),
  'Dad reads the copy she signed');
select is(tests.footprint(), (select f from fp), 'the preview leaves nothing behind');
create temporary table csig as select public.countersign_agreement(tests.acct('kid_a'), 1) as id;
select results_eq(
  $$select account_id, version, signer, signed_by, signed_at, copy from public.agreement_signatures where id = (select id from csig)$$,
  $$select tests.acct('kid_a'), 1, 'parent', '00000000-0000-0000-0000-00000000000f'::uuid, public.app_now(), null::jsonb$$,
  'Dad''s signature row');
select results_eq(
  $$select title, body from public.notifications where account_id = tests.acct('kid_a') and type = 'agreement'$$,
  $$values ('Your agreement is signed!', 'Dad signed it too. You can read it any time in your history.')$$,
  'her notice, word for word as previewed');
select results_eq(
  $$select action, account_id, target_id, summary from public.parent_actions where action = 'countersign_agreement'$$,
  $$select 'countersign_agreement', tests.acct('kid_a'), (select id from csig), 'Signed Kid A''s Big Bucks agreement.'$$,
  'one log row, word for word as previewed');
select is(tests.err($$select public.countersign_agreement(tests.acct('kid_a'), 1)$$),
  'You''ve already signed Kid A''s agreement.', 'Dad signs once');
select tests.as_parent('aal1');
select is(tests.err($$select public.countersign_agreement(tests.acct('kid_b'), 1)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'not without the code');
select tests.as_kid('kid_b');
select is(tests.err($$select public.countersign_agreement(tests.acct('kid_b'), 1)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'and never by a kid');
select is(tests.err($$select public.agreement_preview(tests.acct('kid_b'), 1)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or its preview');

-- The preview runs with in_preview() on; the real thing with it off.
create function tests.must_be_in_preview() returns trigger language plpgsql as $$
begin
  if not public.in_preview() then
    raise exception 'outside preview';
  end if;
  return new;
end;
$$;
create trigger t_preview_sig before insert on public.agreement_signatures for each row
  when (new.signer = 'parent') execute function tests.must_be_in_preview();
select tests.as_parent();
select is(public.agreement_preview(tests.acct('kid_b'), 1) ->> 'problem', null,
  'the countersign preview runs its dry run with in_preview() on');
select is(tests.err($$select public.countersign_agreement(tests.acct('kid_b'), 1)$$), 'outside preview',
  '...and the real countersignature with it off');
select is(public.in_preview(), false, 'the flag is off again afterwards');
drop trigger t_preview_sig on public.agreement_signatures;

-- 8. Her history, and Dad's list ------------------------------------------------------------------

select tests.as_kid('kid_a');
select is((select jsonb_agg(a - 'copy') from jsonb_array_elements(public.my_agreements(tests.acct('kid_a'))) a),
  '[{"version": 1, "signed_on": "Oct 5", "dad_signed_on": "Oct 5"}]'::jsonb, 'her history: signed Oct 5, Dad signed Oct 5');
select is((select s ->> 'countersigned' from (select public.onboarding_state(tests.acct('kid_a')) s) x), 'true',
  'her welcome screens know Dad has signed');
select is(tests.err($$select public.my_agreements(tests.acct('kid_b'))$$), 'You can only see your own account.',
  'not her sister''s');
select tests.as_parent();
select is((select jsonb_agg(k - 'account_id' - 'signed_at' - 'dad_signed_at') from jsonb_array_elements(public.parent_agreements()) k),
  '[{"kid": "Kid A", "is_test": false, "onboarding_done": false, "current_version": 1, "signed_version": 1},
    {"kid": "Kid C", "is_test": false, "onboarding_done": false, "current_version": 1, "signed_version": null},
    {"kid": "Kid B", "is_test": true, "onboarding_done": false, "current_version": 1, "signed_version": 1}]'::jsonb,
  'Dad''s list: real kids first, who has signed which version');
select is((select k ->> 'dad_signed_at' from jsonb_array_elements(public.parent_agreements()) k where k ->> 'kid' = 'Kid A'),
  'Oct 5 at 10:00 am', '...and when he signed');
select is(public.parent_view(tests.acct('kid_a'), 'onboarding_state'), (select public.onboarding_state(tests.acct('kid_a'))),
  'View as reads her onboarding exactly as she does');
select is(public.parent_view(tests.acct('kid_a'), 'my_agreements'), public.my_agreements(tests.acct('kid_a')),
  '...and her signed agreements');

-- 9. Finishing onboarding --------------------------------------------------------------------------

select tests.as_kid('kid_a');
select lives_ok('select public.finish_onboarding()', 'she finishes onboarding after signing');
select is((select onboarding_done_at from public.accounts where id = tests.acct('kid_a')), public.app_now(), '...now');
select lives_ok('select public.finish_onboarding()', 'finishing again changes nothing');
select tests.as_kid('kid_b');
select is(tests.err('select public.finish_onboarding()'), 'Dad hasn''t signed your agreement yet. As soon as he does, this will work.',
  'kid B can''t finish before Dad signs her agreement too (pre-launch audit)');
select tests.as_parent();
select public.countersign_agreement(tests.acct('kid_b'), 1);
select tests.as_kid('kid_b');
select lives_ok('select public.finish_onboarding()', 'kid B finishes too (her Wish List was on during onboarding)');
select is((select array_agg(feature) from public.whats_new_seen where account_id = tests.acct('kid_b')), array['wishlist'],
  '...so the Wish List counts as met');

-- 10. What's new: once, for a feature switched on after she onboarded --------------------------------

select tests.as_kid('kid_b');
select is(public.whats_new(), '[]'::jsonb, 'nothing new for kid B: she met the Wish List in onboarding');
select tests.as_kid('kid_c');
select is(public.whats_new(), '[]'::jsonb, 'nothing before onboarding is done (onboarding shows it instead)');
insert into public.settings (key, value, effective_date) values ('feature:wishlist', 'everyone', date '2026-10-05');
insert into public.settings (key, value, effective_date) values ('feature:badges', 'everyone', date '2026-10-05');
select tests.as_kid('kid_a');
select is(public.whats_new(),
  $$[{"feature": "badges", "title": "New: badges 🏅", "link": null,
      "lines": ["You earn a badge for smart money choices, like keeping a GIC until it finishes or staying calm when a fund drops.",
                "Each badge unlocks something fun for your animal to wear."]},
     {"feature": "wishlist", "title": "New: your Wish List ⭐", "link": "/kid/wishlist",
      "lines": ["Add things you'd love to have, give each one stars, and see how close you are to affording it.",
                "If you still want something after 7 days, you can make it a savings goal.",
                "Mom and Dad can see your wish list."]}]$$::jsonb,
  'two features switched on after she onboarded: one screen each, numbers filled in');
select results_eq(
  $$select title, body from public.notifications where account_id = tests.acct('kid_a') and type = 'whats_new' order by title$$,
  $$values ('New: badges 🏅', 'You earn a badge for smart money choices, like keeping a GIC until it finishes or staying calm when a fund drops. Each badge unlocks something fun for your animal to wear.'),
           ('New: your Wish List ⭐', 'Add things you''d love to have, give each one stars, and see how close you are to affording it. If you still want something after 7 days, you can make it a savings goal. Mom and Dad can see your wish list.')$$,
  'each also lands in her bell');
select is(jsonb_array_length(public.whats_new()), 2, 'until she taps Got it, it''s still waiting...');
select is((select count(*)::int from public.notifications where account_id = tests.acct('kid_a') and type = 'whats_new'), 2,
  '...but the bell gets each notice once');
select lives_ok($$select public.mark_whats_new_seen('badges')$$, 'Got it');
select is((select jsonb_agg(w ->> 'feature') from jsonb_array_elements(public.whats_new()) w), '["wishlist"]'::jsonb,
  'badges is done; the Wish List still waits');
select is(tests.err($$select public.mark_whats_new_seen('rockets')$$), 'There''s no "rockets" to mark as seen.',
  'only real features');
select tests.as_parent();
select is(tests.err($$select public.whats_new()$$), 'Only a kid''s account can do this.', 'What''s new is hers only');

-- 11. A new version of the rules -------------------------------------------------------------------

insert into public.agreement_versions (version, intro, rules, promises, sign_line) values (2,
  'Some house rules have changed. Read them with Dad, and ask about anything that doesn''t make sense. When you both agree, you each sign.',
  '[{"icon": "💵", "title": "The money is real.", "text": "Dad keeps the cash."},
    {"icon": "🧪", "title": "A new rule.", "text": "Up to {cap}.", "mark": "new"}]'::jsonb,
  'Dad keeps your cash safe.', 'I''ve read these rules with Dad, and I agree.');
select is(public.agreement_changed_notices(2), 2, 'the girls who signed version 1 are told');
select results_eq(
  $$select title, body from public.notifications where account_id = tests.acct('kid_a') and dedupe_key like 'agreement_changed:%'$$,
  $$values ('Your Big Bucks agreement has changed',
            'Dad changed the house rules. Read the new version with Dad, and sign it when you both agree. Your old agreement stays in your history.')$$,
  'her notice');
select is(public.agreement_changed_notices(2), 2, 'running it again...');
select is((select count(*)::int from public.notifications where dedupe_key like 'agreement_changed:%'), 2,
  '...tells nobody twice');
select tests.as_kid('kid_a');
select is((select s ->> 'needs_signature' || ' ' || (s ->> 'signed_version') || ' ' || (s -> 'agreement' ->> 'title')
             from (select public.onboarding_state(tests.acct('kid_a')) s) x),
  'true 1 Your Big Bucks agreement (version 2)', 'she has version 2 to sign');
select is((select r ->> 'mark' || ' ' || (r ->> 'text')
             from jsonb_array_elements(public.onboarding_state(tests.acct('kid_a')) -> 'agreement' -> 'rules') r where r ->> 'icon' = '🧪'),
  'new Up to $1,250.00.', 'a new rule is marked new, with today''s numbers');
select is(tests.err('select public.request_deposit(1000)'),
  'Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed.',
  'until she has signed version 2 (and Dad too), new deposits wait (Dad, 2026-10-08)');
select isnt(public.sign_agreement(2), null, 'she signs version 2');
select is((select jsonb_agg(jsonb_build_object('version', a -> 'version', 'title', a -> 'copy' -> 'title', 'dad', a -> 'dad_signed_on'))
             from jsonb_array_elements(public.my_agreements(tests.acct('kid_a'))) a),
  '[{"version": 2, "title": "Your Big Bucks agreement (version 2)", "dad": null},
    {"version": 1, "title": "Your Big Bucks agreement", "dad": "Oct 5"}]'::jsonb,
  'both stay in her history, newest first; Dad hasn''t signed version 2 yet');
select tests.as_parent();
select is(public.agreement_preview(tests.acct('kid_a'), 2) ->> 'summary', 'Signed Kid A''s Big Bucks agreement (version 2).',
  'Dad''s log line names the version');

-- 12. Who may call, and nothing is edited ---------------------------------------------------------

select is(
  array(select r.rolname::text from pg_roles r
         where has_function_privilege(r.oid, 'public.request_deposit_core(bigint)', 'EXECUTE')
           and not r.rolsuper and r.rolname <> 'postgres' order by 1),
  '{}'::text[], 'nobody can skip the signature by calling the committed deposit function directly');
select is((select md5(prosrc) from pg_proc where oid = 'public.request_deposit_core(bigint)'::regprocedure),
  'ee4104c38cec33623506d7b93f222740', 'the committed deposit function is unchanged, byte for byte');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('house_rules', 'fill_house_rules', 'agreement_render', 'agreement_changed_notices',
                             'request_deposit_core', 'onboarding_state', 'sign_agreement', 'finish_onboarding',
                             'my_agreements', 'whats_new', 'mark_whats_new_seen', 'countersign_agreement',
                             'agreement_preview', 'parent_agreements')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         order by 1),
  array['agreement_preview', 'countersign_agreement', 'finish_onboarding', 'mark_whats_new_seen', 'my_agreements',
        'onboarding_state', 'parent_agreements', 'sign_agreement', 'whats_new'],
  'the screens'' functions are callable (each checks who); the helpers are internal');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('onboarding_state', 'sign_agreement', 'finish_onboarding', 'my_agreements', 'whats_new',
                             'mark_whats_new_seen', 'countersign_agreement', 'agreement_preview', 'parent_agreements')
           and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('service_role', p.oid, 'EXECUTE'))),
  '{}'::text[], 'signed-out visitors and the server role can''t call them');
select tests.nobody();
select is(tests.err($$update public.agreement_signatures set version = 1$$) is not null
          and tests.err($$delete from public.agreement_signatures$$) is not null
          and tests.err($$update public.agreement_versions set promises = 'x'$$) is not null
          and tests.err($$delete from public.agreement_versions where version = 2$$) is not null,
  true, 'signatures and versions can''t be edited or deleted');
select tests.as_kid('kid_c');
set local role authenticated;
select is(tests.err($$insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
                      values (tests.acct('kid_c'), 2, 'kid', gen_random_uuid(), '{}')$$),
  'permission denied for table agreement_signatures', 'a kid can''t write a signature directly');
select is((select count(*)::int from public.agreement_signatures), 0,
  'and can only see her own signatures (none yet; her sisters'' are hidden)');
reset role;

-- 13. The 24-hour wait in the agreement is the engine's -------------------------------------------

select tests.clock('2026-10-05 11:00');
select tests.as_parent();
-- Dad signs version 2 too, so money can move again (pre-launch audit).
select public.countersign_agreement(tests.acct('kid_a'), 2);
select public.approve_request((select id from public.requests where account_id = tests.acct('kid_a') and status = 'pending'
                                order by id limit 1));
select tests.as_kid('kid_a');
create temporary table w as select public.request_withdrawal(500) as id;
select tests.clock('2026-10-06 10:59');
select tests.as_parent();
select is(tests.err('select public.approve_request((select id from w))') like
          'Withdrawals wait ' || (public.house_rules() ->> 'withdraw_wait_hours') || ' hours%', true,
  'a withdrawal can''t be approved a minute before the agreement''s wait is up...');
select tests.clock('2026-10-06 11:00');
select lives_ok('select public.approve_request((select id from w))', '...and can be when it is');
select tests.as_kid('kid_a');
select is(tests.err('select public.request_deposit(499)'), 'The smallest deposit is ' || (public.house_rules() ->> 'min_savings') || '.',
  'the smallest deposit is the agreement''s');
select is(tests.err('select public.buy_gic(999, 1)'), 'The smallest GIC is ' || (public.house_rules() ->> 'min_invest') || '.',
  'the smallest GIC is the agreement''s');

select * from finish();
rollback;
