-- Stage 10: badges and "Make it yours" (plan approved by Dad 2026-10-16).
-- Known answers for each badge rule, with the cases that must NOT award one; once only;
-- the separate check calls (the money functions don't call them); the nightly check's
-- safety; the switches; her look; RLS and grants.
-- Badges only read money. Nothing here posts, moves or rounds money.
begin;
select plan(114);

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Test closes count as fetched just after their close (only final closes count).
create function tests.fetched_after_close() returns trigger language plpgsql as $t$
begin
  new.fetched_at := greatest(new.fetched_at,
    public.close_time((select f.market from public.funds f where f.id = new.fund_id), new.price_date)
      + interval '30 minutes');
  return new;
end;
$t$;
create trigger tests_fetched_after_close before insert on public.fund_prices
  for each row execute function tests.fetched_after_close();

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
create function tests.acct(p_username text) returns uuid language sql security definer as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.new_kid(p_username text, p_is_test boolean default true) returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, p_is_test) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb),
           (v_acct, 1, 'parent', v_user, null);
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
-- Money in the normal way: she asks, Dad approves.
create function tests.fund(p_username text, p_cents bigint) returns bigint language plpgsql as $$
declare
  v_req bigint;
begin
  perform tests.as_kid(p_username);
  v_req := public.request_deposit(p_cents);
  perform tests.as_parent();
  perform public.approve_request(v_req);
  perform tests.nobody();
  return v_req;
end;
$$;
-- Money straight into the ledger at a given Alberta moment (for the history-only rules).
create function tests.deposit(p_username text, p_cents bigint, p_at text) returns void language sql as $$
  insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
  values (tests.acct(p_username), 'savings', 'deposit', p_cents, public.edmonton_at(p_at::timestamp));
$$;
create function tests.interest(p_username text, p_cents bigint, p_at text) returns void language sql as $$
  insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
  values (tests.acct(p_username), 'savings', 'interest', p_cents, public.edmonton_at(p_at::timestamp));
$$;
-- Units bought or sold at a close (both sides of the move, as settlement posts them).
create function tests.hold(p_username text, p_fund text, p_units numeric, p_price numeric, p_day date)
returns void language sql as $$
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, effective_at)
  values (tests.acct(p_username), 'savings', null, 'transfer_out', -ceil(p_units * p_price * 100)::bigint, null, null,
          public.edmonton_at(p_day + time '14:00')),
         (tests.acct(p_username), 'stock', p_fund, 'transfer_in', ceil(p_units * p_price * 100)::bigint, p_units, p_price,
          public.edmonton_at(p_day + time '14:00'));
$$;
create function tests.sell(p_username text, p_fund text, p_units numeric, p_price numeric, p_day date)
returns void language sql as $$
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, effective_at)
  values (tests.acct(p_username), 'stock', p_fund, 'transfer_out', -ceil(p_units * p_price * 100)::bigint, -p_units, p_price,
          public.edmonton_at(p_day + time '14:00')),
         (tests.acct(p_username), 'savings', null, 'transfer_in', ceil(p_units * p_price * 100)::bigint, null, null,
          public.edmonton_at(p_day + time '14:00'));
$$;
-- One close for every trading day in a range.
create function tests.closes(p_fund text, p_from date, p_to date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close)
  select p_fund, d::date, p_close
    from generate_series(p_from, p_to, interval '1 day') d
   where public.is_trading_day((select f.market from public.funds f where f.id = p_fund), d::date);
$$;
create function tests.run(p_job text, p_day date) returns text language plpgsql as $$
declare
  r jsonb;
begin
  perform tests.nobody();
  execute format('select public.%I($1)', p_job) into r using p_day;
  return r ->> 'status';
end;
$$;
-- The nightly badge check, as the server runs it.
create function tests.nightly(p_day date) returns jsonb language plpgsql as $$
begin
  perform tests.nobody();
  return public.check_badges_through(p_day);
end;
$$;
create function tests.has(p_username text, p_badge text) returns boolean language sql as $$
  select exists (select 1 from public.badges b where b.account_id = tests.acct(p_username) and b.badge = p_badge);
$$;
create function tests.earned_on(p_username text, p_badge text) returns date language sql as $$
  select b.earned_on from public.badges b where b.account_id = tests.acct(p_username) and b.badge = p_badge;
