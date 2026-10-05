-- Stage 8 B2: the Settings screen. Rates (regular and specials) previewed with
-- every notice the girls will get and when; the cap, inflation, yields and feature
-- switches; rewording market-move notes and ? explanations, each logged. Known
-- answers, written first.
begin;
select plan(63);

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
-- Everything a preview must leave alone.
create function tests.footprint() returns text language sql as $$
  select concat_ws('/', (select count(*) from public.rates), (select count(*) from public.settings),
                   (select count(*) from public.notifications), (select count(*) from public.parent_actions),
                   (select string_agg(body, '|' order by id) from public.notes),
                   (select md5(string_agg(kid_text, '|' order by term)) from public.glossary));
$$;
create function tests.preview(p_action text, p_args text) returns jsonb language sql as $$
  select public.parent_change_preview(p_action, p_args::jsonb);
$$;
create function tests.problem(p_action text, p_args text) returns text language sql as $$
  select public.parent_change_preview(p_action, p_args::jsonb) ->> 'problem';
$$;
create function tests.kid_notices(p_type text) returns table (title text, body text) language sql as $$
  select n.title, n.body from public.notifications n
   where n.account_id = (select account_id from public.profiles where username = 'kid_a') and n.type::text = p_type
   order by n.id;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

select tests.clock('2026-10-05 10:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);

-- 1. The rates as the screen shows them -----------------------------------------------------------

select tests.as_parent();
select results_eq(
  $$select r ->> 'what', r ->> 'text', r ->> 'rate' from jsonb_array_elements(public.parent_settings() -> 'rates') r$$,
  $$values ('Savings'::text, '2.0%'::text, '2'::text), ('1-month GIC', '2.5%', '2.5'), ('3-month GIC', '3.0%', '3'),
           ('6-month GIC', '4.0%', '4'), ('9-month GIC', '4.5%', '4.5'), ('1-year GIC', '5.0%', '5'),
           ('2-year GIC', '6.0%', '6')$$,
  'every rate in force today, savings first, then each GIC term');
select is((select (s ->> 'rate_from') || ' ' || (s ->> 'rate_to') from (select public.parent_settings() s) x),
  '2026-10-12 2026-10-18', 'a new rate starts 7 days out by default; a special runs a week by default');
select is((select count(*)::int from jsonb_array_elements(public.parent_settings() -> 'rate_history') h
            where h ->> 'who' = 'Starting rate' and h ->> 'when' is null), 7,
  'the history starts with the 7 starting rates');

-- 2. Previewing a rate change: every notice, and when --------------------------------------------

create temporary table fp as select tests.footprint() as f;
select is(tests.preview('add_rate', '{"vehicle": "savings", "rate": "1.5", "note": "The Bank of Canada cut rates"}'),
  '{"problem": null, "summary": "Savings rate set to 1.5% from Oct 12.",
    "facts": {"what": "Savings", "before": "2.0%", "after": "1.5%", "from": "Oct 12", "special": false,
              "to": null, "back_to": null},
    "notices": [
      {"title": "Savings rate drops from 2.0% to 1.5% on Oct 12", "kids": 2, "on": null,
       "body": "The Bank of Canada cut rates. Tip: GICs bought before then keep today''s rates."},
      {"title": "The new savings rate is now 1.5%", "kids": 2, "on": "Oct 12", "body": "It applies from today."}]}'::jsonb,
  'savings 2.0% → 1.5% (7 days out by default): the log line, the notice now and the one on Oct 12');
select is(tests.footprint(), (select f from fp), 'the preview leaves no rate, notice or log row behind');

