-- The inflation switch made obvious (block 1, item 3; Dad 2026-11-14 and 2026-11-27; migration
-- 20261128020000_inflation_total.sql). Known answers worked by hand:
--   the Total card: $95.18 at 2.0% inflation buys next year what 9518 / 1.02 = 9331.37 → $93.31
--   buys today (rounded to the nearest cent, like the savings line);
--   the Inflation ?: $75.11 at 1.0% savings, 2.0% inflation (Dad's Nov 8 example): it needs
--   7511 × 1.02 = 7661.22 → $76.62 (rounded up, as before); a year at 1.0% is 12 months of
--   7511 × 1%/12 = 6.26¢ → 7¢ (still under 7¢ a month all year, the balance staying under $84.00):
--   84¢, so $75.95, which is 67¢ behind prices.
begin;
select plan(16);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create function tests.new_kid(p_user uuid, p_username text) returns uuid language plpgsql as $$
declare
  v_acct uuid;
begin
  insert into auth.users (id, email) values (p_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Test ' || p_username, true) returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (p_user, 'investor', v_acct, p_username, p_username);
  return v_acct;
end;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

create temp table k (name text primary key, acct uuid, usr uuid);
insert into k values ('t', null, '00000000-0000-0000-0000-0000000000b1'),
                     ('g', null, '00000000-0000-0000-0000-0000000000b2'),
                     ('z', null, '00000000-0000-0000-0000-0000000000b3');
update k set acct = tests.new_kid(usr, 'it_' || name);
grant select on k to authenticated;

insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at) values
  ((select acct from k where name = 't'), 'savings', 'deposit', 9518, public.edmonton_at('2026-11-10 10:00')),
  ((select acct from k where name = 'g'), 'savings', 'deposit', 7511, public.edmonton_at('2026-11-10 10:00'));
insert into public.rates (vehicle, gic_term, rate, effective_date) values ('savings', null, 1.0, '2026-11-20');
insert into public.settings (key, value, effective_date) values ('feature:inflation', 'test', '2026-11-01');
select tests.clock('2026-11-28 12:00');

-- 1. The Total card ------------------------------------------------------------------------------------

select tests.as_user((select usr from k where name = 't'));
select is(public.kid_inflation((select acct from k where name = 't')) ->> 'inflation_rate', '2.0',
  'inflation is the setting in force: 2.0%');
select is(public.kid_inflation((select acct from k where name = 't')) -> 'total' ->> 'now_cents', '9518',
  'the Total card: her total worth, $95.18');
select is((public.kid_inflation((select acct from k where name = 't')) -> 'total' ->> 'now_cents')::bigint,
  (select b.total_worth_cents from public.account_balances b where b.account_id = (select acct from k where name = 't')),
  '...the same figure as Total worth on Home');
select is(public.kid_inflation((select acct from k where name = 't')) -> 'total' ->> 'buys_like_cents', '9331',
  '...which next year, if it didn''t grow, buys about what $93.31 buys today (9518 / 1.02, nearest cent)');
-- 9518 × 1%/12 = 7.93¢ → 8¢ a month for 11 months (to $96.06), then 9606 × 1%/12 = 8.005¢ → 9¢: 97¢.
select is(public.kid_inflation((select acct from k where name = 't')) -> 'savings' ->> 'in_a_year_cents', '9615',
  'the savings line is unchanged: $95.18 at 1.0% grows to $96.15');

-- Nothing at all: a total of $0.00 (the screen shows the general note instead).
select tests.as_user((select usr from k where name = 'z'));
select is(public.kid_inflation((select acct from k where name = 'z')) -> 'total',
  '{"now_cents": 0, "buys_like_cents": 0}'::jsonb, 'nothing saved: a total of zero');

-- 2. The Inflation ?: Dad's Nov 8 example ---------------------------------------------------------------

select tests.as_user((select usr from k where name = 'g'));
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'need_cents', '7662',
  '$75.11 would need to grow to $76.62 to keep up with 2.0% (as before)');
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'year_total_cents', '7595',
  'at 1.0% her savings grow to about $75.95 in a year');
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'gap_cents', '67',
  '...about 67¢ behind prices');
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'year_total_cents',
  public.kid_inflation((select acct from k where name = 'g')) -> 'savings' ->> 'in_a_year_cents',
  'the ? and the savings line agree to the cent');

-- A savings rate above inflation: ahead of prices, so the gap is below zero.
-- 7511 at 3.0%: 19¢ a month while under $76.00 (7600 × 0.25% = 19¢), then 20¢: 7511 → 7530 → 7549
-- → 7568 → 7587 → 7606 → 7626 → 7646 → 7666 → 7686 → 7706 → 7726 → 7746, so 7662 − 7746 = −84.
insert into public.rates (vehicle, gic_term, rate, effective_date) values ('savings', null, 3.0, '2026-11-29');
select tests.clock('2026-11-29 12:00');
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'year_total_cents', '7746',
  'at 3.0% her savings grow to about $77.46');
select is(public.kid_rate_help((select acct from k where name = 'g')) ->> 'gap_cents', '-84',
  '...84¢ ahead of prices: the gap is below zero');

-- 3. Nothing saved, the switch off, and who can see -----------------------------------------------------

select tests.as_user((select usr from k where name = 'z'));
select is(public.kid_rate_help((select acct from k where name = 'z')) -> 'gap_cents', 'null'::jsonb,
  'nothing saved: no gap line');
insert into public.settings (key, value, effective_date) values ('feature:inflation', 'off', '2026-11-29');
select is(public.kid_inflation((select acct from k where name = 'z')), '{"on": false}'::jsonb,
  'the switch off: nothing at all');
select throws_ok(format('select public.kid_inflation(%L)', (select acct from k where name = 't')), '42501', null,
  'one kid can''t read the other''s figures');

select tests.as_user('00000000-0000-0000-0000-00000000000f', 'aal2');
select is(public.parent_view((select acct from k where name = 'g'), 'kid_rate_help') ->> 'gap_cents',
  public.kid_rate_help((select acct from k where name = 'g')) ->> 'gap_cents', 'View as reads the same figures');

select * from finish();
rollback;