$$;
create function tests.notices(p_username text, p_badge text) returns bigint language sql as $$
  select count(*) from public.notifications n
   where n.account_id = tests.acct(p_username) and n.type = 'badge'
     and n.dedupe_key = 'badge:' || p_badge || ':' || tests.acct(p_username);
$$;
create function tests.notice(p_username text, p_badge text) returns public.notifications language sql as $$
  select n.* from public.notifications n
   where n.dedupe_key = 'badge:' || p_badge || ':' || tests.acct(p_username);
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
insert into public.settings (key, value, effective_date)
values ('feature:badges', 'test', date '2026-01-01'),
       ('feature:personalisation', 'test', date '2026-01-01');

select tests.clock('2026-10-16 09:00');
select tests.new_kid('bg_gic');           -- First GIC, ladder, kept to the end, her look
select tests.new_kid('bg_same');          -- 3 GICs on one date, a broken rung
select tests.new_kid('bg_small');         -- a rung under $10
select tests.new_kid('bg_broke');         -- her only GIC broken
select tests.new_kid('bg_int');           -- first dollar of interest
select tests.new_kid('bg_hold');          -- held through a drop
select tests.new_kid('bg_nine');          -- a 9.9% drop
select tests.new_kid('bg_part');          -- a partial sell, then a second drop held
select tests.new_kid('bg_req');           -- a sell request during the drop
select tests.new_kid('bg_more');          -- buys more during the drop
select tests.new_kid('bg_tiny');          -- under $10 in the fund
select tests.new_kid('bg_split');         -- a weekly close and a split, no real drop
select tests.new_kid('bg_goal');          -- reaches her goal (price lowered on the way)
select tests.new_kid('bg_above');         -- already had enough when she set it
select tests.new_kid('bg_ended');         -- stopped her goal before reaching it
select tests.new_kid('bg_fail');          -- the forced failure
select tests.new_kid('bg_real', false);   -- a real kid: the switches are "test accounts only"
select tests.new_kid('bg_sis', false);    -- her sister

-- 1. Reference data and the table ----------------------------------------------------------------------

select is((select array_agg(k.key order by k.sort) from public.badge_kinds k),
  array['first_gic', 'gic_to_end', 'drop_held', 'gic_ladder', 'first_dollar', 'goal_reached'],
  'six badges, in order');
select is((select array_agg(k.accessory order by k.sort) from public.badge_kinds k),
  array['party_hat', 'grad_cap', 'sunglasses', 'top_hat', 'bow', 'crown'],
  'each unlocks its accessory (Dad: top hat and bow for now)');
select is(tests.err($$update public.badge_kinds set accessory = 'crown' where key = 'first_gic'$$),
  'badge_kinds is append-only: update is not allowed. Add a new row instead.', 'the badge list can''t be changed');

-- 2. First GIC, at purchase, through the separate call -------------------------------------------------

select tests.fund('bg_gic', 50000);
select tests.as_kid('bg_gic');
select public.buy_gic(10000, 1);
select is(tests.has('bg_gic', 'first_gic'), false, 'buying a GIC awards nothing by itself (the money function doesn''t call badges)');
select is(public.kid_check_my_badges() -> 'awarded', '["first_gic"]'::jsonb, 'her check right after gives First GIC');
select is(tests.earned_on('bg_gic', 'first_gic'), date '2026-10-16', '...earned the day she bought it');
select is((tests.notice('bg_gic', 'first_gic')).title, '🎉 Badge: First GIC!', 'the notice''s title');
select is((tests.notice('bg_gic', 'first_gic')).body,
  'You locked money in a GIC to grow. That''s planning ahead! Your animal can wear a party hat now.',
  '...and its words, with the accessory line (Make it yours is on for her)');
select is(public.kid_check_my_badges() -> 'awarded', '[]'::jsonb, 'checking again gives nothing new');
select is((select count(*) from public.badges where account_id = tests.acct('bg_gic')), 1::bigint, 'one badge row');
select is(tests.notices('bg_gic', 'first_gic'), 1::bigint, 'one notice');

-- 3. GIC ladder -------------------------------------------------------------------------------------------