select is(tests.preview('add_rate',
    '{"vehicle": "gic", "gic_term": 12, "rate": "6.5", "effective_date": "2026-10-06", "end_date": "2026-10-12", "note": "Fall special"}'),
  '{"problem": null, "summary": "Special: 1-year GIC at 6.5% from Oct 6 to Oct 12.",
    "facts": {"what": "1-year GIC", "before": "5.0%", "after": "6.5%", "from": "Oct 6", "special": true,
              "to": "Oct 12", "back_to": "5.0%"},
    "notices": [
      {"title": "Special: 1-year GICs at 6.5% from Oct 6 to Oct 12", "kids": 2, "on": null,
       "body": "Fall special. After Oct 12 the rate goes back to 5.0%. A GIC bought during the special keeps 6.5% until it matures."},
      {"title": "The 1-year GIC special at 6.5% starts today", "kids": 2, "on": "Oct 6", "body": "It ends after Oct 12."},
      {"title": "The 1-year GIC special has ended", "kids": 2, "on": "Oct 13",
       "body": "1-year GICs are back to 5.0%. GICs bought during the special keep 6.5%."}]}'::jsonb,
  'a one-week special: the notice now, the day it starts, and the day after it ends');

select is(tests.preview('add_rate', '{"vehicle": "gic", "gic_term": 3, "rate": "3.25", "effective_date": "2026-10-05"}') -> 'notices',
  '[{"title": "3-month GIC rate goes up from 3.0% to 3.25% today", "kids": 2, "on": null,
     "body": "GICs you already have keep their locked-in rate."}]'::jsonb,
  'a change from today: one notice, right away (no "now live" notice later)');
select is(tests.footprint(), (select f from fp), '...and still nothing left behind');

-- The real action's messages, word for word.
select is(tests.problem('add_rate', '{"vehicle": "savings", "rate": "1.5", "effective_date": "2026-10-04"}'),
  'A rate change can''t start in the past: it would change interest already earned.', 'a date in the past');
select is(tests.problem('add_rate', '{"vehicle": "gic", "gic_term": 12, "rate": "6", "effective_date": "2026-10-10", "end_date": "2026-10-09"}'),
  'A special can''t end before it starts.', 'a special ending before it starts');
select is(tests.problem('add_rate', '{"vehicle": "savings", "rate": "2.1234"}'),
  'Use at most 3 decimal places (for example 2.125).', 'too many decimal places');
select is(tests.problem('add_rate', '{"vehicle": "gic", "gic_term": 2, "rate": "3"}'),
  'GIC terms are 1, 3, 6, 9, 12 or 24 months.', 'a term that doesn''t exist');
select is(tests.problem('add_rate', '{"vehicle": "stock", "rate": "3"}'),
  'Rates are only for savings and GICs.', 'not savings or a GIC');
select is(tests.problem('add_rate', '{"vehicle": "savings", "rate": "two"}'),
  'Type the rate as a percent, like 2.5.', 'not a number');
select is(tests.problem('add_rate', '{"vehicle": "savings", "rate": "150"}'),
  'Type the rate as a percent, like 2.5.', '100% or more');

-- 3. Saving it: what she gets is word for word what the preview showed ----------------------------

create temporary table pv as
  select tests.preview('add_rate', '{"vehicle": "savings", "rate": "1.5", "note": "The Bank of Canada cut rates"}') as p;
select public.add_rate('savings', null, '1.5', null, 'The Bank of Canada cut rates');
select results_eq($$select title, body from tests.kid_notices('rate_change')$$,
  $$select n ->> 'title', n ->> 'body' from pv, jsonb_array_elements(p -> 'notices') n where n ->> 'on' is null$$,
  'her notice right away is the one previewed');
select is((select summary from public.parent_actions order by id desc limit 1), (select p ->> 'summary' from pv),
  'the log line is the one previewed');
select tests.clock('2026-10-12 16:30');
select tests.nobody();
select public.send_rate_notices(date '2026-10-12');
select results_eq($$select title, body from tests.kid_notices('rate_live')$$,
  $$select n ->> 'title', n ->> 'body' from pv, jsonb_array_elements(p -> 'notices') n where n ->> 'on' = 'Oct 12'$$,
  'on Oct 12 she gets the "now live" notice previewed for Oct 12');
select tests.clock('2026-10-05 10:00');

