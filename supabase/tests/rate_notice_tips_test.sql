-- The rate-change notice's tip (Dad, 2026-10-19, from the beta). A savings change never gives a
-- GIC tip; "buy before then to keep today's rate" only on a GIC cut, for that term, and only when
-- today's rate for that term holds until then. Tonight's case: a savings cut and a 1-month GIC
-- special starting the same day.
begin;
select plan(22);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_parent() returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000000f', 'role', 'authenticated', 'aal', 'aal2')::text, true);
$$;
-- The notice the kid got for a rate row.
create function tests.notice(p_rate bigint) returns public.notifications language sql as $$
  select n.* from public.notifications n where n.related_rate_id = p_rate and n.type = 'rate_change' limit 1;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
insert into public.accounts (name, is_test) values ('Test tips', true);
select tests.clock('2026-10-19 19:00');
select tests.as_parent();

create temp table r (k text primary key, id bigint);

-- 1. A savings cut alone: no GIC tip, a true neutral line instead.
insert into r select 'savings_cut', public.add_rate('savings', null, 1.0, '2026-10-26', 'Test cut');
select is((tests.notice((select id from r where k = 'savings_cut'))).title, 'Savings rate drops from 2.0% to 1.0% on Oct 26',
  'a savings cut: the title is as before');
select is((tests.notice((select id from r where k = 'savings_cut'))).body,
  'Test cut. This doesn''t change GIC rates. A GIC keeps the rate it was bought at until it matures.',
  '...and the body never says to buy a GIC first');

-- 2. A savings raise alone: the same neutral line.
insert into r select 'savings_up', public.add_rate('savings', null, 1.5, '2026-11-02', null);
select is((tests.notice((select id from r where k = 'savings_up'))).title, 'Savings rate goes up from 1.0% to 1.5% on Nov 2',
  'a savings raise');
select is((tests.notice((select id from r where k = 'savings_up'))).body,
  'This doesn''t change GIC rates. A GIC keeps the rate it was bought at until it matures.', '...the same neutral line');

-- 3. A GIC cut alone: the tip, for that term, with today's rate.
insert into r select 'gic_cut', public.add_rate('gic', 3, 2.5, '2026-10-26', null);
select is((tests.notice((select id from r where k = 'gic_cut'))).title, '3-month GIC rate drops from 3.0% to 2.5% on Oct 26',
  'a GIC cut');
select is((tests.notice((select id from r where k = 'gic_cut'))).body,
  'Tip: a 3-month GIC bought before Oct 26 keeps today''s 3.0%.', '...the tip names the term, the day and today''s rate');

-- 4. A GIC raise alone, from today: no "buy before" tip, but what a new GIC gets (Dad, 2026-10-19).
insert into r select 'gic_up', public.add_rate('gic', 6, 4.5, '2026-10-19', null);
select is((tests.notice((select id from r where k = 'gic_up'))).title, '6-month GIC rate goes up from 4.0% to 4.5% today',
  'a GIC raise');
select is((tests.notice((select id from r where k = 'gic_up'))).body,
  'GICs you already have keep their locked-in rate. A 6-month GIC bought from today gets 4.5%.',
  '...no tip to buy before it; a new one gets the new rate "from today"');

-- 5. A GIC special alone: its own words, no "buy before" tip.
insert into r select 'gic_special', public.add_rate('gic', 12, 6.0, '2026-10-20', null, '2026-10-30');
select is((tests.notice((select id from r where k = 'gic_special'))).title, 'Special: 1-year GICs at 6.0% from Oct 20 to Oct 30',
  'a GIC special');
select is((tests.notice((select id from r where k = 'gic_special'))).body,
  'Last day: Oct 30. Then the rate goes back to 5.0%. A GIC bought during the special keeps 6.0% until it matures.',
  '...its own words, no tip to buy before it');