select public.buy_gic(1000, 3);
select is(public.kid_check_my_badges() -> 'awarded', '[]'::jsonb, 'two GICs on two dates: no ladder yet');
select public.buy_gic(1000, 6);
select is(public.kid_check_my_badges() -> 'awarded', '["gic_ladder"]'::jsonb, 'a third date: GIC ladder');
select is((tests.notice('bg_gic', 'gic_ladder')).title, '🪜 Badge: GIC ladder!', 'the ladder notice');

select tests.fund('bg_same', 10000);
select tests.as_kid('bg_same');
select public.buy_gic(1000, 1);
select public.buy_gic(1000, 1);
select public.buy_gic(1000, 1);
select is(public.kid_check_my_badges() -> 'awarded', '["first_gic"]'::jsonb,
  'three GICs that all finish on the same day are not a ladder');
select public.buy_gic(1000, 3);
select is(public.kid_check_my_badges() -> 'awarded', '[]'::jsonb, 'two different dates: still not');
select public.break_gic((select id from public.gic_holdings where account_id = tests.acct('bg_same') and term_months = 3));
select public.buy_gic(1000, 6);
select is(public.kid_check_my_badges() -> 'awarded', '[]'::jsonb,
  'two active dates plus one broken GIC is not a ladder');

-- A rung under $10 (only possible by hand: buy_gic already refuses it).
insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
values (tests.acct('bg_small'), 1000, 2, 3, date '2026-10-16', date '2027-01-16'),
       (tests.acct('bg_small'), 1000, 2, 9, date '2026-10-16', date '2027-07-16'),
       (tests.acct('bg_small'), 999, 2, 12, date '2026-10-16', date '2027-10-16');
select is(tests.nightly('2026-10-16') -> 'awarded' -> tests.acct('bg_small')::text, '["first_gic"]'::jsonb,
  'a rung under $10.00 doesn''t count toward a ladder');

-- 4. Kept it to the end, and a broken GIC -------------------------------------------------------------

select tests.fund('bg_broke', 10000);
select tests.as_kid('bg_broke');
select public.buy_gic(1000, 1);
select public.break_gic((select id from public.gic_holdings where account_id = tests.acct('bg_broke')));

select tests.clock('2026-11-16 16:30');
select 'ran: ' || tests.run('mature_gics', '2026-11-16');
select is(tests.nightly('2026-11-15') -> 'awarded' -> tests.acct('bg_gic')::text, '[]'::jsonb,
  'the night before maturity: nothing');
select is(tests.nightly('2026-11-16') -> 'awarded' -> tests.acct('bg_gic')::text, '["gic_to_end"]'::jsonb,
  'the maturity night: Kept it to the end');
select is(tests.earned_on('bg_gic', 'gic_to_end'), date '2026-11-16', '...on the maturity day');
select is(tests.has('bg_broke', 'gic_to_end'), false, 'a broken GIC never earns it');
select is(tests.has('bg_broke', 'first_gic'), true, '...though buying it was still her first GIC (badges are never taken away)');
select is((select status from public.job_runs where job = 'badges' order by id desc limit 1), 'ok'::public.job_status,
  'the nightly check records its own job row');

-- 5. First dollar of interest ---------------------------------------------------------------------------

select tests.interest('bg_int', 60, '2026-11-01 00:10');
select tests.interest('bg_int', 39, '2026-12-01 00:10');
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
values (tests.acct('bg_int'), 'savings', 'dividend', 500, public.edmonton_at('2026-10-05 09:00'));
insert into public.transactions (account_id, vehicle, type, amount_cents, note, counts_as, effective_at)
values (tests.acct('bg_int'), 'savings', 'correction', 100, 'Test fix', 'earned', public.edmonton_at('2026-10-06 09:00'));
select tests.clock('2027-01-05 17:00');
select is(tests.nightly('2026-12-31') -> 'awarded' -> tests.acct('bg_int')::text, '[]'::jsonb,
  '$0.99 of interest (plus a dividend and a correction) is not a dollar');
select tests.interest('bg_int', 1, '2027-01-01 00:10');
select is(tests.nightly('2027-01-01') -> 'awarded' -> tests.acct('bg_int')::text, '["first_dollar"]'::jsonb,
  'one more cent of interest makes $1.00');
