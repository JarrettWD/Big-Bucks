-- The health check in plain words (Dad, 2026-10-10): no false alarm the morning after
-- the first account opens; a missed night said plainly ("Nightly jobs haven't
-- finished since …"); alerts pointing at the Dashboard; the same words on Dad's
-- Dashboard; and no names in the summary. Feb 2027 (markets close 3:00 pm Alberta).
begin;
select plan(16);

create schema tests;
grant usage on schema tests to authenticated, service_role;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text) returns void language sql as $$
  select set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create function tests.night(p_day date) returns void language plpgsql as $$
begin
  insert into public.fund_prices (fund_id, price_date, close) select f.id, p_day, 100 from public.funds f
    where public.is_trading_day(f.market, p_day)
      and not exists (select 1 from public.fund_prices p where p.fund_id = f.id and p.price_date = p_day);
  perform public.run_daily(p_day);
  perform public.reconcile_through(p_day);
end;
$$;
create function tests.health() returns jsonb language sql as $$ select public.health_check() $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- A fresh database (as CI has it) has no accounts; the demo has some. Either way, the
-- account below opens on Feb 1, 2027, after anything already there.
select tests.clock('2027-02-01 09:00');
select is((select count(*)::int from public.accounts where created_at > public.app_now()), 0, 'nothing opens after Feb 1, 2027');

-- Only meaningful when this is the first account: the demo's accounts opened earlier.
create temp table fresh as select not exists (select 1 from public.accounts) as yes;
insert into public.accounts (name, is_test) values ('Test Kid H', false);

select is(case when (select yes from fresh) then (tests.health() ->> 'summary') else 'All well.' end, 'All well.',
  'the day an account opens, nothing is behind');

-- The morning after, before any evening run.
select tests.clock('2027-02-02 08:00');
select is(case when (select yes from fresh) then tests.health() ->> 'summary'
               else 'Nightly jobs haven''t run yet (expire, splits, settle, gic_maturity, auto_move, dividends, monthly, rate_notices, reconcile). They catch up by themselves at the next evening run; if they don''t, see RUNBOOK, "How the nightly run works".' end,
  'Nightly jobs haven''t run yet (expire, splits, settle, gic_maturity, auto_move, dividends, monthly, rate_notices, reconcile). They catch up by themselves at the next evening run; if they don''t, see RUNBOOK, "How the nightly run works".',
  'no evening run at all: said plainly, and savings interest isn''t due yet');

-- The first evening runs. The next morning is clear: no false alarm for interest.
select tests.clock('2027-02-01 17:00');
select tests.night(date '2027-02-01');
select tests.clock('2027-02-02 08:00');
select is((tests.health() -> 'problems') @> '[{"kind": "behind", "job": "interest"}]'::jsonb, false,
  'the morning after the first evening run, savings interest isn''t counted as behind');
select is(case when (select yes from fresh) then (tests.health() ->> 'ok')::boolean else true end, true,
  '...and the check is clear');

-- A missed night: Feb 2's evening run never happens.
select tests.clock('2027-02-03 08:00');
select ok((tests.health() ->> 'summary') like 'Nightly jobs haven''t finished since Feb 1%',
  'a missed night: "Nightly jobs haven''t finished since Feb 1"');
select ok((tests.health() ->> 'summary') like '%(expire, splits, settle, gic_maturity, auto_move, dividends, monthly, rate_notices, interest, reconcile).%',
  '...naming every job behind, savings interest included now');
select ok((tests.health() ->> 'summary') like '%They catch up by themselves at the next evening run%', '...and what happens next');
select is((tests.health() ->> 'ok')::boolean, false, '...and the check fails, so GitHub emails Dad');

-- An open alert too: the summary points at the Dashboard first.
insert into public.alerts (kind, message) values ('test', 'Test alert for Test Kid H');
select ok((tests.health() ->> 'summary') like '1 open alert: open the parent Dashboard to see it. Nightly jobs haven''t finished since Feb 1%',
  'an open alert comes first, pointing at the Dashboard');
select ok((tests.health() ->> 'summary') not like '%Test Kid H%', 'the summary never holds an alert''s words or a name');

-- The next evening catches up, and the morning after is clear again.
select tests.clock('2027-02-03 17:00');
select tests.night(date '2027-02-03');
update public.alerts set resolved_at = public.app_now() where kind = 'test';
select tests.clock('2027-02-04 08:00');
select is(tests.health() ->> 'summary', 'All well.', 'caught up: "All well."');

-- Dad's Dashboard shows the same words about the jobs.
select tests.clock('2027-02-06 08:00');
select tests.as_user('00000000-0000-0000-0000-00000000000f', 'aal2');
set local role authenticated;
select is(public.parent_nightly_status() ->> 'behind', 'true', 'Dad''s Dashboard knows the jobs are behind...');
-- Everything finished through Feb 2 (Feb 3's interest is worked out the evening after).
select ok(public.parent_nightly_status() ->> 'text' like 'Nightly jobs haven''t finished since Feb 2 (%', '...in the same words');
reset role;
select tests.as_user('00000000-0000-0000-0000-00000000000f', 'aal1');
set local role authenticated;
select throws_ok($$select public.parent_nightly_status()$$, '42501', null, 'without the authenticator code, it''s refused');
reset role;
select is(
  array(select r from unnest(array['anon', 'service_role']) r
         where has_function_privilege(r, 'public.parent_nightly_status()', 'execute')
            or has_function_privilege(r, 'public.jobs_behind()', 'execute')),
  '{}'::text[], 'nobody else can call them');

select * from finish();
rollback;
