-- The shape of the database: tables, money types, and the check constraints
-- that keep impossible rows out of the ledger.
begin;
select plan(44);

-- Every table
select tables_are('public', array[
  'accounts', 'alerts', 'badges', 'fund_prices', 'fund_splits', 'funds', 'gic_holdings', 'glossary', 'goals',
  'interest_accruals', 'job_runs', 'login_attempts', 'market_holidays', 'notes', 'notifications',
  'cancellations', 'parent_actions', 'profiles', 'questions', 'rates', 'requests', 'settings', 'transactions', 'wishlist_items',
  'wishlist_parent_marks', 'agreement_versions', 'agreement_signatures', 'whats_new_features', 'whats_new_seen',
  'fund_price_corrections', 'outbox', 'price_calls'
], 'public has exactly the Data model tables plus the Build decisions additions (and fund_splits, stage 2; parent_actions, cancellations and the onboarding tables, stage 8; fund_price_corrections and outbox, pre-launch audit; price_calls, stage 4)');

select hasnt_column('public', 'wishlist_items', 'parent_got_it',
  'the "Got it" marker is not a wish-list column (it lives in wishlist_parent_marks)');

-- Enums with every value the spec names
select enum_has_labels('public', 'transaction_type', array[
  'deposit', 'withdraw', 'interest', 'transfer_in', 'transfer_out', 'penalty', 'dividend', 'split_adjust', 'correction'],
  'transaction types');
select enum_has_labels('public', 'request_status', array['pending', 'approved', 'declined', 'settled', 'expired'],
  'request statuses');
select enum_has_labels('public', 'notification_type', array[
  'rate_change', 'rate_live', 'request', 'gic_maturity', 'cap_change', 'request_expired', 'badge', 'whats_new',
  'question', 'rule_change', 'correction', 'agreement'],
  'notification types (question added in stage 2, rule_change, correction and agreement in stage 8)');
select enum_has_labels('public', 'vehicle', array['savings', 'gic', 'stock'], 'vehicles');

-- Money is integer cents; units and accruals are exact decimals; no floats anywhere
select is(
  array(select table_name || '.' || column_name from information_schema.columns
         where table_schema = 'public' and column_name like '%\_cents' and data_type <> 'bigint'
         order by 1),
  '{}'::text[],
  'every *_cents column is bigint');
select ok(
  (select count(*) from information_schema.columns
    where table_schema = 'public' and column_name like '%\_cents') >= 7,
  'the money columns exist (sanity check for the test above)');
select is(
  array(select table_name || '.' || column_name from information_schema.columns
         where table_schema = 'public' and data_type in ('real', 'double precision', 'money')
         order by 1),
  '{}'::text[],
  'no floating-point or money-type columns anywhere');
select col_type_is('public', 'transactions', 'units', 'numeric(20,8)', 'transactions.units is numeric(20,8)');
select col_type_is('public', 'requests', 'held_units', 'numeric(20,8)', 'requests.held_units is numeric(20,8)');
select col_type_is('public', 'interest_accruals', 'accrued', 'numeric', 'interest_accruals.accrued is unbounded numeric');
select col_is_unique('public', 'transactions', 'posting_key', 'transactions.posting_key is unique');