select is(tests.earned_on('bg_int', 'first_dollar'), date '2027-01-01', '...the day the dollar was reached');
select is((tests.notice('bg_int', 'first_dollar')).body,
  'You earned this on Jan 1. Your money has earned $1.00 just by sitting and growing. Your animal can wear a bow now.',
  'given days later, it says when she earned it');

-- 6. Cool in a drop ----------------------------------------------------------------------------------------
-- The Dow fund: 400 to Nov 6, a high of 440 on Nov 9, then exactly 10% down (396) to Dec 31;
-- a new high of 500 on Jan 4, then 12% down (440) to Feb 26.
select tests.closes('dow', '2026-11-02', '2026-11-06', 400);
select tests.closes('dow', '2026-11-09', '2026-11-09', 440);
select tests.closes('dow', '2026-11-10', '2026-12-31', 396);
select tests.closes('dow', '2027-01-04', '2027-01-04', 500);
select tests.closes('dow', '2027-01-05', '2027-02-26', 440);
-- The Nasdaq fund: a 9.9% drop (330 to 297.33).
select tests.closes('nasdaq100', '2026-11-02', '2026-11-06', 300);
select tests.closes('nasdaq100', '2026-11-09', '2026-11-09', 330);
select tests.closes('nasdaq100', '2026-11-10', '2026-12-31', 297.33);
-- The TSX fund: a weekly backfill close of 60 would look like a high; then a 2-for-1 split.
select tests.closes('tsx', '2026-11-02', '2026-11-05', 50);
insert into public.fund_prices (fund_id, price_date, close, source) values ('tsx', '2026-11-06', 60, 'weekly_backfill');
select tests.closes('tsx', '2026-11-09', '2027-01-08', 52);
insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to) values ('tsx', '2027-01-11', 1, 2);
select tests.closes('tsx', '2027-01-11', '2027-02-26', 26);

select tests.hold('bg_hold', 'dow', 1, 400, '2026-11-02');
select tests.hold('bg_nine', 'nasdaq100', 1, 300, '2026-11-02');
select tests.hold('bg_part', 'dow', 1, 400, '2026-11-02');
select tests.sell('bg_part', 'dow', 0.1, 396, '2026-11-20');
select tests.hold('bg_req', 'dow', 1, 400, '2026-11-02');
insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, held_units, created_at)
values (tests.acct('bg_req'), 'move', 'stock', 'savings', 'dow', 1000, 0.02525253, public.edmonton_at('2026-11-25 10:00'));
select tests.hold('bg_more', 'dow', 1, 400, '2026-11-02');
select tests.hold('bg_more', 'dow', 1, 396, '2026-11-16');
select tests.hold('bg_tiny', 'dow', 0.02, 400, '2026-11-02');
select tests.hold('bg_split', 'tsx', 1, 50, '2026-11-02');
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, effective_at)
values (tests.acct('bg_split'), 'stock', 'tsx', 'split_adjust', 0, 1, public.edmonton_at('2027-01-11 06:00'));

select tests.clock('2027-03-15 17:00');
select is(tests.nightly('2026-12-09') -> 'awarded' -> tests.acct('bg_hold')::text, '[]'::jsonb,
  'day 29 after the drop started: not yet');
select is(tests.nightly('2026-12-10') -> 'awarded' -> tests.acct('bg_hold')::text, '["drop_held"]'::jsonb,
  'day 30, holding all along, after an exactly-10% drop: Cool in a drop');
select is(tests.earned_on('bg_hold', 'drop_held'), date '2026-12-10', '...earned on day 30');
select is((select related_fund from public.badges where account_id = tests.acct('bg_hold') and badge = 'drop_held'), 'dow',
  '...for the Dow fund');
select is((select details ->> 'drop_day' from public.badges where account_id = tests.acct('bg_hold') and badge = 'drop_held'),
  '2026-11-10', '...from the drop that started Nov 10');
select is((tests.notice('bg_hold', 'drop_held')).body,
  'You earned this on Dec 10. The Dow Jones fund fell more than 10%, and you stayed calm and kept it. That''s hard, and you did it. Your animal can wear sunglasses now.',
  'given later, it says when');