select tests.as_parent();
select is((select r -> 'scheduled' from jsonb_array_elements(public.parent_settings() -> 'rates') r where r ->> 'what' = 'Savings'),
  jsonb_build_array(jsonb_build_object('id', (select max(id) from public.rates where vehicle = 'savings'),
                                       'text', '1.5% from Oct 12', 'special', false, 'from', 'Oct 12')),
  'Settings shows the change waiting for Oct 12, with its id (for Cancel)');
select is((select r ->> 'text' from jsonb_array_elements(public.parent_settings() -> 'rates') r where r ->> 'what' = 'Savings'),
  '2.0%', '...and 2.0% still in force today');
select is(public.parent_settings() -> 'rate_history' -> 0,
  '{"what": "Savings", "text": "1.5% from Oct 12", "special": false, "note": "The Bank of Canada cut rates",
    "who": "Parent", "when": "Oct 5 at 10:00 am", "cancelled": false}'::jsonb,
  'the history, newest first, with the note, who and when');

-- 4. A special in force, and ending on time --------------------------------------------------------

select public.add_rate('gic', 12, 6.5, date '2026-10-05', 'Fall special', date '2026-10-11');
select is((select jsonb_build_object('text', r ->> 'text', 'special_to', r ->> 'special_to', 'regular', r ->> 'regular')
             from jsonb_array_elements(public.parent_settings() -> 'rates') r where r ->> 'what' = '1-year GIC'),
  '{"text": "6.5%", "special_to": "Oct 11", "regular": "5.0%"}'::jsonb,
  'a special in force: its rate, its last day, and the regular rate it goes back to');
select is((public.rate_on('gic', 12, date '2026-10-11')).rate, 6.500::numeric, 'the special applies on its last day');
select is((public.rate_on('gic', 12, date '2026-10-12')).rate, 5.000::numeric, '...and not the day after');
select tests.nobody();
select public.send_rate_notices(date '2026-10-12');
select is((select count(*)::int from public.notifications where title = 'The 1-year GIC special has ended'), 2,
  'the day after it ends, both kids are told it has ended');
select tests.as_parent();
select is(public.parent_settings() -> 'rate_history' -> 0 ->> 'text', '6.5% special, Oct 5 to Oct 11',
  'the special is in the history with its dates');

-- 5. The cap, inflation, yields and switches --------------------------------------------------------

select is(tests.preview('set_setting', '{"key": "deposit_cap_cents", "value": "80000", "effective_date": "2026-10-12"}'),
  '{"problem": null, "summary": "Deposit cap set to $800.00 from Oct 12.",
    "facts": {"before": "$1,000.00", "after": "$800.00", "from": "Oct 12"},
    "notices": [{"title": "The deposit limit goes down from $1,000.00 to $800.00 on Oct 12", "kids": 2, "on": null,
                 "body": "This is the most you can put in, minus what you take out. Interest and gains don''t count. If you''ve already put in more than that, nothing is taken away. You just can''t add more for now."}]}'::jsonb,
  'lowering the cap with 7 days'' notice: the log line and the notice both kids get right away');
select is(tests.preview('set_setting', '{"key": "inflation_rate", "value": "2.5"}'),
  '{"problem": null, "summary": "Inflation rate set to 2.5% from Oct 5.",
    "facts": {"before": "2.0%", "after": "2.5%", "from": "Oct 5"}, "notices": []}'::jsonb,
  'inflation: the log line, and no notice');
select is(tests.preview('set_setting', '{"key": "dividend_yield:tsx", "value": "3"}') ->> 'summary',
  'TSX dividend yield set to 3.0% from Oct 5.', 'a dividend yield');
select is(tests.preview('set_setting', '{"key": "feature:wishlist", "value": "test"}') -> 'facts',
  '{"before": "Off", "after": "Test accounts only", "from": "Oct 5"}'::jsonb, 'a feature switch, in words');
select is(tests.problem('set_setting', '{"key": "feature:wishlist", "value": "on"}'),
  'A feature switch is off, test or everyone.', 'a switch only takes off, test or everyone');
select public.set_setting('deposit_cap_cents', '120000', date '2026-10-20', 'More room for birthday money');
create temporary table fp2 as select tests.footprint() as f;
select tests.preview('set_setting', '{"key": "deposit_cap_cents", "value": "50000"}');
select is(tests.footprint(), (select f from fp2), 'a setting preview leaves nothing behind');

