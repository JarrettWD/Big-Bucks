-- Every table, view and sequence in public has exactly the grants we chose, per role (Dad,
-- 2026-10-20). From Oct 30 Supabase no longer grants new public tables to anon, authenticated and
-- service_role by itself, and a rebuild from migrations (local reset, CI, restore drill, a new
-- project) must give exactly production's grants. Any table added later without its grants fails
-- here: add its grants in the migration that creates it, and its row below.
begin;
select plan(6);

create temp table expected (obj text, grantee text, privilege text);
insert into expected values
  ('account_balances', 'authenticated', 'SELECT'),
  ('account_balances', 'backup_reader', 'SELECT'),
  ('account_balances', 'service_role', 'SELECT'),
  ('accounts', 'authenticated', 'SELECT'),
  ('accounts', 'backup_reader', 'SELECT'),
  ('accounts', 'service_role', 'SELECT'),
  ('agreement_signatures', 'authenticated', 'SELECT'),
  ('agreement_signatures', 'backup_reader', 'SELECT'),
  ('agreement_signatures', 'service_role', 'SELECT'),
  ('agreement_signatures_id_seq', 'backup_reader', 'SELECT'),
  ('agreement_versions', 'authenticated', 'SELECT'),
  ('agreement_versions', 'backup_reader', 'SELECT'),
  ('agreement_versions', 'service_role', 'SELECT'),
  ('alerts', 'authenticated', 'SELECT'),
  ('alerts', 'backup_reader', 'SELECT'),
  ('alerts', 'service_role', 'SELECT'),
  ('alerts_id_seq', 'backup_reader', 'SELECT'),
  ('badge_kinds', 'authenticated', 'SELECT'),
  ('badge_kinds', 'backup_reader', 'SELECT'),
  ('badge_kinds', 'service_role', 'SELECT'),
  ('badges', 'authenticated', 'SELECT'),
  ('badges', 'backup_reader', 'SELECT'),
  ('badges', 'service_role', 'SELECT'),
  ('badges_id_seq', 'backup_reader', 'SELECT'),
  ('cancellations', 'authenticated', 'SELECT'),
  ('cancellations', 'backup_reader', 'SELECT'),
  ('cancellations', 'service_role', 'SELECT'),
  ('cancellations_id_seq', 'backup_reader', 'SELECT'),
  ('fund_positions', 'authenticated', 'SELECT'),
  ('fund_positions', 'backup_reader', 'SELECT'),
  ('fund_positions', 'service_role', 'SELECT'),
  ('fund_price_corrections', 'authenticated', 'SELECT'),
  ('fund_price_corrections', 'backup_reader', 'SELECT'),
  ('fund_price_corrections', 'service_role', 'SELECT'),
  ('fund_price_corrections_id_seq', 'backup_reader', 'SELECT'),
  ('fund_prices', 'authenticated', 'SELECT'),
  ('fund_prices', 'backup_reader', 'SELECT'),
  ('fund_prices', 'service_role', 'SELECT'),
  ('fund_splits', 'authenticated', 'SELECT'),
  ('fund_splits', 'backup_reader', 'SELECT'),
  ('fund_splits', 'service_role', 'SELECT'),
  ('funds', 'authenticated', 'SELECT'),
  ('funds', 'backup_reader', 'SELECT'),
  ('funds', 'service_role', 'SELECT'),
  ('gic_holdings', 'authenticated', 'SELECT'),
  ('gic_holdings', 'backup_reader', 'SELECT'),
  ('gic_holdings', 'service_role', 'SELECT'),
  ('gic_holdings_id_seq', 'backup_reader', 'SELECT'),
  ('gic_positions', 'authenticated', 'SELECT'),
  ('gic_positions', 'backup_reader', 'SELECT'),
  ('gic_positions', 'service_role', 'SELECT'),
  ('glossary', 'authenticated', 'SELECT'),
  ('glossary', 'backup_reader', 'SELECT'),
  ('glossary', 'service_role', 'SELECT'),
  ('goals', 'authenticated', 'SELECT'),
  ('goals', 'backup_reader', 'SELECT'),
  ('goals', 'service_role', 'SELECT'),
  ('goals_id_seq', 'backup_reader', 'SELECT'),
  ('interest_accruals', 'authenticated', 'SELECT'),
  ('interest_accruals', 'backup_reader', 'SELECT'),
  ('interest_accruals', 'service_role', 'SELECT'),
  ('job_runs', 'authenticated', 'SELECT'),
  ('job_runs', 'backup_reader', 'SELECT'),
  ('job_runs', 'service_role', 'SELECT'),
  ('job_runs_id_seq', 'backup_reader', 'SELECT'),
  ('login_attempts', 'authenticated', 'SELECT'),
  ('login_attempts', 'backup_reader', 'SELECT'),
  ('login_attempts', 'service_role', 'SELECT'),
  ('login_attempts_id_seq', 'backup_reader', 'SELECT'),
  ('market_holidays', 'authenticated', 'SELECT'),
  ('market_holidays', 'backup_reader', 'SELECT'),
  ('market_holidays', 'service_role', 'SELECT'),
  ('notes', 'authenticated', 'SELECT'),
  ('notes', 'backup_reader', 'SELECT'),
  ('notes', 'service_role', 'SELECT'),
  ('notes_id_seq', 'backup_reader', 'SELECT'),
  ('notifications', 'authenticated', 'SELECT'),
  ('notifications', 'backup_reader', 'SELECT'),
  ('notifications', 'service_role', 'SELECT'),
  ('notifications_id_seq', 'backup_reader', 'SELECT'),
  ('outbox', 'authenticated', 'SELECT'),
  ('outbox', 'backup_reader', 'SELECT'),
  ('outbox', 'service_role', 'SELECT'),
  ('outbox_id_seq', 'backup_reader', 'SELECT'),
  ('parent_actions', 'authenticated', 'SELECT'),
  ('parent_actions', 'backup_reader', 'SELECT'),
  ('parent_actions', 'service_role', 'SELECT'),
  ('parent_actions_id_seq', 'backup_reader', 'SELECT'),
  ('prelaunch_resets', 'authenticated', 'SELECT'),
  ('prelaunch_resets', 'backup_reader', 'SELECT'),
  ('prelaunch_resets_id_seq', 'backup_reader', 'SELECT'),
  ('price_calls', 'authenticated', 'SELECT'),
  ('price_calls', 'backup_reader', 'SELECT'),
  ('price_calls', 'service_role', 'SELECT'),
  ('price_calls_id_seq', 'backup_reader', 'SELECT'),
  ('profiles', 'authenticated', 'SELECT'),
  ('profiles', 'backup_reader', 'SELECT'),
  ('profiles', 'service_role', 'SELECT'),
  ('questions', 'authenticated', 'SELECT'),
  ('questions', 'backup_reader', 'SELECT'),
  ('questions', 'service_role', 'SELECT'),
  ('questions_id_seq', 'backup_reader', 'SELECT'),
  ('rates', 'authenticated', 'SELECT'),
  ('rates', 'backup_reader', 'SELECT'),
  ('rates', 'service_role', 'SELECT'),
  ('rates_id_seq', 'backup_reader', 'SELECT'),
  ('requests', 'authenticated', 'SELECT'),
  ('requests', 'backup_reader', 'SELECT'),
  ('requests', 'service_role', 'SELECT'),
  ('requests_id_seq', 'backup_reader', 'SELECT'),
  ('sell_reflections', 'authenticated', 'SELECT'),
  ('sell_reflections', 'backup_reader', 'SELECT'),
  ('sell_reflections', 'service_role', 'SELECT'),
  ('settings', 'authenticated', 'SELECT'),
  ('settings', 'backup_reader', 'SELECT'),
  ('settings', 'service_role', 'SELECT'),
  ('settings_id_seq', 'backup_reader', 'SELECT'),
  ('transactions', 'authenticated', 'SELECT'),
  ('transactions', 'backup_reader', 'SELECT'),
  ('transactions', 'service_role', 'SELECT'),
  ('transactions_id_seq', 'backup_reader', 'SELECT'),
  ('whats_new_features', 'authenticated', 'SELECT'),
  ('whats_new_features', 'backup_reader', 'SELECT'),
  ('whats_new_features', 'service_role', 'SELECT'),
  ('whats_new_seen', 'authenticated', 'SELECT'),
  ('whats_new_seen', 'backup_reader', 'SELECT'),
  ('whats_new_seen', 'service_role', 'SELECT'),
  ('wishlist_items', 'authenticated', 'SELECT'),
  ('wishlist_items', 'backup_reader', 'SELECT'),
  ('wishlist_items', 'service_role', 'SELECT'),
  ('wishlist_parent_marks', 'authenticated', 'SELECT'),
  ('wishlist_parent_marks', 'backup_reader', 'SELECT'),
  ('wishlist_parent_marks', 'service_role', 'SELECT'),
  ('wishlist_photos', 'authenticated', 'SELECT'),
  ('wishlist_photos', 'backup_reader', 'SELECT'),
  ('wishlist_photos', 'service_role', 'SELECT');