select is(tests.has('bg_more', 'drop_held'), true, 'buying more during the drop still counts');
select is(tests.earned_on('bg_more', 'drop_held'), date '2026-12-10', '...on the same day 30');
select is(tests.has('bg_nine', 'drop_held'), false, 'a 9.9% drop is not 10%');
select is(tests.has('bg_part', 'drop_held'), false, 'a partial sell on day 10 breaks it');
select is(tests.has('bg_req', 'drop_held'), false, 'asking to sell during the 30 days breaks it');
select is(tests.has('bg_tiny', 'drop_held'), false, 'under $10.00 in the fund doesn''t count');

select is(tests.nightly('2027-02-03') -> 'awarded' -> tests.acct('bg_part')::text, '[]'::jsonb,
  'after the broken one, a new high and a new 12% drop: day 29 not yet');
select is(tests.nightly('2027-02-04') -> 'awarded' -> tests.acct('bg_part')::text, '["drop_held"]'::jsonb,
  '...day 30 of the second drop: Cool in a drop');
select is((select details ->> 'drop_day' from public.badges where account_id = tests.acct('bg_part') and badge = 'drop_held'),
  '2027-01-05', '...from the drop that started Jan 5');
select is(tests.has('bg_hold', 'drop_held') and (select count(*) from public.badges
            where account_id = tests.acct('bg_hold') and badge = 'drop_held') = 1, true,
  'the second drop gives nobody a second one');
select is(tests.nightly('2027-03-15') -> 'awarded' -> tests.acct('bg_split')::text, '[]'::jsonb,
  'a weekly backfill close is never a high, and a 2-for-1 split is not a 50% drop');

-- 7. Goal reached ------------------------------------------------------------------------------------------

select tests.deposit('bg_goal', 30000, '2026-10-16 10:00');
insert into public.goals (account_id, name, target_cents, created_at)
values (tests.acct('bg_goal'), 'Bike', 35000, public.edmonton_at('2026-10-20 10:00'));
select is((select first_target_cents from public.goals where account_id = tests.acct('bg_goal')), 35000::bigint,
  'a goal remembers the price it was set at');
select tests.deposit('bg_goal', 4000, '2026-10-25 10:00');
update public.goals set target_cents = 33000 where account_id = tests.acct('bg_goal');
select is(tests.nightly('2026-10-27') -> 'awarded' -> tests.acct('bg_goal')::text, '[]'::jsonb,
  '$340 against a goal lowered to $330 from $350: lowering the price doesn''t help');
select tests.fund('bg_goal', 2000);
select is(tests.has('bg_goal', 'goal_reached'), false, 'Dad''s approval awards nothing by itself');
select tests.as_parent();
select is(public.parent_check_badges(tests.acct('bg_goal'), 'deposit') -> 'awarded' -> tests.acct('bg_goal')::text,
  '["goal_reached"]'::jsonb, 'his check right after the approval: Goal reached ($360 of $350)');
select is((select action || ' · ' || summary from public.parent_actions order by id desc limit 1),
  'check_badges · Checked Test bg_goal''s badges after approving a deposit: gave Goal reached.', 'logged');
select is((tests.notice('bg_goal', 'goal_reached')).body,
  'You have enough for Bike. You kept your eye on the prize! Your animal can wear a crown now.', 'the crown notice');

select tests.deposit('bg_above', 50000, '2026-10-16 10:00');
insert into public.goals (account_id, name, target_cents, created_at)
values (tests.acct('bg_above'), 'Game', 40000, public.edmonton_at('2026-10-20 10:00'));
select tests.deposit('bg_ended', 30000, '2026-10-16 10:00');
insert into public.goals (account_id, name, target_cents, created_at, ended_at, ended_how)
values (tests.acct('bg_ended'), 'Skates', 35000, public.edmonton_at('2026-10-20 10:00'),
        public.edmonton_at('2026-10-22 10:00'), 'stopped');
select tests.deposit('bg_ended', 10000, '2026-10-25 10:00');
select tests.nightly('2027-03-15');
select is(tests.has('bg_above', 'goal_reached'), false, 'already enough when she set it: no crown');
select is(tests.has('bg_ended', 'goal_reached'), false, 'enough only after she stopped the goal: no crown');

-- 8. Once only ----------------------------------------------------------------------------------------------