-- 6. Tonight's case: a 1-month GIC special starting the same day as the savings cut (case 1).
insert into r select 'gic1_special', public.add_rate('gic', 1, 5.0, '2026-10-26', 'Test special', '2026-11-01');
select is((tests.notice((select id from r where k = 'gic1_special'))).title, 'Special: 1-month GICs at 5.0% from Oct 26 to Nov 1',
  'the 1-month special starting Oct 26');
select ok((tests.notice((select id from r where k = 'savings_cut'))).body not like '%bought before%'
          and (tests.notice((select id from r where k = 'savings_cut'))).body not like '%Tip%',
  '...and the savings cut on the same day never nudges her to buy a 1-month GIC before it');

-- 7. A GIC cut with a special for that term in between: no tip (today's rate doesn't hold until then).
insert into r select 'gic9_special', public.add_rate('gic', 9, 5.5, '2026-10-21', null, '2026-10-24');
insert into r select 'gic9_cut', public.add_rate('gic', 9, 4.0, '2026-10-27', null);
select is((tests.notice((select id from r where k = 'gic9_cut'))).title, '9-month GIC rate drops from 4.5% to 4.0% on Oct 27',
  'a 9-month cut after a 9-month special');
select is((tests.notice((select id from r where k = 'gic9_cut'))).body, 'GICs you already have keep their locked-in rate.',
  '...no "keeps today''s rate" tip: a special comes first, so today''s rate doesn''t hold until then');

-- 8. A GIC cut for one term, while another term has a special: the tip still holds for its own term.
insert into r select 'gic24_cut', public.add_rate('gic', 24, 5.5, '2026-10-28', null);
select is((tests.notice((select id from r where k = 'gic24_cut'))).body,
  'Tip: a 2-year GIC bought before Oct 28 keeps today''s 6.0%.', 'a 2-year cut keeps its own tip (other terms don''t matter)');

-- 10. A GIC raise on a later day, after a special for that term has ended: the tip names the day.
insert into r select 'gic12_up', public.add_rate('gic', 12, 5.5, '2026-11-05', null);
select is((tests.notice((select id from r where k = 'gic12_up'))).title, '1-year GIC rate goes up from 5.0% to 5.5% on Nov 5',
  'a 1-year raise on Nov 5 (its special ended Oct 30)');
select is((tests.notice((select id from r where k = 'gic12_up'))).body,
  'GICs you already have keep their locked-in rate. A 1-year GIC bought from Nov 5 gets 5.5%.',
  '...a new one bought from Nov 5 gets the new rate');

-- 11. A GIC raise while a special for that term runs on or after its first day: no tip that contradicts it.
insert into r select 'gic1_up', public.add_rate('gic', 1, 3.0, '2026-10-22', null);
select is((tests.notice((select id from r where k = 'gic1_up'))).title, '1-month GIC rate goes up from 2.5% to 3.0% on Oct 22',
  'a 1-month raise on Oct 22, with the 1-month special from Oct 26 to Nov 1');
select is((tests.notice((select id from r where k = 'gic1_up'))).body, 'GICs you already have keep their locked-in rate.',
  '...no "bought from Oct 22 gets 3.0%": the special would contradict it');

-- 12. A GIC raise with a later change for that term already planned: no tip.
insert into r select 'gic24_up', public.add_rate('gic', 24, 6.5, '2026-10-21', null);
select is((tests.notice((select id from r where k = 'gic24_up'))).title, '2-year GIC rate goes up from 6.0% to 6.5% on Oct 21',
  'a 2-year raise on Oct 21, with the 2-year cut on Oct 28 already planned');
select is((tests.notice((select id from r where k = 'gic24_up'))).body, 'GICs you already have keep their locked-in rate.',
  '...no tip: it only lasts until the cut');

-- 9. Nothing else changed: the rate rows are exactly what Dad saved.
select is((select count(*) from public.rates where id in (select id from r))::int, 12, 'every change was saved as before');

select * from finish();
rollback;