create temp table actual as
select c.relname::text as obj, a.grantee::regrole::text as grantee, a.privilege_type::text as privilege
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 cross join lateral aclexplode(coalesce(c.relacl, acldefault(case when c.relkind = 'S' then 's' else 'r' end::"char", c.relowner))) a
 where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S') and a.grantee <> c.relowner and a.grantee <> 0;

select set_eq('select obj, grantee, privilege from actual', 'select obj, grantee, privilege from expected',
  'every table, view and sequence in public has exactly its expected grants, role by role');

select is_empty($$
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
     and c.relname not in (select obj from actual)
$$, 'no table or view in public is left without grants');

select is_empty($$
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S')
     and c.relname not in (select obj from expected)
$$, 'every table, view and sequence in public is listed here (a new one needs its row)');

select is_empty($$
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   cross join lateral aclexplode(c.relacl) a
   where n.nspname = 'public' and (a.grantee = 0 or a.grantee = 'anon'::regrole)
$$, 'anon and PUBLIC have nothing on any table, view or sequence');

select is_empty($$
  select privilege from actual where privilege <> 'SELECT'
$$, 'nobody can write to a table directly: every grant is SELECT');

-- Functions: anon may run only the health check's ping; nothing is open to PUBLIC.
select set_eq($$
  select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where n.nspname = 'public' and (a.grantee = 0 or a.grantee = 'anon'::regrole)
$$, array['ping'], 'anon can run only ping, and PUBLIC can run nothing');

select * from finish();
rollback;