select tests.nightly('2027-03-15');
select tests.nightly('2027-03-15');
select tests.as_kid('bg_gic');
select public.kid_check_my_badges();
select is((select count(*) from public.badges b where b.account_id = tests.acct('bg_gic')), 3::bigint,
  'running every check again gives no extra badges');
select is((select count(*) from public.notifications n where n.account_id = tests.acct('bg_gic') and n.type = 'badge'),
  3::bigint, '...and no extra notices');
select is((select count(distinct award_key) = count(*) from public.badges), true, 'every award key is unique');

-- 9. Previews and the switch ----------------------------------------------------------------------------------

select tests.clock('2027-03-16 10:00');
select tests.fund('bg_real', 10000);
select tests.as_kid('bg_real');
select public.buy_gic(1000, 1);
select is(public.kid_check_my_badges(), '{"on": false, "awarded": []}'::jsonb,
  'with Badges off for her (a real kid while it''s "test accounts only"), her check does nothing');
select is(tests.has('bg_real', 'first_gic'), false, '...no badge');
select is(tests.nightly('2027-03-16') -> 'awarded' ? tests.acct('bg_real')::text, false, '...and the nightly skips her');

select tests.fund('bg_fail', 10000);
select tests.as_kid('bg_fail');
select public.buy_gic(1000, 1);
select set_config('bigbucks.preview', 'on', true);
select is(public.kid_check_my_badges() -> 'awarded', '[]'::jsonb, 'during a preview, a check awards nothing');
select set_config('bigbucks.preview', '', true);
select is(tests.has('bg_fail', 'first_gic'), false, '...and leaves nothing behind');

-- 10. The nightly check's safety ------------------------------------------------------------------------------

create function tests.boom() returns trigger language plpgsql as $t$
begin
  if new.account_id = tests.acct('bg_fail') then
    raise exception 'a badge bug';
  end if;
  return new;
end;
$t$;
create trigger tests_boom before insert on public.badges for each row execute function tests.boom();
select tests.clock('2027-03-16 17:00');
select is(tests.nightly('2027-03-16') ->> 'status', 'failed', 'a badge bug for one kid marks tonight''s badge check failed');
select is((select status from public.job_runs where job = 'badges' order by id desc limit 1), 'failed'::public.job_status,
  '...in its own job row');
select is((select count(*) from public.alerts where kind = 'badge_check_failed' and resolved_at is null
            and account_id = tests.acct('bg_fail')), 1::bigint, '...with one alert for Dad''s Dashboard');
select is((select message from public.alerts where kind = 'badge_check_failed' and account_id = tests.acct('bg_fail')),
  'Badges couldn''t be checked for Test bg_fail on Mar 16. No money is affected; the next evening''s run tries again.',
  '...in plain words');
select is((select is_quiet from public.alerts where kind = 'badge_check_failed' and account_id = tests.acct('bg_fail')), true,
  '...quiet, as she is a test account');
select is((select count(*) from jsonb_array_elements(public.health_check() -> 'problems') p
            where p ->> 'alert_kind' = 'badge_check_failed'), 0::bigint,
  'a badge alert never turns the health check red (Dad''s decision F)');
select is((select count(*) from jsonb_array_elements(public.jobs_behind()) b where b ->> 'job' = 'badges'), 0::bigint,
  'the health check never waits for the badge check');
select is((select prosrc not like '%badge%' from pg_proc where proname = 'nightly_status'), true,
  'tonight''s "done" doesn''t depend on badges');
select is((select prosrc not like '%badge%' from pg_proc where proname = 'run_daily'), true,
  'run_daily doesn''t run badges');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prosrc ilike '%badge%'
              and p.proname in ('buy_gic', 'break_gic', 'break_gic_core', 'choose_maturity', 'approve_request',
                                'approve_request_unlogged', 'request_deposit', 'request_withdrawal', 'request_trade',
                                'settle_trades', 'mature_gics', 'auto_move_unclaimed_maturities', 'post_monthly_interest',
                                'accrue_savings_interest', 'pay_quarterly_dividends', 'post_late_interest', 'apply_split',
                                'expire_requests', 'correct_savings', 'reconcile', 'reconcile_through', 'move_preview',
                                'parent_decision_preview', 'set_setting', 'set_setting_unlogged')), null,
  'no money function calls badges (Dad: they stay byte-for-byte unchanged)');
