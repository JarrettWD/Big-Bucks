-- "Matures", not "finishes" (Dad, 2026-10-20; migration 20261101000000_matures_wording.sql).
-- The wording changed, the append-only guards are back on, and nothing else moved.
begin;
select plan(12);

select is((select kid_text from public.glossary where term = 'Matures'),
  'A GIC matures on the day its time is up. You get back the money you put in plus all the interest it earned, and then you choose what happens next.',
  'the "Matures" ? explains it in kid words');
select is((select kid_text from public.glossary where term = 'Maturity'),
  'The day your GIC matures, when its time is up. You get your money back plus the interest, and you choose what to do next.',
  'the "Maturity" ? says matures');
select is((select kid_text from public.glossary where term = 'GIC ladder'),
  'Having several GICs that mature at different times, like the steps of a ladder. Some of your money is always close to being free.',
  'the "GIC ladder" ? says mature');

select is((select array[notice_line, earned_line, todo_line] from public.badge_kinds where key = 'gic_to_end'),
  array['You waited until your GIC matured, so you got all its interest. Patience pays!',
        'You kept a GIC until it matured and got all its interest.',
        'Keep a GIC until it matures.'],
  'the "Kept it to the end" badge says matured / matures');
select is((select array[notice_line, earned_line, todo_line] from public.badge_kinds where key = 'gic_ladder'),
  array['You have 3 GICs that mature on different days, so some money frees up sooner. Smart thinking!',
        'You had 3 GICs that mature on different days.',
        'Have 3 GICs of $10 or more that mature on different days.'],
  'the "GIC ladder" badge says mature');
select is((select lines from public.whats_new_features where feature = 'badges'),
  '["You earn a badge for smart money choices, like keeping a GIC until it matures or staying calm when a fund drops.", "Each badge unlocks something fun for your animal to wear."]'::jsonb,
  'the badges What''s new says matures, and its second line is unchanged');

select is((select count(*)::int from public.badge_kinds where row_to_json(badge_kinds)::text ~* 'finish'), 0,
  'no badge says finish any more');
select is((select count(*)::int from public.glossary where kid_text ~* '\mfinish'), 0,
  'no ? explanation says finish any more');

-- The guards are back on: the reworded rows can't be changed or removed.
select throws_ok($$update public.badge_kinds set todo_line = 'x' where key = 'gic_to_end'$$, null, null,
  'badge_kinds is append-only again');
select throws_ok($$update public.whats_new_features set title = 'x' where feature = 'badges'$$, null, null,
  'whats_new_features is append-only again');

-- Nothing else moved: still six badges and nine What's new screens.
select is((select count(*)::int from public.badge_kinds), 6, 'still six badges');
select is((select count(*)::int from public.whats_new_features), 9, 'still nine What''s new screens');

select * from finish();
rollback;
