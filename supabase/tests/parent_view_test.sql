-- Stage 8: "View as <kid>". parent_view answers each read exactly as her own app's
-- read does, for her account only; only a parent with the authenticator code may
-- call it; every kid action refuses a parent; and viewing never marks a notice read.
begin;
select plan(19);

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
  -- Stage 8 B4: she has signed the agreement, so she can ask for deposits.
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
    values (v_acct, 1, 'kid', v_user, '{}'::jsonb);
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
-- Run as an app user (the "authenticated" role, so row-level security applies).
create function tests.as_role(p_sql text) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  execute 'set local role authenticated';
  execute p_sql into r;
  execute 'reset role';
  return r;
end;
$$;
-- Everything viewing could possibly change.
create function tests.footprint() returns text language sql as $$
  select concat_ws('/', (select count(*) from public.requests), (select count(*) from public.transactions),
    (select count(*) from public.notifications), (select count(*) from public.notifications where read_at is not null),
    (select count(*) from public.questions), (select count(*) from public.gic_holdings),
    (select count(*) from public.parent_actions));
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');

-- Prices on every weekday in September and Oct 1.
insert into public.fund_prices (fund_id, price_date, close)
select f.fund_id, d::date, f.flat
  from (values ('dow', 400.0), ('nasdaq100', 500.0), ('tsx', 40.0)) f(fund_id, flat)
 cross join generate_series(date '2026-09-01', date '2026-10-01', interval '1 day') d
 where extract(isodow from d) < 6;

-- Kid A: money in, a GIC, a Dow buy (settled), a waiting withdrawal, a question and notices.
-- Kid B (a test account) has her own, so a wrong account would show.
select tests.clock('2026-09-01 08:00');
select tests.new_kid('kid_a');
select tests.new_kid('kid_b', true);
select tests.as_kid('kid_a');
select public.request_deposit(60000);
select tests.as_kid('kid_b');
select public.request_deposit(30000);
select tests.as_parent();
select public.approve_request(id) from public.requests where status = 'pending' order by id;
select tests.clock('2026-09-02 09:00');
select tests.as_kid('kid_a');
select public.buy_gic(10000, 3);
select public.request_trade('dow', 'buy', 20000, false);
select tests.as_kid('kid_b');
select public.buy_gic(5000, 1);
select tests.clock('2026-09-02 16:30');
select tests.nobody();
select public.settle_trades('2026-09-02');
select tests.clock('2026-10-01 10:00');
select tests.as_kid('kid_a');
select public.request_withdrawal(1500);
select public.ask_question('Is my GIC right?', null);
select tests.as_parent();
select public.add_rate('savings', null, 1.5, date '2026-10-08', 'Rates are down');
select tests.clock('2026-10-01 12:00');

-- 1. Each read: Dad's view is exactly what her own app gets -----------------------------------------

create temporary table reads (name text, args jsonb, kid_sql text);
insert into reads values
  ('account', '{}', $$select jsonb_build_object('account_id', a.id, 'name', a.name, 'is_test', a.is_test) from public.accounts a$$),
  ('app_today', '{}', $$select to_jsonb(public.app_today())$$),
  ('balances', '{}', $$select to_jsonb(b) from public.account_balances b$$),
  ('home_gics', '{}', $$select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]') from public.gic_positions g
                        where g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null)$$),
  ('unread_notices', '{}', $$select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                             'related_gic_id', n.related_gic_id) order by n.created_at desc, n.id desc), '[]')
                             from public.notifications n where n.read_at is null$$),
  ('unread_count', '{}', $$select to_jsonb(count(*)) from public.notifications n where n.read_at is null$$),
  ('figures_updating', '{}', $$select to_jsonb(public.figures_updating(public.my_account_id()))$$),
  ('feature_enabled', '{"p_feature": "wishlist"}', $$select to_jsonb(public.feature_enabled('wishlist', public.my_account_id()))$$),
  ('current_rates', '{}', $$select jsonb_agg(to_jsonb(t)) from public.current_rates() t$$),
  ('fund_overview', '{}', $$select jsonb_agg(to_jsonb(t)) from public.fund_overview(public.my_account_id()) t$$),
  ('my_activity', '{"p_limit": 5}', $$select jsonb_agg(to_jsonb(t)) from public.my_activity(public.my_account_id(), 5) t$$),
  ('my_notices', '{"p_limit": 30}', $$select jsonb_agg(to_jsonb(t)) from public.my_notices(public.my_account_id(), 30) t$$),
  ('my_questions', '{}', $$select jsonb_agg(to_jsonb(t)) from public.my_questions(public.my_account_id()) t$$),
  ('graph_ranges', '{}', $$select public.graph_ranges(public.my_account_id())$$),
  ('daily_balances', '{"p_from": "2026-09-01", "p_to": "2026-10-01"}',
     $$select jsonb_agg(to_jsonb(t)) from public.daily_balances(public.my_account_id(), '2026-09-01', '2026-10-01') t$$),
  ('growth_by_option', '{"p_from": "2026-09-01", "p_to": "2026-10-01"}',
     $$select jsonb_agg(to_jsonb(t)) from public.growth_by_option(public.my_account_id(), '2026-09-01', '2026-10-01') t$$),
  ('money_in_vs_earned', '{}', $$select jsonb_agg(to_jsonb(t)) from public.money_in_vs_earned(public.my_account_id()) t$$),
  ('my_mix', '{}', $$select jsonb_agg(to_jsonb(t)) from public.my_mix(public.my_account_id()) t$$),
  ('gic_ladder', '{}', $$select jsonb_agg(to_jsonb(t)) from public.gic_ladder(public.my_account_id()) t$$),
  ('fund_chart', '{"p_fund_id": "dow", "p_from": "2026-09-01"}',
     $$select public.fund_chart(public.my_account_id(), 'dow', '2026-09-01')$$);

