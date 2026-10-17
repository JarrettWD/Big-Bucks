-- Stage 10: "Make it yours" and badges (plan approved by Dad 2026-10-16: docs/plans/stage10-plan.md).
--
-- Badges reward decisions, never activity. They only READ money (the ledger, GICs, closes and
-- goals); nothing here posts, moves or rounds money, and no money function is changed or calls
-- anything here (Dad's change: the app makes a separate call after a money call succeeds).
--
-- 1. badge_kinds: the six badges and the accessory each unlocks (reference data, append-only).
-- 2. badges: award_key (each badge at most once, like posting_key), earned_on, links; append-only.
-- 3. goals.first_target_cents: the price a goal was set at (lowering it never earns the crown).
-- 4. Her look: the eight theme colours, sixteen animals and six accessories, as allowed keys.
-- 5. The rules: badge_rules() reads her history as of a day (so earlier decisions count when
--    the switch goes on, Dad's decision G); award_badges() gives what's new, once, with a notice.
-- 6. The checks: check_badges_through() (the nightly run, after reconcile; server only),
--    kid_check_my_badges() (after her GIC purchase or renewal), parent_check_badges() (after
--    Dad approves a deposit or changes a switch). None does anything in a preview or with
--    Badges off for her, and a kid whose figures show "Updating..." waits.
-- 7. Reads: kid_look, kid_badges, parent_looks, and "View as" (parent_view 'look', 'badges').
--    kid_set_look saves her choice.
-- 8. A failed badge check is a Dashboard alert only, never the health check (Dad's decision F).
-- Known answers: supabase/tests/badges_test.sql.

alter type public.job_name add value if not exists 'badges';
alter type public.alert_kind add value if not exists 'badge_check_failed';

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement', 'correct_fund_price', 'record_market_closure',
                    'reset_kid_pin', 'record_early_close', 'download_backup', 'wishlist_mark', 'check_badges'));

-- 1. The six badges ---------------------------------------------------------------------------------------

create table public.badge_kinds (
  key             text primary key check (key ~ '^[a-z_]+$'),
  sort            smallint not null unique,
  name            text not null check (btrim(name) <> ''),
  emoji           text not null check (btrim(emoji) <> ''),
  accessory       text not null unique check (accessory ~ '^[a-z_]+$'),
  accessory_name  text not null check (btrim(accessory_name) <> ''),  -- "crown": "Earn ... to wear the crown."
  accessory_words text not null check (btrim(accessory_words) <> ''), -- "a crown": "Your animal can wear a crown now."
  notice_title    text not null check (btrim(notice_title) <> ''),
  notice_line     text not null check (btrim(notice_line) <> ''),     -- {fund} and {goal} are filled in
  earned_line     text not null check (btrim(earned_line) <> ''),     -- on her Badges screen
  todo_line       text not null check (btrim(todo_line) <> '')        -- "Still to discover"
);
comment on table public.badge_kinds is
  'The badges (stage 10): each rewards a decision and unlocks one accessory. Append-only reference data; wording in MESSAGES §13.';

insert into public.badge_kinds
  (key, sort, name, emoji, accessory, accessory_name, accessory_words, notice_title, notice_line, earned_line, todo_line)
values
  ('first_gic', 1, 'First GIC', '🎉', 'party_hat', 'party hat', 'a party hat',
   '🎉 Badge: First GIC!', 'You locked money in a GIC to grow. That''s planning ahead!',
   'You locked money in a GIC to grow.', 'Buy a GIC and let your money grow.'),
  ('gic_to_end', 2, 'Kept it to the end', '🎓', 'grad_cap', 'graduation cap', 'a graduation cap',
   '🎓 Badge: Kept it to the end!', 'You waited until your GIC finished, so you got all its interest. Patience pays!',
   'You kept a GIC until it finished and got all its interest.', 'Keep a GIC until it finishes.'),
  ('drop_held', 3, 'Cool in a drop', '😎', 'sunglasses', 'sunglasses', 'sunglasses',
   '😎 Badge: Cool in a drop!', 'The {fund} fund fell more than 10%, and you stayed calm and kept it. That''s hard, and you did it.',
   'A fund fell more than 10%, and you stayed calm and kept it.',
   'When a fund drops a lot, stay calm and keep it for 30 days.'),
  ('gic_ladder', 4, 'GIC ladder', '🪜', 'top_hat', 'top hat', 'a top hat',
   '🪜 Badge: GIC ladder!', 'You have 3 GICs that finish on different days, so some money frees up sooner. Smart thinking!',
   'You had 3 GICs that finish on different days.', 'Have 3 GICs of $10 or more that finish on different days.'),
  ('first_dollar', 5, 'First dollar of interest', '💰', 'bow', 'bow', 'a bow',
   '💰 Badge: Your first dollar of interest!', 'Your money has earned $1.00 just by sitting and growing.',
   'Your money earned $1.00 of interest.', 'Let your money earn $1.00 of interest.'),
  ('goal_reached', 6, 'Goal reached', '👑', 'crown', 'crown', 'a crown',
   '👑 Badge: Goal reached!', 'You have enough for {goal}. You kept your eye on the prize!',
   'You saved enough for your goal.', 'Save enough for your goal.');

create trigger badge_kinds_no_update_delete
  before update or delete on public.badge_kinds
  for each row execute function public.reject_append_only_change();
create trigger badge_kinds_no_truncate
  before truncate on public.badge_kinds
  for each statement execute function public.reject_append_only_change();
alter table public.badge_kinds enable row level security;
create policy badge_kinds_read on public.badge_kinds for select to authenticated using (true);
revoke all on public.badge_kinds from public, anon, authenticated, service_role;
grant select on public.badge_kinds to authenticated, service_role;

-- 2. Badges: once each, append-only ---------------------------------------------------------------------------

alter table public.badges rename column earned_at to awarded_at;
alter table public.badges
  add column award_key       text,
  add column earned_on       date,
  add column related_gic_id  bigint references public.gic_holdings (id),
  add column related_goal_id bigint references public.goals (id),
  add column related_fund    text references public.funds (id),
  add column details         jsonb not null default '{}'::jsonb;
update public.badges b
   set award_key = 'badge:' || b.badge || ':' || b.account_id,
       earned_on = public.edmonton_local(b.awarded_at)::date
 where b.award_key is null;
alter table public.badges
  alter column award_key set not null,
  alter column earned_on set not null,
  add constraint badges_award_key_unique unique (award_key),
  add constraint badges_award_key_shape check (award_key = 'badge:' || badge || ':' || account_id),
  add constraint badges_kind_fk foreign key (badge) references public.badge_kinds (key);
comment on column public.badges.awarded_at is 'When the app gave the badge.';
comment on column public.badges.earned_on is 'The Alberta day she made the decision (earlier than awarded_at for history).';
comment on column public.badges.award_key is 'badge:<badge>:<account>: each badge at most once (like posting_key).';

create trigger badges_no_update_delete
  before update or delete on public.badges
  for each row execute function public.reject_append_only_change();
create trigger badges_no_truncate
  before truncate on public.badges
  for each statement execute function public.reject_append_only_change();

-- 3. The price a goal was set at ------------------------------------------------------------------------------

alter table public.goals add column first_target_cents bigint check (first_target_cents > 0);
update public.goals g set first_target_cents = g.target_cents where g.first_target_cents is null;
alter table public.goals alter column first_target_cents set not null;
comment on column public.goals.first_target_cents is
  'The price when she made it her goal. Kept as it was; the crown needs the higher of this and the price now.';

create function public.goals_keep_first_target()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.first_target_cents := new.target_cents;
  else
    new.first_target_cents := old.first_target_cents;
  end if;
  return new;
end;
$$;
create trigger goals_keep_first_target before insert or update on public.goals
  for each row execute function public.goals_keep_first_target();

-- 4. Her look ------------------------------------------------------------------------------------------------

-- Eight colours, each with white text at 4.5 : 1 or more (src/lib/look.ts lists the same, with names;
-- a Vitest test checks every ratio). The first is the default.
create function public.look_themes()
returns text[]
language sql immutable
set search_path = ''
as $$
  select array['#5B3FD1', '#8E24AA', '#B0127A', '#3949AB', '#0D47A1', '#00695C', '#1B5E20', '#795548'];
$$;
-- Sixteen animals (app files in public/avatars/animals, from Microsoft's Fluent Emoji, MIT).
create function public.look_animals()
returns text[]
language sql immutable
set search_path = ''
as $$
  select array['fox', 'panda', 'koala', 'bunny', 'cat', 'puppy', 'owl', 'penguin', 'unicorn', 'tiger',
               'frog', 'hedgehog', 'bear', 'hamster', 'lion', 'moose'];
$$;

alter table public.accounts
  add constraint accounts_theme_on_list check (theme_colour is null or theme_colour = any (public.look_themes())),
  add constraint accounts_animal_on_list check (avatar_animal is null or avatar_animal = any (public.look_animals())),
  add constraint accounts_accessory_on_list check (avatar_accessory is null or avatar_accessory in
    ('party_hat', 'grad_cap', 'sunglasses', 'top_hat', 'bow', 'crown'));

-- 5. The rules ------------------------------------------------------------------------------------------------
-- What she has earned as of the end of an Alberta day, from her history. Pure reads.
-- p_skip: badges she already has (not worked out again).

create function public.badge_rules(p_account uuid, p_through date, p_skip text[] default '{}')
returns table (badge text, earned_on date, related_gic_id bigint, related_goal_id bigint,
               related_fund text, details jsonb)
language plpgsql stable
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_end timestamptz := public.edmonton_start(p_through + 1);
  v_gic bigint;
  v_day date;
  v_at timestamptz;
  v_goal record;
  v_before bigint;
  v_target bigint;
  v_last date;
  v_fund record;
  v_drop record;
begin
  -- First GIC: her first GIC bought (a renewal is her choice too).
  if not 'first_gic' = any (p_skip) then
    select g.id, g.start_date into v_gic, v_day from public.gic_holdings g
     where g.account_id = p_account and g.created_at < v_end and g.start_date <= p_through
     order by g.start_date, g.id limit 1;
    if v_gic is not null then
      badge := 'first_gic'; earned_on := v_day; related_gic_id := v_gic;
      related_goal_id := null; related_fund := null; details := '{}'::jsonb;
      return next;
    end if;
  end if;

  -- Kept it to the end: a GIC that matured (a broken one never does).
  if not 'gic_to_end' = any (p_skip) then
    v_gic := null;
    select g.id, g.maturity_date into v_gic, v_day from public.gic_holdings g
     where g.account_id = p_account and g.status = 'matured' and g.maturity_date <= p_through
     order by g.maturity_date, g.id limit 1;
    if v_gic is not null then
      badge := 'gic_to_end'; earned_on := v_day; related_gic_id := v_gic;
      related_goal_id := null; related_fund := null; details := '{}'::jsonb;
      return next;
    end if;
  end if;

  -- GIC ladder: at the moment a GIC was bought, 3 or more of her GICs of at least $10.00 were
  -- active (bought, not broken, and not yet at their maturity day) with 3 or more different
  -- maturity dates.
  if not 'gic_ladder' = any (p_skip) then
    v_gic := null;
    with g as (
      select h.id, h.created_at, h.maturity_date, h.principal_cents,
             -- broken (money out early) or finished (its maturity day), whichever came first
             least((select min(t.effective_at) from public.transactions t
                     where t.gic_id = h.id and t.vehicle = 'gic' and t.amount_cents < 0),
                   public.edmonton_start(h.maturity_date)) as ended
        from public.gic_holdings h
       where h.account_id = p_account and h.created_at < v_end)
    select c.id, c.created_at into v_gic, v_at
      from g c
     where (select count(distinct x.maturity_date) from g x
             where x.principal_cents >= 1000 and x.created_at <= c.created_at
               and (x.ended is null or x.ended > c.created_at)) >= 3
     order by c.created_at, c.id limit 1;
    if v_gic is not null then
      badge := 'gic_ladder'; earned_on := public.edmonton_local(v_at)::date; related_gic_id := v_gic;
      related_goal_id := null; related_fund := null; details := '{}'::jsonb;
      return next;
    end if;
  end if;

  -- First dollar of interest: her interest lines (savings, GIC, late interest) add up to $1.00.
  -- Dividends and corrections aren't interest.
  if not 'first_dollar' = any (p_skip) then
    v_at := null;
    select x.effective_at into v_at
      from (select t.effective_at, t.id,
                   sum(t.amount_cents) over (order by t.effective_at, t.id) as total
              from public.transactions t
             where t.account_id = p_account and t.type = 'interest' and t.effective_at < v_end) x
     where x.total >= 100
     order by x.effective_at, x.id limit 1;
    if v_at is not null then
      badge := 'first_dollar'; earned_on := public.edmonton_local(v_at)::date; related_gic_id := null;
      related_goal_id := null; related_fund := null; details := '{}'::jsonb;
      return next;
    end if;
  end if;

  -- Goal reached: while it was her goal, her total worth (end of a day) reached the higher of the
  -- price she set and the price now; and the day before she set it, she didn't have enough yet.
  if not 'goal_reached' = any (p_skip) then
    for v_goal in
      select g.id, g.name, g.created_at, g.ended_at, greatest(g.first_target_cents, g.target_cents) as target
        from public.goals g
       where g.account_id = p_account and g.created_at < v_end
       order by g.created_at, g.id
    loop
      v_day := public.edmonton_local(v_goal.created_at)::date;
      v_last := least(coalesce(public.edmonton_local(v_goal.ended_at)::date, p_through), p_through);
      continue when v_last < v_day;
      select b.total_cents into v_before from public.daily_balances(p_account, v_day - 1, v_day - 1) b;
      continue when coalesce(v_before, 0) >= v_goal.target;
      select min(b.balance_date) into v_last
        from public.daily_balances(p_account, v_day, v_last) b where b.total_cents >= v_goal.target;
      if v_last is not null then
        badge := 'goal_reached'; earned_on := v_last; related_gic_id := null;
        related_goal_id := v_goal.id; related_fund := null;
        details := jsonb_build_object('goal', v_goal.name, 'target_cents', v_goal.target);
        return next;
        exit;
      end if;
    end loop;
  end if;

  -- Cool in a drop (Dad's A1): a fund's final close fell at least 10% below its highest final close
  -- on any day she held it (since she last went from no units to some), while she held at least
  -- $10.00 of it; and for the 30 days from that day she sold none of it and had no sell waiting.
  -- Closes before a split count in after-split terms, so a split is never a drop. Weekly backfill
  -- closes are never final, so they never count. Each high gives one chance.
  if not 'drop_held' = any (p_skip) then
    for v_fund in
      select f.id, f.name, f.market,
             (select public.edmonton_local(min(t.effective_at))::date from public.transactions t
               where t.account_id = p_account and t.fund_id = f.id and t.vehicle = 'stock') as first_day
        from public.funds f
       order by f.sort_order, f.id
    loop
      continue when v_fund.first_day is null or v_fund.first_day > p_through;
      for v_drop in
        with days as (
          select fp.price_date as d, fp.close,
                 fp.close * coalesce((select exp(sum(ln(s.ratio_from::numeric / s.ratio_to)))
                                        from public.fund_splits s
                                       where s.fund_id = v_fund.id and s.split_date > fp.price_date), 1) as adj,
                 (select coalesce(sum(t.units), 0) from public.transactions t
                   where t.account_id = p_account and t.fund_id = v_fund.id and t.vehicle = 'stock'
                     and t.effective_at < public.edmonton_start(fp.price_date + 1)) as units
            from public.fund_prices fp
           where fp.fund_id = v_fund.id and fp.source = 'daily'
             and fp.fetched_at >= public.close_time(v_fund.market, fp.price_date)
             and fp.price_date between v_fund.first_day and p_through),
        periods as (
          select days.*, sum(case when days.units <= 0 then 1 else 0 end) over (order by days.d) as period
            from days),
        held as (
          select periods.*, max(periods.adj) over (partition by periods.period order by periods.d
                                                   rows between unbounded preceding and current row) as high
            from periods where periods.units > 0)
        select distinct on (held.period, held.high) held.d, held.high, held.close
          from held
         where held.adj <= 0.9 * held.high and held.units * held.close >= 10
         order by held.period, held.high, held.d
      loop
        continue when v_drop.d + 30 > p_through;
        continue when exists (
          select 1 from public.transactions t
           where t.account_id = p_account and t.fund_id = v_fund.id and t.vehicle = 'stock' and t.type = 'transfer_out'
             and t.effective_at >= public.edmonton_start(v_drop.d)
             and t.effective_at < public.edmonton_start(v_drop.d + 31));
        continue when exists (
          select 1 from public.requests r
           where r.account_id = p_account and r.fund_id = v_fund.id and r.from_vehicle = 'stock'
             and r.created_at < public.edmonton_start(v_drop.d + 31)
             and (r.status = 'pending'
                  or coalesce(r.settled_at, r.decided_at) >= public.edmonton_start(v_drop.d)));
        badge := 'drop_held'; earned_on := v_drop.d + 30; related_gic_id := null;
        related_goal_id := null; related_fund := v_fund.id;
        details := jsonb_build_object('drop_day', v_drop.d, 'high', round(v_drop.high, 4), 'close', v_drop.close,
                                      'fund', v_fund.name);
        return next;
        return;
      end loop;
    end loop;
  end if;
end;
$$;
comment on function public.badge_rules(uuid, date, text[]) is
  'Stage 10: the badges an account has earned as of the end of an Alberta day, from her history. Reads only.';

-- The notice for a new badge.
create function public.badge_notice(p_account uuid, p_kind public.badge_kinds, p_earned_on date, p_details jsonb)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_line text := replace(replace(p_kind.notice_line, '{fund}', coalesce(p_details ->> 'fund', 'fund')),
                         '{goal}', coalesce(p_details ->> 'goal', 'your goal'));
  v_switch_on date;
  v_body text;
begin
  -- The day the Badges switch in force today took effect.
  select s.effective_date into v_switch_on from public.settings s
   where s.key = 'feature:badges' and s.effective_date <= v_today
   order by s.effective_date desc, s.id desc limit 1;
  if p_earned_on >= v_today - 1 then
    v_body := v_line;
  elsif p_earned_on < v_switch_on then
    v_body := 'You earned this on ' || public.fmt_date(p_earned_on) || '. Badges just arrived!';
  else
    v_body := 'You earned this on ' || public.fmt_date(p_earned_on) || '. ' || v_line;
  end if;
  if public.feature_enabled('personalisation', p_account) then
    v_body := v_body || ' Your animal can wear ' || p_kind.accessory_words || ' now.';
  end if;
  return v_body;
end;
$$;

-- Give what's new, once each, with a notice. Returns the new badge keys, or null when her figures
-- show "Updating..." (she waits). Nothing in a preview or with Badges off for her.
create function public.award_badges(p_account uuid, p_through date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_have text[];
  v_new jsonb := '[]'::jsonb;
  v_rule record;
  v_kind public.badge_kinds;
  v_id bigint;
begin
  if public.in_preview() or not public.feature_enabled('badges', p_account) then
    return '[]'::jsonb;
  end if;
  if public.figures_updating(p_account) then
    return null;
  end if;
  select coalesce(array_agg(b.badge), '{}') into v_have from public.badges b where b.account_id = p_account;
  for v_rule in
    select r.*, k.sort from public.badge_rules(p_account, p_through, v_have) r
      join public.badge_kinds k on k.key = r.badge
     order by r.earned_on, k.sort
  loop
    select * into v_kind from public.badge_kinds k where k.key = v_rule.badge;
    v_id := null;
    insert into public.badges (account_id, badge, unlocks_accessory, award_key, earned_on,
                               related_gic_id, related_goal_id, related_fund, details)
    values (p_account, v_rule.badge, v_kind.accessory, 'badge:' || v_rule.badge || ':' || p_account,
            v_rule.earned_on, v_rule.related_gic_id, v_rule.related_goal_id, v_rule.related_fund, v_rule.details)
    on conflict do nothing
    returning id into v_id;
    if v_id is not null then
      perform public.notify(p_account, 'badge', v_kind.notice_title,
                            public.badge_notice(p_account, v_kind, v_rule.earned_on, v_rule.details),
                            'badge:' || v_rule.badge || ':' || p_account);
      v_new := v_new || to_jsonb(v_rule.badge);
    end if;
  end loop;
  return v_new;
end;
$$;

-- 6. The checks -----------------------------------------------------------------------------------------------

-- The nightly run's check, after the money jobs and reconcile, in its own transaction (its own RPC call).
-- Each kid is checked on her own: one kid's failure is her alert, never anyone else's badges, and
-- never any money. Server only.
create function public.check_badges_through(p_through date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct record;
  v_new jsonb;
  v_awarded jsonb := '{}'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_failed jsonb := '[]'::jsonb;
  v_status public.job_status;
  v_out jsonb;
begin
  if p_through > public.app_today() then
    raise exception 'Can''t check badges for % because it hasn''t happened yet.', p_through;
  end if;
  for v_acct in select a.id, a.name, a.is_test from public.accounts a order by a.created_at, a.id loop
    continue when not public.feature_enabled('badges', v_acct.id);
    if public.figures_updating(v_acct.id) then
      v_skipped := v_skipped || to_jsonb(v_acct.id);
      continue;
    end if;
    begin
      v_new := public.award_badges(v_acct.id, p_through);
      v_awarded := v_awarded || jsonb_build_object(v_acct.id::text, coalesce(v_new, '[]'::jsonb));
      update public.alerts al set resolved_at = public.app_now()
       where al.kind = 'badge_check_failed' and al.account_id = v_acct.id and al.resolved_at is null;
    exception when others then
      v_failed := v_failed || jsonb_build_object('account_id', v_acct.id, 'error', left(sqlerrm, 200));
      if not exists (select 1 from public.alerts al where al.kind = 'badge_check_failed'
                      and al.account_id = v_acct.id and al.resolved_at is null) then
        insert into public.alerts (kind, account_id, is_quiet, message, details)
        values ('badge_check_failed', v_acct.id, v_acct.is_test,
                'Badges couldn''t be checked for ' || v_acct.name || ' on ' || public.fmt_date(p_through)
                  || '. No money is affected; the next evening''s run tries again.',
                jsonb_build_object('date', p_through, 'error', left(sqlerrm, 200)));
      end if;
    end;
  end loop;

  v_status := case when jsonb_array_length(v_failed) = 0 then 'ok' else 'failed' end;
  v_out := jsonb_build_object('status', v_status, 'through', p_through, 'awarded', v_awarded,
                              'skipped', v_skipped, 'failed', v_failed);
  insert into public.job_runs (job, run_for_date, status, details, finished_at)
  values ('badges', p_through, v_status, v_out, public.app_now());
  return v_out;
end;
$$;
comment on function public.check_badges_through(date) is
  'Stage 10: the nightly badge check, run after run_daily and reconcile in its own call. Never part of the money jobs.';

-- Her own check, which the app calls after her GIC purchase or renewal has succeeded.
create function public.kid_check_my_badges()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.kid_account();
begin
  if not public.feature_enabled('badges', v_acct) then
    return jsonb_build_object('on', false, 'awarded', '[]'::jsonb);
  end if;
  return jsonb_build_object('on', true,
                            'awarded', coalesce(public.award_badges(v_acct, public.app_today()), '[]'::jsonb));
end;
$$;

-- Dad's check, which his screens call after he approves a deposit (one kid) or changes a feature
-- switch (every kid). Logged like every parent action.
create function public.parent_check_badges(p_account uuid, p_after text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct record;
  v_new jsonb;
  v_awarded jsonb := '{}'::jsonb;
  v_gave text[] := '{}';
  v_names text;
begin
  perform public.require_parent();
  if p_after is null or p_after not in ('deposit', 'switch') then
    raise exception 'Say why you''re checking: after a "deposit" or a "switch".';
  end if;
  if p_account is not null and not exists (select 1 from public.accounts a where a.id = p_account) then
    raise exception 'There''s no such account.';
  end if;
  for v_acct in
    select a.id, a.name from public.accounts a
     where p_account is null or a.id = p_account
     order by a.created_at, a.id
  loop
    continue when not public.feature_enabled('badges', v_acct.id);
    v_new := coalesce(public.award_badges(v_acct.id, public.app_today()), '[]'::jsonb);
    v_awarded := v_awarded || jsonb_build_object(v_acct.id::text, v_new);
    if jsonb_array_length(v_new) > 0 then
      select string_agg(k.name, ', ' order by k.sort) into v_names
        from public.badge_kinds k where v_new ? k.key;
      v_gave := v_gave || (v_names || case when p_account is null then ' to ' || v_acct.name else '' end);
    end if;
  end loop;

  perform public.log_parent_action('check_badges', p_account, null,
    'Checked ' || case when p_account is null then 'every kid'
                       else (select a.name from public.accounts a where a.id = p_account) end
      || '''s badges after ' || case p_after when 'deposit' then 'approving a deposit' else 'changing a feature switch' end
      || ': ' || case when cardinality(v_gave) = 0 then 'nothing new' else 'gave ' || array_to_string(v_gave, '; ') end
      || '.',
    jsonb_build_object('after', p_after, 'awarded', v_awarded));
  return jsonb_build_object('awarded', v_awarded);
end;
$$;

-- 7. Reads and her choice --------------------------------------------------------------------------------------

-- Her look. An accessory shows only while Badges is on for her and she has its badge (after the
-- pre-launch reset clears badges, a crown she wore is simply not shown).
create function public.kid_look(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  a public.accounts;
  v_badges boolean;
begin
  if p_account_id is null or (p_account_id is distinct from public.my_account_id() and not public.is_parent()) then
    raise exception 'You can only see your own look.' using errcode = '42501';
  end if;
  select * into a from public.accounts x where x.id = p_account_id;
  v_badges := public.feature_enabled('badges', p_account_id);
  return jsonb_build_object(
    'on', public.feature_enabled('personalisation', p_account_id),
    'badges_on', v_badges,
    'theme', coalesce(a.theme_colour, (public.look_themes())[1]),
    'animal', a.avatar_animal,
    'accessory', case when v_badges and exists (
                        select 1 from public.badges b where b.account_id = p_account_id and b.unlocks_accessory = a.avatar_accessory)
                      then a.avatar_accessory end);
end;
$$;

create function public.kid_set_look(p_theme text, p_animal text, p_accessory text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.kid_account();
  v_theme text := upper(btrim(coalesce(p_theme, '')));
  v_kind public.badge_kinds;
begin
  if not public.feature_enabled('personalisation', v_acct) then
    raise exception 'Make it yours isn''t switched on for you yet.' using errcode = '42501';
  end if;
  if not v_theme = any (public.look_themes()) then
    raise exception 'Pick one of the colours on the list.';
  end if;
  if p_animal is null or not p_animal = any (public.look_animals()) then
    raise exception 'Pick one of the animals on the list.';
  end if;
  if p_accessory is not null then
    select * into v_kind from public.badge_kinds k where k.accessory = p_accessory;
    if not found then
      raise exception 'Pick something to wear from the list.';
    end if;
    if not public.feature_enabled('badges', v_acct)
       or not exists (select 1 from public.badges b where b.account_id = v_acct and b.badge = v_kind.key) then
      raise exception 'Earn the % badge to wear the %.', v_kind.name, v_kind.accessory_name;
    end if;
  end if;
  update public.accounts a
     set theme_colour = v_theme, avatar_animal = p_animal, avatar_accessory = p_accessory
   where a.id = v_acct;
  return public.kid_look(v_acct);
end;
$$;

-- Her badges (oldest first) and every kind, for her Badges screen, the picker and Dad.
create function public.kid_badges(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or (p_account_id is distinct from public.my_account_id() and not public.is_parent()) then
    raise exception 'You can only see your own badges.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'on', public.feature_enabled('badges', p_account_id),
    'earned', coalesce((
      select jsonb_agg(jsonb_build_object('badge', b.badge, 'earned_on', b.earned_on, 'awarded_at', b.awarded_at,
                                          'accessory', b.unlocks_accessory, 'related_fund', b.related_fund)
                       order by b.earned_on, k.sort, b.id)
        from public.badges b join public.badge_kinds k on k.key = b.badge
       where b.account_id = p_account_id), '[]'::jsonb),
    'kinds', (
      select jsonb_agg(jsonb_build_object('key', k.key, 'name', k.name, 'emoji', k.emoji, 'accessory', k.accessory,
                                          'accessory_name', k.accessory_name, 'earned_line', k.earned_line,
                                          'todo_line', k.todo_line)
                       order by k.sort)
        from public.badge_kinds k));
end;
$$;

-- Every kid's look at once, for Dad's Dashboard and Approvals.
create function public.parent_looks()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return coalesce((select jsonb_object_agg(a.id::text, public.kid_look(a.id)) from public.accounts a), '{}'::jsonb);
end;
$$;

-- "View as": her look and badges, read exactly as she reads them.
create or replace function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  r jsonb;
begin
  perform public.require_parent();
  if p_account is null or not exists (select 1 from public.accounts x where x.id = p_account) then
    raise exception 'There''s no account to view.';
  end if;

  case p_read
    when 'account' then
      select jsonb_build_object('account_id', x.id, 'name', x.name, 'is_test', x.is_test)
        into r from public.accounts x where x.id = p_account;
    when 'app_today' then
      r := to_jsonb(public.app_today());
    -- Her Home: the same rows her app reads from these views and her notices.
    when 'balances' then
      select to_jsonb(b) into r from public.account_balances b where b.account_id = p_account;
    when 'home_gics' then
      select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]'::jsonb) into r
        from public.gic_positions g
       where g.account_id = p_account
         and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null));
    when 'unread_notices' then
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                                                   'related_gic_id', n.related_gic_id)
                                order by n.created_at desc, n.id desc), '[]'::jsonb) into r
        from public.notifications n where n.account_id = p_account and n.read_at is null;
    when 'unread_count' then
      r := to_jsonb((select count(*) from public.notifications n where n.account_id = p_account and n.read_at is null));
    when 'figures_updating' then
      r := to_jsonb(public.figures_updating(p_account));
    when 'feature_enabled' then
      r := to_jsonb(public.feature_enabled(a ->> 'p_feature', p_account));
    when 'current_rates' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.current_rates() with ordinality t;
    when 'fund_overview' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.fund_overview(p_account) with ordinality t;
    when 'my_activity' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_activity(p_account, coalesce((a ->> 'p_limit')::integer, 20),
                                (a ->> 'p_before_at')::timestamptz, a ->> 'p_before_key') with ordinality t;
    when 'my_notices' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_notices(p_account, coalesce((a ->> 'p_limit')::integer, 50),
                               (a ->> 'p_before_id')::bigint) with ordinality t;
    when 'my_questions' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_questions(p_account) with ordinality t;
    -- B4: her onboarding and her signed agreements.
    when 'onboarding_state' then
      r := public.onboarding_state(p_account);
    when 'my_agreements' then
      r := public.my_agreements(p_account);
    -- Stage 9: her goal card on Home (never the "Got it" marker).
    when 'kid_goal' then
      r := public.kid_goal(p_account);
    -- Stage 10: her look and her badges.
    when 'kid_look' then
      r := public.kid_look(p_account);
    when 'kid_badges' then
      r := public.kid_badges(p_account);
    -- Her Graphs.
    when 'graph_ranges' then
      r := public.graph_ranges(p_account);
    when 'daily_balances' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.daily_balances(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'growth_by_option' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.growth_by_option(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'money_in_vs_earned' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.money_in_vs_earned(p_account) with ordinality t;
    when 'my_mix' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_mix(p_account) with ordinality t;
    when 'gic_ladder' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.gic_ladder(p_account) with ordinality t;
    when 'fund_chart' then
      r := public.fund_chart(p_account, a ->> 'p_fund_id', (a ->> 'p_from')::date);
    else
      raise exception 'There''s no "%" to view.', p_read;
  end case;
  return r;
end;
$$;

-- 8. A failed badge check never turns the health check red (Dad's decision F) ---------------------------------

create or replace function public.health_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_problems jsonb := '[]'::jsonb;
  v_behind jsonb := public.jobs_behind();
  v_r record;
  v_alerts integer := 0;
  v_jobs text;
  v_summary text;
begin
  for v_r in
    select al.id, al.kind, al.account_id, al.message, al.created_at from public.alerts al
     where al.resolved_at is null and not al.is_quiet
       and al.kind::text <> 'badge_check_failed'  -- stage 10: Dashboard only, never money
     order by al.id
  loop
    v_problems := v_problems || jsonb_build_object('kind', 'alert', 'alert_id', v_r.id, 'alert_kind', v_r.kind,
                                                   'account_id', v_r.account_id, 'message', v_r.message,
                                                   'since', v_r.created_at);
    v_alerts := v_alerts + 1;
  end loop;

  for v_r in select b ->> 'job' as job, (b ->> 'done_through')::date as done from jsonb_array_elements(v_behind) b loop
    v_problems := v_problems || jsonb_build_object('kind', 'behind', 'job', v_r.job, 'done_through', v_r.done,
      'message', 'The ' || v_r.job || ' job has only finished through '
                 || coalesce(to_char(v_r.done, 'Mon DD, YYYY'), 'never') || '.');
  end loop;

  v_jobs := public.jobs_behind_words(v_behind);
  v_summary := concat_ws(' ',
    case when v_alerts = 1 then '1 open alert: open the parent Dashboard to see it.'
         when v_alerts > 1 then v_alerts || ' open alerts: open the parent Dashboard to see them.' end,
    v_jobs || case when v_jobs is not null
                   then ' They catch up by themselves at the next evening run; if they don''t, see RUNBOOK, "How the nightly run works".'
              end);

  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'checked_at', public.app_now(),
                            'summary', coalesce(nullif(v_summary, ''), 'All well.'),
                            'problems', v_problems);
end;
$$;

-- 9. Who may call them ----------------------------------------------------------------------------------------

revoke all on function public.goals_keep_first_target() from public, anon, authenticated, service_role;
revoke all on function public.look_themes() from public, anon, authenticated, service_role;
revoke all on function public.look_animals() from public, anon, authenticated, service_role;
revoke all on function public.badge_rules(uuid, date, text[]) from public, anon, authenticated, service_role;
revoke all on function public.badge_notice(uuid, public.badge_kinds, date, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.award_badges(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.check_badges_through(date) from public, anon, authenticated, service_role;
revoke all on function public.kid_check_my_badges() from public, anon, authenticated, service_role;
revoke all on function public.parent_check_badges(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.kid_look(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_set_look(text, text, text) from public, anon, authenticated, service_role;
revoke all on function public.kid_badges(uuid) from public, anon, authenticated, service_role;
revoke all on function public.parent_looks() from public, anon, authenticated, service_role;

grant execute on function public.check_badges_through(date) to service_role;
grant execute on function public.kid_check_my_badges() to authenticated;
grant execute on function public.parent_check_badges(uuid, text) to authenticated;
grant execute on function public.kid_look(uuid) to authenticated;
grant execute on function public.kid_set_look(text, text, text) to authenticated;
grant execute on function public.kid_badges(uuid) to authenticated;
grant execute on function public.parent_looks() to authenticated;

-- 10. The "?" on her GIC ladder badge ------------------------------------------------------------------------

insert into public.glossary (term, kid_text) values
  ('GIC ladder', 'A ladder is a few GICs that finish on different days. Some of your money frees up every so often, while the rest keeps earning.')
on conflict (term) do nothing;