-- Fixture
insert into public.accounts (id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Test Kid A');
create function pg_temp.tx(p_vehicle text, p_type text, p_cents bigint, p_extra text default '') returns text
language sql as $$
  select format(
    'insert into public.transactions (account_id, vehicle, type, amount_cents%s) values (%L, %L, %L, %s%s)',
    case when p_extra = '' then '' else ', ' || split_part(p_extra, '=', 1) end,
    'aaaaaaaa-0000-0000-0000-000000000001', p_vehicle, p_type, p_cents,
    case when p_extra = '' then '' else ', ' || split_part(p_extra, '=', 2) end);
$$;

-- Timestamps follow the app clock (and so the time machine)
insert into public.settings (key, value, effective_date) values ('clock_override', '2027-03-15 10:00', '2026-10-02');
insert into public.accounts (id, name) values ('cccccccc-0000-0000-0000-000000000003', 'Clock Test');
select is((select created_at from public.accounts where id = 'cccccccc-0000-0000-0000-000000000003'),
  '2027-03-15 10:00-06'::timestamptz, 'created_at defaults to app_now()');
insert into public.settings (key, value, effective_date) values ('clock_override', '', '2026-10-02');

-- Ledger signs: + adds, - takes away
select lives_ok(pg_temp.tx('savings', 'deposit', 5000), 'a positive deposit is fine');
select throws_ok(pg_temp.tx('savings', 'deposit', -5000), '23514', null, 'a negative deposit is refused');
select throws_ok(pg_temp.tx('savings', 'deposit', 0), '23514', null, 'a zero deposit is refused');
select throws_ok(pg_temp.tx('savings', 'withdraw', 500), '23514', null, 'a positive withdrawal is refused');
select throws_ok(pg_temp.tx('savings', 'interest', -1), '23514', null, 'negative interest is refused');
select throws_ok(pg_temp.tx('gic', 'deposit', 5000, 'gic_id=null'), '23514', null, 'a deposit can only land in savings');
select throws_ok(pg_temp.tx('stock', 'transfer_in', 5000), '23514', null, 'a stock row must name its fund and units');
select throws_ok(pg_temp.tx('savings', 'transfer_in', 5000, 'units=1'), '23514', null, 'only stock rows carry units');
select lives_ok(pg_temp.tx('stock', 'transfer_in', 10000, 'fund_id, units, unit_price=''dow'', 0.23809524, 420'),
  'a stock buy with fund, units and price is fine');
select throws_ok(pg_temp.tx('stock', 'transfer_out', -10000, 'fund_id, units=''dow'', 0.5'), '23514', null,
  'a stock sale must take units away, not add them');
select throws_ok(pg_temp.tx('stock', 'split_adjust', 100, 'fund_id, units=''dow'', 1'), '23514', null,
  'a split adjustment moves no money');
select lives_ok(pg_temp.tx('stock', 'split_adjust', 0, 'fund_id, units=''dow'', 0.23809524'),
  'a zero-dollar split adjustment that scales units is fine');

-- Corrections and duplicates
select throws_ok(pg_temp.tx('savings', 'correction', 100), '23514', null, 'a correction must carry a note');
select lives_ok(pg_temp.tx('savings', 'correction', 100, 'note=''Test: we owed you a cent'''),
  'a correction with a plain-language note is fine');
select throws_ok(pg_temp.tx('savings', 'deposit', 100, 'reverses_id=1'), '23514', null,
  'only a correction may reverse another row');
select lives_ok(pg_temp.tx('savings', 'interest', 42, 'posting_key=''interest:2026-11:test'''), 'a posting key is accepted once');
select throws_ok(pg_temp.tx('savings', 'interest', 42, 'posting_key=''interest:2026-11:test'''), '23505', null,
  'the same posting key twice is refused: nothing posts twice');

-- GICs: terms and the maturity-date rule
select lives_ok($$insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 10000, 2.5, 1, '2027-01-31', '2027-02-28')$$,
  'Jan 31, 2027 + 1 month matures Feb 28');
select lives_ok($$insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 10000, 2.5, 1, '2028-01-31', '2028-02-29')$$,
  'Jan 31, 2028 + 1 month matures Feb 29 (leap year)');
select throws_ok($$insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 10000, 2.5, 1, '2027-01-31', '2027-03-03')$$,
  '23514', null, 'a wrong maturity date is refused');
select throws_ok($$insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 10000, 2.5, 2, '2027-01-01', '2027-03-01')$$,
  '23514', null, 'a 2-month term is refused (terms are 1, 3, 6, 9, 12, 24)');

-- Requests: the shape of each kind
select lives_ok($$insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'move', 'savings', 'stock', 'tsx', 1000)$$,
  'savings to a fund is a valid move');
select throws_ok($$insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, gic_term, amount_cents)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'move', 'stock', 'gic', 'tsx', 12, 1000)$$,
  '23514', null, 'fund to GIC in one step is refused: every move goes through savings');
select throws_ok($$insert into public.requests (account_id, type, from_vehicle, to_vehicle, amount_cents)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'move', null, 'savings', 1000)$$,
  '23514', null, 'a move must say where the money comes from');
select throws_ok($$insert into public.requests (account_id, type, to_vehicle, gic_term, amount_cents)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'deposit', 'gic', 12, 1000)$$,
  '23514', null, 'a deposit can only go to savings');
select throws_ok($$insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'move', 'stock', 'savings', 'dow', 1000, true)$$,
  '23514', null, '"sell all" cannot also name an amount');

-- Rates
select throws_ok($$insert into public.rates (vehicle, gic_term, rate, effective_date, is_special)
  values ('gic', 12, 6.0, '2027-01-01', true)$$,
  '23514', null, 'a special needs an end date');
select throws_ok($$insert into public.rates (vehicle, rate, effective_date) values ('gic', 6.0, '2027-01-01')$$,
  '23514', null, 'a GIC rate must name its term');
select throws_ok($$insert into public.rates (vehicle, rate, effective_date) values ('stock', 6.0, '2027-01-01')$$,
  '23514', null, 'stock funds have no rate');

-- Wish lists
select throws_ok($$insert into public.wishlist_items (account_id, name, stars)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'Kite', 6)$$, '23514', null, 'stars go from 1 to 5');

select * from finish();
rollback;