select is(tests.has('bg_gic', 'first_gic') and tests.has('bg_hold', 'drop_held'), true,
  'other kids'' badges are unaffected by one kid''s failure');

drop trigger tests_boom on public.badges;
select is(tests.nightly('2027-03-16') ->> 'status', 'ok', 'once fixed, the next night is ok');
select is(tests.has('bg_fail', 'first_gic'), true, '...and catches the badge the failed night missed');
select is((select resolved_at is not null from public.alerts where kind = 'badge_check_failed'
            and account_id = tests.acct('bg_fail')), true, '...and settles its alert');

-- "Updating…": a kid whose figures are being checked waits.
insert into public.job_runs (job, run_for_date, status, details, finished_at)
values ('reconcile', '2027-03-16', 'ok',
        jsonb_build_object('problems', jsonb_build_array(jsonb_build_object('account_id', tests.acct('bg_ended')))),
        public.app_now());
select tests.clock('2027-04-20 17:00');
select 'ran: ' || tests.run('mature_gics', '2027-04-16');
select tests.interest('bg_ended', 100, '2027-04-01 00:10');
select is(tests.nightly('2027-04-20') -> 'skipped', jsonb_build_array(tests.acct('bg_ended')),
  'a kid whose figures show "Updating…" is skipped');
select is(tests.has('bg_ended', 'first_dollar'), false, '...so her badge waits');
insert into public.job_runs (job, run_for_date, status, details, finished_at)
values ('reconcile', '2027-04-20', 'ok', jsonb_build_object('problems', '[]'::jsonb), public.app_now());
select tests.nightly('2027-04-20');
select is(tests.earned_on('bg_ended', 'first_dollar'), date '2027-04-01', '...then comes, dated when she earned it');

