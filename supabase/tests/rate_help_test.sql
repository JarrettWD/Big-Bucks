-- The live figures in the "Interest rate" and "Inflation" ?s (Dad, 2026-10-26; migration
-- 20261103000000_rate_help.sql). Known answers worked by hand: a year of savings interest
-- month by month, each month rounded up to the cent like the real interest; the plain meaning
-- of a percent for $100; inflation's "would need to grow to", rounded up.
begin;
select plan(24);

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
create function tests.help(p_acct uuid) returns jsonb language sql as $$
  select public.kid_rate_help(p_acct);
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

create temp table k (name text primary key, acct uuid, usr uuid);
insert into k values ('a', null, '00000000-0000-0000-0000-0000000000a1'), ('z', null, '00000000-0000-0000-0000-0000000000a2');
update k set acct = tests.new_kid(usr, 'rh_' || name);
grant select on k to authenticated;

-- She has $95.00 in savings (Dad's example). The other kid has nothing.
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at)
values ((select acct from k where name = 'a'), 'savings', 'deposit', 9500, public.edmonton_at('2026-10-10 10:00'));

-- 1. The year of interest, by hand -------------------------------------------------------------------

-- $95.00 at 1.0%: each month 9500 × 1%/12 = 7.92¢, rounded up to 8¢, and still under 8¢ all year: 12 × 8 = 96¢.
select is(public.savings_year_cents(9500, 1.0), 96::bigint, '$95.00 at 1.0% earns about 96¢ in a year');
-- $183.67 at 2.0%: 31¢ for 8 months, then 32¢ for 4 (learning_test shows each month): $3.76.
select is(public.savings_year_cents(18367, 2.0), 376::bigint, '$183.67 at 2.0% earns about $3.76 in a year');
select is(public.savings_year_cents(0, 2.0), 0::bigint, 'nothing saved earns nothing');
select is(public.savings_year_cents(9500, 0), 0::bigint, 'at 0% nothing is earned');

-- 2. Her ?s at 1.0% (the Oct 26 savings cut) ----------------------------------------------------------

insert into public.rates (vehicle, gic_term, rate, effective_date) values ('savings', null, 1.0, '2026-10-26');
select tests.clock('2026-10-26 12:00');
select tests.as_user((select usr from k where name = 'a'));

select is((tests.help((select acct from k where name = 'a')) ->> 'savings_rate')::numeric, 1.0::numeric,
  'the rate is the one Home shows: 1.0% from Oct 26');
select is(tests.help((select acct from k where name = 'a')) ->> 'per_100_cents', '100',
  'the plain meaning: at 1.0% a year, every $100 earns $1');
select is(tests.help((select acct from k where name = 'a')) ->> 'per_100_exact', 'true', '...exactly $1');
select is(tests.help((select acct from k where name = 'a')) ->> 'balance_cents', '9500', 'her savings: $95.00');
select is(tests.help((select acct from k where name = 'a')) ->> 'year_cents', '96',
  'her own figure: about 96¢ in a year, worked out like the real interest');
select is(tests.help((select acct from k where name = 'a')) ->> 'inflation_rate', '2.0', 'inflation is the setting: 2.0%');
select is(tests.help((select acct from k where name = 'a')) ->> 'infl_100_cents', '10200',
  'at 2.0% a year, something that costs $100 now costs $102 next year');
select is(tests.help((select acct from k where name = 'a')) ->> 'infl_exact', 'true', '...exactly $102');
-- 9500 × 1.02 = 9690 exactly.
select is(tests.help((select acct from k where name = 'a')) ->> 'need_cents', '9690',
  'her $95.00 would need to grow to $96.90 to buy the same things');

-- 3. A rate that isn't whole cents per $100, and a special ------------------------------------------

insert into public.rates (vehicle, gic_term, rate, effective_date) values ('savings', null, 2.125, '2026-11-01');
select tests.clock('2026-11-01 12:00');
-- $100 × 2.125% = $2.125, so "about $2.13" (rounded up).
select is(tests.help((select acct from k where name = 'a')) ->> 'per_100_cents', '213', 'at 2.125%, every $100 earns about $2.13');
select is(tests.help((select acct from k where name = 'a')) ->> 'per_100_exact', 'false', '...not exactly, so the screen says "about"');

insert into public.rates (vehicle, gic_term, rate, effective_date, end_date, is_special)
values ('savings', null, 5.0, '2026-11-02', '2026-11-08', true);
select tests.clock('2026-11-03 12:00');
select is((tests.help((select acct from k where name = 'a')) ->> 'savings_rate')::numeric, 5.0::numeric,
  'during a savings special, the special rate (what Home shows)');

-- 4. Nothing saved, and who can see -------------------------------------------------------------------

select tests.as_user((select usr from k where name = 'z'));
select is(tests.help((select acct from k where name = 'z')) -> 'year_cents', 'null'::jsonb, 'nothing saved: no "your" line');
select is(tests.help((select acct from k where name = 'z')) -> 'need_cents', 'null'::jsonb, '...for inflation either');
select throws_ok(format('select public.kid_rate_help(%L)', (select acct from k where name = 'a')), '42501', null,
  'one kid can''t read the other''s figures');

select tests.as_user('00000000-0000-0000-0000-00000000000f', 'aal2');
select is(public.parent_view((select acct from k where name = 'a'), 'kid_rate_help') ->> 'year_cents',
  public.kid_rate_help((select acct from k where name = 'a')) ->> 'year_cents', 'View as reads the same figures');

select ok(not has_function_privilege('anon', 'public.kid_rate_help(uuid)', 'execute'), 'anon can''t run it');
select ok(not has_function_privilege('authenticated', 'public.savings_year_cents(bigint, numeric)', 'execute'),
  'the helper isn''t callable from the app');

-- 5. The ?s lose their fixed examples (the live lines replace them) ------------------------------------

select is((select kid_text from public.glossary where term = 'Interest rate'),
  'How much interest you earn in a year, shown as a percent.', 'the Interest rate ? has no fixed 2% example');
select is((select kid_text from public.glossary where term = 'Inflation'),
  'Prices slowly going up over time. Your money needs to grow at least as fast as prices just to buy the same stuff.',
  'the Inflation ? has no fixed 2% example');

select * from finish();
rollback;
