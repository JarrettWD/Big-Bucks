-- "Matures", not "finishes", for GICs (Dad, 2026-10-20). Wording only: no function, rate,
-- setting or money row changes.
--
-- 1. A new glossary ? for "Matures", in kid words, and the two explanations that said "finish".
--    Each is reworded only if it still has its original words, so an explanation Dad has
--    reworded in Settings is never overwritten.
-- 2. The badge wording (badge_kinds) and the badges What's new screen (whats_new_features).
--    Both tables are append-only reference data with no function to edit them, so this
--    migration switches their guard off for these exact rewordings and straight back on, and
--    checks it is back on. Badges already earned store no wording (badges.details holds only
--    figures); notices already sent keep their words, as always.
--
-- Not changed here (each needs Dad's decision, see PROGRESS):
--   * the maturity notice "Your {term} GIC finished and earned ..." is written by the nightly
--     maturity job, a money function;
--   * the signed account agreement says "When a GIC finishes, ...": changing it means a new
--     agreement version for the girls to sign.
-- Known answers: supabase/tests/matures_wording_test.sql.

-- 1. The glossary ------------------------------------------------------------------------------------

insert into public.glossary (term, kid_text) values
  ('Matures', 'A GIC matures on the day its time is up. You get back the money you put in plus all the '
              || 'interest it earned, and then you choose what happens next.')
on conflict (term) do nothing;

update public.glossary
   set kid_text = 'The day your GIC matures, when its time is up. You get your money back plus the interest, '
                  || 'and you choose what to do next.'
 where term = 'Maturity'
   and kid_text = 'The day your GIC''s promise is finished. You get your money back plus the interest, and you choose what to do next.';

update public.glossary
   set kid_text = 'Having several GICs that mature at different times, like the steps of a ladder. '
                  || 'Some of your money is always close to being free.'
 where term = 'GIC ladder'
   and kid_text = 'Having several GICs that finish at different times, like the steps of a ladder. Some of your money is always close to being free.';

-- 2. Badges and the badges What's new ----------------------------------------------------------------

alter table public.badge_kinds disable trigger badge_kinds_no_update_delete;

update public.badge_kinds
   set notice_line = 'You waited until your GIC matured, so you got all its interest. Patience pays!',
       earned_line = 'You kept a GIC until it matured and got all its interest.',
       todo_line   = 'Keep a GIC until it matures.'
 where key = 'gic_to_end'
   and notice_line = 'You waited until your GIC finished, so you got all its interest. Patience pays!'
   and earned_line = 'You kept a GIC until it finished and got all its interest.'
   and todo_line   = 'Keep a GIC until it finishes.';

update public.badge_kinds
   set notice_line = 'You have 3 GICs that mature on different days, so some money frees up sooner. Smart thinking!',
       earned_line = 'You had 3 GICs that mature on different days.',
       todo_line   = 'Have 3 GICs of $10 or more that mature on different days.'
 where key = 'gic_ladder'
   and notice_line = 'You have 3 GICs that finish on different days, so some money frees up sooner. Smart thinking!'
   and earned_line = 'You had 3 GICs that finish on different days.'
   and todo_line   = 'Have 3 GICs of $10 or more that finish on different days.';

alter table public.badge_kinds enable trigger badge_kinds_no_update_delete;

alter table public.whats_new_features disable trigger whats_new_features_no_update_delete;

update public.whats_new_features
   set lines = jsonb_set(lines, '{0}',
         to_jsonb('You earn a badge for smart money choices, like keeping a GIC until it matures or staying calm when a fund drops.'::text))
 where feature = 'badges'
   and lines ->> 0 = 'You earn a badge for smart money choices, like keeping a GIC until it finishes or staying calm when a fund drops.';

alter table public.whats_new_features enable trigger whats_new_features_no_update_delete;

-- The guards are back on (a migration that left them off would stop here, and nothing would apply).
do $$
begin
  if exists (select 1 from pg_trigger
              where tgname in ('badge_kinds_no_update_delete', 'whats_new_features_no_update_delete')
                and tgenabled <> 'O') then
    raise exception 'An append-only guard was left switched off.';
  end if;
end;
$$;