-- 11. Switching Badges on for everyone: her history counts (Dad's decision G) --------------------------------

insert into public.settings (key, value, effective_date) values ('feature:badges', 'everyone', date '2027-04-20');
select tests.as_parent();
select is(public.parent_check_badges(null, 'switch') -> 'awarded' -> tests.acct('bg_real')::text, '["first_gic", "gic_to_end"]'::jsonb,
  'after Dad switches Badges on for everyone, his check finds her earlier GIC, and its maturity on Apr 16');
select is(tests.earned_on('bg_real', 'first_gic'), date '2027-03-16', '...dated the day she bought it');
select is((tests.notice('bg_real', 'first_gic')).body,
  'You earned this on Mar 16. Badges just arrived!',
  '...and, with Make it yours still off for her, no accessory line');
select is((select summary from public.parent_actions where action = 'check_badges' order by id desc limit 1),
  'Checked every kid''s badges after changing a feature switch: gave First GIC, Kept it to the end to Test bg_real.', 'logged once');
select is(tests.err($$select public.parent_check_badges(null, 'whenever')$$),
  'Say why you''re checking: after a "deposit" or a "switch".', 'the reason is one of two');

-- 12. Her look --------------------------------------------------------------------------------------------------

select tests.as_kid('bg_gic');
select is(public.kid_look(public.my_account_id()),
  '{"on": true, "badges_on": true, "theme": "#5B3FD1", "animal": null, "accessory": null}'::jsonb,
  'before she picks: Big Bucks purple, no animal');
select is(public.kid_set_look('#00695c', 'moose', 'party_hat') ->> 'theme', '#00695C', 'she picks Teal, the moose and her party hat');
select is(public.kid_look(public.my_account_id()),
  '{"on": true, "badges_on": true, "theme": "#00695C", "animal": "moose", "accessory": "party_hat"}'::jsonb, 'saved');
select is(tests.err($$select public.kid_set_look('#FF0000', 'fox', null)$$),
  'Pick one of the colours on the list.', 'a colour off the list is refused');
select is(tests.err($$select public.kid_set_look('#5B3FD1', 'dragon', null)$$),
  'Pick one of the animals on the list.', 'an unknown animal is refused');
select is(tests.err($$select public.kid_set_look('#5B3FD1', 'fox', 'crown')$$),
  'Earn the Goal reached badge to wear the crown.', 'a crown she hasn''t earned is refused');
select is(tests.err($$select public.kid_set_look('#5B3FD1', 'fox', 'cape')$$),
  'Pick something to wear from the list.', 'an unknown accessory is refused');
select is(public.kid_set_look('#5B3FD1', 'fox', 'top_hat') ->> 'accessory', 'top_hat', 'her ladder''s top hat is hers to wear');
select tests.as_kid('bg_real');
select is(tests.err($$select public.kid_set_look('#5B3FD1', 'fox', null)$$),
  'Make it yours isn''t switched on for you yet.', 'with Make it yours off, she can''t change her look');
select is(public.kid_look(public.my_account_id()) ->> 'on', 'false', '...and her look reads as off');

-- A crown worn, then gone (as after the pre-launch reset clears badges): it's never shown.
update public.accounts set avatar_accessory = 'crown' where id = tests.acct('bg_hold');
select tests.as_kid('bg_hold');
select is(public.kid_look(public.my_account_id()) ->> 'accessory', null, 'an accessory without its badge is never shown');

-- 13. Her badges, as she reads them ------------------------------------------------------------------------------

select tests.as_kid('bg_gic');
select is(jsonb_array_length(public.kid_badges(public.my_account_id()) -> 'earned'), 3, 'she sees her 3 badges');
select is(public.kid_badges(public.my_account_id()) -> 'earned' -> 0 ->> 'badge', 'first_gic', '...oldest first');
select is(jsonb_array_length(public.kid_badges(public.my_account_id()) -> 'kinds'), 6, '...and all six kinds, to show the rest softly');

-- 14. RLS, grants, append-only -------------------------------------------------------------------------------------

select tests.as_kid('bg_sis');
set local role authenticated;
select is((select count(*) from public.badges where account_id = tests.acct('bg_gic')), 0::bigint,
  'another kid can''t see her badges');
select is((select count(*) from public.accounts where id = tests.acct('bg_gic')), 0::bigint, '...or her look');
select is(tests.err(format('select public.kid_badges(%L)', tests.acct('bg_gic'))),
  'You can only see your own badges.', '...even by asking');
select is(tests.err(format('select public.kid_look(%L)', tests.acct('bg_gic'))),
  'You can only see your own look.', '...or her look');
select is(tests.err($$select public.check_badges_through('2027-04-20')$$),
  'permission denied for function check_badges_through', 'kids can''t run the nightly check');
select is(tests.err(format('select public.award_badges(%L, %L)', tests.acct('bg_sis'), '2027-04-20')),
  'permission denied for function award_badges', '...or award badges');
select is(tests.err($$select public.parent_check_badges(null, 'switch')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or Dad''s check');
select is(tests.err(format($$insert into public.badges (account_id, badge, award_key) values (%L, 'crown', 'x')$$,
                           tests.acct('bg_sis'))),
  'permission denied for table badges', '...or write a badge');
reset role;
select tests.as_parent('aal1');
select is(tests.err($$select public.parent_check_badges(null, 'switch')$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'Dad''s check needs the second step');
select tests.as_parent();
select is(jsonb_array_length(public.kid_badges(tests.acct('bg_gic')) -> 'earned'), 3, 'Dad can see her badges');
select is(public.parent_view(tests.acct('bg_gic'), 'kid_badges') = public.kid_badges(tests.acct('bg_gic')), true,
  '"View as" reads her badges exactly as she does');
select is(public.parent_view(tests.acct('bg_gic'), 'kid_look') = public.kid_look(tests.acct('bg_gic')), true,
  '...and her look');
select is((public.parent_looks() -> tests.acct('bg_gic')::text) ->> 'animal', 'fox', 'Dad''s screens read every look at once');
select tests.nobody();
select is(tests.err($$update public.badges set earned_on = '2026-01-01'$$),
  'badges is append-only: update is not allowed. Add a new row instead.', 'badges can''t be changed, even by the owner');
select is(tests.err($$delete from public.badges$$),
  'badges is append-only: delete is not allowed. Add a new row instead.', '...or deleted');
select is((select count(*) from public.glossary where term = 'GIC ladder'), 1::bigint, 'the GIC ladder ? explains itself');
select is((select array_agg(t) from unnest(private.prelaunch_tables()) t where t = 'public.badges'), array['public.badges'],
  'the pre-launch reset still clears badges');

select * from finish();
rollback;