-- Her answers (as kid A, with her own permissions), then Dad's through parent_view.
create temporary table answers (name text, kid jsonb, dad jsonb);
grant all on reads, answers to authenticated;
create function tests.collect() returns void language plpgsql as $$
declare
  v reads;
  k jsonb;
  d jsonb;
begin
  for v in select * from reads loop
    perform tests.as_kid('kid_a');
    k := tests.as_role(v.kid_sql);
    perform tests.as_parent();
    d := tests.as_role(format('select public.parent_view(%L, %L, %L)', tests.acct('kid_a'), v.name, v.args));
    insert into answers values (v.name, k, d);
  end loop;
end;
$$;
create temporary table before_viewing as select tests.footprint() as f;
select tests.collect();

select is(array(select name from answers where kid is distinct from dad order by name), '{}'::text[],
  'every read: Dad''s view is exactly what her own app gets');
select is((select count(*)::int from answers where dad is not null and dad <> '[]'::jsonb), 20,
  'and each one really has something in it (20 reads, none empty)');
select is((select dad ->> 'name' from answers where name = 'account'), 'Kid A', 'her name, for the banner and "Hi, …!"');
select is((select jsonb_array_length(dad) from answers where name = 'unread_notices'),
  (select count(*)::int from public.notifications where account_id = tests.acct('kid_a') and read_at is null),
  'her unread notices only, not her sister''s (Dad could see both)');
select is((select dad -> 'savings_cents' from answers where name = 'balances'),
  (select to_jsonb(savings_cents) from public.account_balances where account_id = tests.acct('kid_a')),
  'her balances, not her sister''s');

-- 2. Viewing changes nothing, and never marks a notice read --------------------------------------------

select is(tests.footprint(), (select f from before_viewing),
  'after every read: no request, ledger line, notice, question, GIC or log row changed, and nothing marked read');

-- 3. Only a parent with the authenticator code may view ---------------------------------------------

select tests.as_kid('kid_a');
select is(tests.err(format('select public.parent_view(%L, ''balances'')', tests.acct('kid_a'))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t use it, even for herself');
select tests.as_kid('kid_b');
select is(tests.err(format('select public.parent_view(%L, ''balances'')', tests.acct('kid_a'))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...or for her sister');
select tests.as_parent('aal1');
select is(tests.err(format('select public.parent_view(%L, ''balances'')', tests.acct('kid_a'))),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a parent without the code can''t');
select ok(not has_function_privilege('anon', 'public.parent_view(uuid, text, jsonb)', 'EXECUTE')
          and not has_function_privilege('service_role', 'public.parent_view(uuid, text, jsonb)', 'EXECUTE'),
  'signed-out visitors and the server role can''t call it');
select tests.as_parent();
select is(tests.err(format('select public.parent_view(%L, ''trade_options'')', tests.acct('kid_a'))),
  'There''s no "trade_options" to view.', 'only the allowed reads (Buy / Sell isn''t one)');
select is(tests.err('select public.parent_view(gen_random_uuid(), ''balances'')'),
  'There''s no account to view.', 'an account that doesn''t exist');
select ok(not exists (select 1 from pg_proc p where p.proname = 'parent_view'
                        and (p.prosrc ~* '\m(insert|update|delete|truncate)\M' or p.provolatile = 'v')),
  'parent_view only reads (stable, and no insert, update or delete in it)');

-- 4. Every kid action refuses a parent, even with the code -----------------------------------------

select tests.as_parent();
select is(
  array(select x from unnest(array[
    tests.err('select public.request_deposit(1000)'),
    tests.err('select public.request_withdrawal(1000)'),
    tests.err('select public.buy_gic(1000, 1)'),
    tests.err(format('select public.break_gic(%s)', (select id from public.gic_holdings where account_id = tests.acct('kid_a')))),
    tests.err(format('select public.choose_maturity(%s, ''to_savings'')', (select id from public.gic_holdings where account_id = tests.acct('kid_a')))),
    tests.err('select public.request_trade(''dow'', ''buy'', 1000, false)'),
    tests.err('select public.ask_question(''From Dad'')')]) x where x is distinct from 'Only a kid''s account can do this.'),
  '{}'::text[],
  'deposit, withdrawal, GIC buy, GIC break, maturity choice, trade and question: all refused for a parent');
select is(tests.err(format('select public.mark_notices_read(array(select id from public.notifications where account_id = %L))',
            tests.acct('kid_a'))),
  'Only a kid can mark her notices as read.', 'marking her notices read: refused for a parent');
select is(tests.err('select public.move_preview(''deposit'', 1000)'),
  'Only a kid''s account can do this.', 'even Buy / Sell''s preview refuses a parent');
select is(tests.footprint(), (select f from before_viewing), 'and none of them changed anything');

-- 5. Her own app is unchanged: a kid can't read a sister through her own functions ---------------------

select tests.as_kid('kid_a');
select is(tests.err(format('select public.my_activity(%L)', tests.acct('kid_b'))),
  'You can only see your own account.', 'a kid still can''t read her sister''s history');
select ok((select count(*) from answers) = 20, '(all 20 allowed reads were compared)');

select * from finish();
rollback;