select is(public.parent_settings() -> 'cap',
  ('{"key": "deposit_cap_cents", "value": "100000", "text": "$1,000.00",
    "scheduled": [{"id": ' || (select max(id) from public.settings where key = 'deposit_cap_cents')
                 || ', "value": "120000", "text": "$1,200.00", "from": "Oct 20"}],
    "history": [{"value": "120000", "text": "$1,200.00", "from": "Oct 20", "note": "More room for birthday money",
                 "who": "Parent", "when": "Oct 5 at 10:00 am", "cancelled": false},
                {"value": "100000", "text": "$1,000.00", "from": "Jan 1", "note": "Starting cap: $1,000 in net deposits per kid.",
                 "who": "Starting rule", "when": null, "cancelled": false}]}')::jsonb,
  'the cap: in force today, waiting for Oct 20, and its history with who and when');
select results_eq(
  $$select y ->> 'name', y -> 'card' ->> 'text' from jsonb_array_elements(public.parent_settings() -> 'yields') y$$,
  $$values ('Dow Jones'::text, '1.8%'::text), ('Nasdaq-100', '0.6%'), ('TSX', '2.8%')$$,
  'each fund''s dividend yield');
select results_eq(
  $$select f ->> 'name', f -> 'card' ->> 'text' from jsonb_array_elements(public.parent_settings() -> 'features') f$$,
  $$values ('wishlist'::text, 'Off'::text), ('personalisation', 'Off'), ('badges', 'Off')$$,
  'each feature switch, off unless switched on');
select is(public.parent_settings() -> 'inflation' ->> 'text', '2.0%', 'the inflation rate');
select is(public.parent_settings() -> 'recent' -> 0,
  '{"summary": "Deposit cap set to $1,200.00 from Oct 20.", "who": "Parent", "when": "Oct 5 at 10:00 am"}'::jsonb,
  'the latest change, for "Done … Recorded: Parent, …"');

-- 6. Rewording a market-move note -------------------------------------------------------------------

insert into public.notes (note_date, fund_id, body, audience, auto_key)
  values (date '2026-10-02', 'nasdaq100', 'Big jump today.', 'kids', 'move:nasdaq100:2026-10-02');
create temporary table note_id as select max(id) as id from public.notes;
create temporary table fp3 as select tests.footprint() as f;

select is(public.parent_change_preview('edit_note',
    jsonb_build_object('note_id', (select id from note_id), 'body', '  Tech stocks had a great day.  ')),
  '{"problem": null, "summary": "Reworded the Nasdaq-100 note for Oct 2.",
    "facts": {"before": "Big jump today.", "after": "Tech stocks had a great day."}, "notices": []}'::jsonb,
  'previewing a note: before and after, the log line, and no notice');
select is(tests.footprint(), (select f from fp3), '...leaving the note as it was');
select lives_ok(format($$select public.edit_note(%s, 'Tech stocks had a great day.')$$, (select id from note_id)),
  'Dad rewords the note');
select is((select details from public.parent_actions order by id desc limit 1),
  '{"fund_id": "nasdaq100", "note_date": "2026-10-02", "before": "Big jump today.", "after": "Tech stocks had a great day."}'::jsonb,
  'the log keeps the wording before and after');
select is((public.parent_settings() -> 'notes' -> 0) - 'id',
  '{"date": "Oct 2", "fund": "Nasdaq-100", "body": "Tech stocks had a great day.", "for_kids": true}'::jsonb,
  'Settings lists the note with its new wording');
select tests.as_kid('kid_a');
select is((select body from public.notes where id = (select id from note_id)), 'Tech stocks had a great day.',
  'she sees the new wording');
select tests.as_parent();
select is(tests.err(format($$select public.edit_note(%s, 'Tech stocks had a great day.')$$, (select id from note_id))),
  'That''s the same wording as now.', 'the same wording is refused');
select is(tests.err(format($$select public.edit_note(%s, '   ')$$, (select id from note_id))),
  'The note needs some words, and at most 300 letters.', 'no words');
select is(tests.err(format($$select public.edit_note(%s, repeat('a', 301))$$, (select id from note_id))),
  'The note needs some words, and at most 300 letters.', 'more than 300 letters');
select is(tests.err('select public.edit_note(999999, ''Hello'')'), 'There''s no note #999999.', 'a note that doesn''t exist');

-- 7. Rewording a ? explanation ------------------------------------------------------------------------

select is(tests.preview('edit_glossary', '{"term": "GIC", "text": "A promise to leave money alone for a while, for a better rate."}') ->> 'summary',
  'Reworded the explanation of "GIC".', 'previewing an explanation: the log line');
select lives_ok($$select public.edit_glossary('GIC', 'A promise to leave money alone for a while, for a better rate.')$$,
  'Dad rewords the explanation');
select tests.as_kid('kid_a');
select is((select kid_text from public.glossary where term = 'GIC'),
  'A promise to leave money alone for a while, for a better rate.', 'she reads the new wording behind the ?');
select tests.as_parent();
select is((select details ->> 'term' from public.parent_actions where action = 'edit_glossary'), 'GIC',
  'the log says which word');
select is(tests.err('select public.edit_glossary(''Bitcoin'', ''Hello'')'), 'There''s no "Bitcoin" in the glossary.',
  'only words already in the glossary (the app asks for them by name)');
select is(tests.err('select public.edit_glossary(''GIC'', repeat(''a'', 401))'),
  'The explanation needs some words, and at most 400 letters.', 'more than 400 letters');

-- 8. Who may call ----------------------------------------------------------------------------------------

select tests.as_kid('kid_a');
select is(tests.err('select public.edit_glossary(''GIC'', ''Hacked'')'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t reword the glossary');
select is(tests.err(format($$select public.edit_note(%s, 'Hacked')$$, (select id from note_id))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or a note');
select is(tests.err($$select public.parent_change_preview('add_rate', '{"vehicle": "savings", "rate": "9"}')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or preview a rate');
select tests.as_parent('aal1');
select is(tests.err('select public.edit_glossary(''GIC'', ''Hacked'')'),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'nor can a parent without the code');
select tests.nobody();

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('edit_note', 'edit_glossary', 'parent_settings', 'parent_change_preview', 'setting_text',
                             'preview_notices', 'setting_card', 'rate_row_text', 'feature_list')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         order by 1),
  array['edit_glossary', 'edit_note', 'parent_change_preview', 'parent_settings'],
  'signed-in users may call the four Settings functions (each requires a parent with the code); the helpers are internal');

-- 9. The dry runs run with in_preview() on ------------------------------------------------------------

create function tests.must_be_in_preview() returns trigger language plpgsql as $$
begin
  if not public.in_preview() then
    raise exception 'outside preview';
  end if;
  return new;
end;
$$;
create trigger t_preview_rates before insert on public.rates for each row execute function tests.must_be_in_preview();
create trigger t_preview_notes before update on public.notes for each row execute function tests.must_be_in_preview();
create trigger t_preview_glossary before update on public.glossary for each row execute function tests.must_be_in_preview();
select tests.as_parent();
select is(tests.problem('add_rate', '{"vehicle": "savings", "rate": "1.75"}'), null,
  'a rate preview runs its dry run with in_preview() on');
select is(public.parent_change_preview('edit_note', jsonb_build_object('note_id', (select id from note_id), 'body', 'Wow.')) ->> 'problem',
  null, '...and so does a note preview');
select is(tests.problem('edit_glossary', '{"term": "GIC", "text": "Locked box."}'), null, '...and a glossary preview');
select isnt(tests.err('select public.add_rate(''savings'', null, 1.75)'), null, 'while the real action runs with it off');
select is(public.in_preview(), false, 'the flag is off again afterwards');
drop trigger t_preview_rates on public.rates;
drop trigger t_preview_notes on public.notes;
drop trigger t_preview_glossary on public.glossary;

select * from finish();
rollback;
