-- Explicit grants for every table, view and sequence in public (Dad, 2026-10-20).
--
-- From Oct 30, Supabase stops granting new public tables to anon, authenticated and service_role
-- by default, and the same holds wherever the schema is rebuilt from migrations (local
-- "supabase db reset", CI, the restore drill, a new project). Big Bucks never relied on those
-- defaults: 20261002040000_rls.sql switched them off on day one, and every migration since has
-- opened each table on purpose. This migration writes down every table's grants in one place, so
-- a rebuild can never depend on a platform default.
--
-- It reproduces production's grants exactly, as read from the Oct 20 backup's schema (plus
-- sell_reflections from 20261029000000_learning.sql, granted the same way there), so on
-- production it changes nothing:
--   * anon: nothing, on any table, view or sequence (the app signs in before reading anything);
--   * authenticated and service_role: SELECT on every table and view, except prelaunch_resets
--     (authenticated only, as 20261023000000_backups.sql set it). Row-level security
--     decides which rows; nobody writes directly: every change goes through a function;
--   * backup_reader (the nightly backup's read-only login): SELECT on everything;
--   * sequences: backup_reader only.
-- supabase/tests/explicit_grants_test.sql checks every object has exactly these grants, and fails
-- for any table added later without its grants.

revoke all on table public.accounts from public, anon, authenticated, service_role, backup_reader;
grant select on table public.accounts to authenticated, service_role, backup_reader;
revoke all on table public.agreement_signatures from public, anon, authenticated, service_role, backup_reader;
grant select on table public.agreement_signatures to authenticated, service_role, backup_reader;
revoke all on table public.agreement_versions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.agreement_versions to authenticated, service_role, backup_reader;
revoke all on table public.alerts from public, anon, authenticated, service_role, backup_reader;
grant select on table public.alerts to authenticated, service_role, backup_reader;
revoke all on table public.badge_kinds from public, anon, authenticated, service_role, backup_reader;
grant select on table public.badge_kinds to authenticated, service_role, backup_reader;
revoke all on table public.badges from public, anon, authenticated, service_role, backup_reader;
grant select on table public.badges to authenticated, service_role, backup_reader;
revoke all on table public.cancellations from public, anon, authenticated, service_role, backup_reader;
grant select on table public.cancellations to authenticated, service_role, backup_reader;
revoke all on table public.fund_price_corrections from public, anon, authenticated, service_role, backup_reader;
grant select on table public.fund_price_corrections to authenticated, service_role, backup_reader;
revoke all on table public.fund_prices from public, anon, authenticated, service_role, backup_reader;
grant select on table public.fund_prices to authenticated, service_role, backup_reader;
revoke all on table public.fund_splits from public, anon, authenticated, service_role, backup_reader;
grant select on table public.fund_splits to authenticated, service_role, backup_reader;
revoke all on table public.funds from public, anon, authenticated, service_role, backup_reader;
grant select on table public.funds to authenticated, service_role, backup_reader;
revoke all on table public.gic_holdings from public, anon, authenticated, service_role, backup_reader;
grant select on table public.gic_holdings to authenticated, service_role, backup_reader;
revoke all on table public.glossary from public, anon, authenticated, service_role, backup_reader;
grant select on table public.glossary to authenticated, service_role, backup_reader;
revoke all on table public.goals from public, anon, authenticated, service_role, backup_reader;
grant select on table public.goals to authenticated, service_role, backup_reader;
revoke all on table public.interest_accruals from public, anon, authenticated, service_role, backup_reader;
grant select on table public.interest_accruals to authenticated, service_role, backup_reader;
revoke all on table public.job_runs from public, anon, authenticated, service_role, backup_reader;
grant select on table public.job_runs to authenticated, service_role, backup_reader;
revoke all on table public.login_attempts from public, anon, authenticated, service_role, backup_reader;
grant select on table public.login_attempts to authenticated, service_role, backup_reader;
revoke all on table public.market_holidays from public, anon, authenticated, service_role, backup_reader;
grant select on table public.market_holidays to authenticated, service_role, backup_reader;
revoke all on table public.notes from public, anon, authenticated, service_role, backup_reader;
grant select on table public.notes to authenticated, service_role, backup_reader;
revoke all on table public.notifications from public, anon, authenticated, service_role, backup_reader;
grant select on table public.notifications to authenticated, service_role, backup_reader;
revoke all on table public.outbox from public, anon, authenticated, service_role, backup_reader;
grant select on table public.outbox to authenticated, service_role, backup_reader;
revoke all on table public.parent_actions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.parent_actions to authenticated, service_role, backup_reader;
revoke all on table public.prelaunch_resets from public, anon, authenticated, service_role, backup_reader;
grant select on table public.prelaunch_resets to authenticated, backup_reader;
revoke all on table public.price_calls from public, anon, authenticated, service_role, backup_reader;
grant select on table public.price_calls to authenticated, service_role, backup_reader;
revoke all on table public.profiles from public, anon, authenticated, service_role, backup_reader;
grant select on table public.profiles to authenticated, service_role, backup_reader;
revoke all on table public.questions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.questions to authenticated, service_role, backup_reader;
revoke all on table public.rates from public, anon, authenticated, service_role, backup_reader;
grant select on table public.rates to authenticated, service_role, backup_reader;
revoke all on table public.requests from public, anon, authenticated, service_role, backup_reader;
grant select on table public.requests to authenticated, service_role, backup_reader;
revoke all on table public.sell_reflections from public, anon, authenticated, service_role, backup_reader;
grant select on table public.sell_reflections to authenticated, service_role, backup_reader;
revoke all on table public.settings from public, anon, authenticated, service_role, backup_reader;
grant select on table public.settings to authenticated, service_role, backup_reader;
revoke all on table public.transactions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.transactions to authenticated, service_role, backup_reader;
revoke all on table public.whats_new_features from public, anon, authenticated, service_role, backup_reader;
grant select on table public.whats_new_features to authenticated, service_role, backup_reader;
revoke all on table public.whats_new_seen from public, anon, authenticated, service_role, backup_reader;
grant select on table public.whats_new_seen to authenticated, service_role, backup_reader;
revoke all on table public.wishlist_items from public, anon, authenticated, service_role, backup_reader;
grant select on table public.wishlist_items to authenticated, service_role, backup_reader;
revoke all on table public.wishlist_parent_marks from public, anon, authenticated, service_role, backup_reader;
grant select on table public.wishlist_parent_marks to authenticated, service_role, backup_reader;
revoke all on table public.wishlist_photos from public, anon, authenticated, service_role, backup_reader;
grant select on table public.wishlist_photos to authenticated, service_role, backup_reader;
revoke all on table public.account_balances from public, anon, authenticated, service_role, backup_reader;
grant select on table public.account_balances to authenticated, service_role, backup_reader;
revoke all on table public.fund_positions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.fund_positions to authenticated, service_role, backup_reader;
revoke all on table public.gic_positions from public, anon, authenticated, service_role, backup_reader;
grant select on table public.gic_positions to authenticated, service_role, backup_reader;
revoke all on sequence public.agreement_signatures_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.agreement_signatures_id_seq to backup_reader;
revoke all on sequence public.alerts_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.alerts_id_seq to backup_reader;
revoke all on sequence public.badges_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.badges_id_seq to backup_reader;
revoke all on sequence public.cancellations_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.cancellations_id_seq to backup_reader;
revoke all on sequence public.fund_price_corrections_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.fund_price_corrections_id_seq to backup_reader;
revoke all on sequence public.gic_holdings_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.gic_holdings_id_seq to backup_reader;
revoke all on sequence public.goals_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.goals_id_seq to backup_reader;
revoke all on sequence public.job_runs_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.job_runs_id_seq to backup_reader;
revoke all on sequence public.login_attempts_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.login_attempts_id_seq to backup_reader;
revoke all on sequence public.notes_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.notes_id_seq to backup_reader;
revoke all on sequence public.notifications_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.notifications_id_seq to backup_reader;
revoke all on sequence public.outbox_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.outbox_id_seq to backup_reader;
revoke all on sequence public.parent_actions_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.parent_actions_id_seq to backup_reader;
revoke all on sequence public.prelaunch_resets_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.prelaunch_resets_id_seq to backup_reader;
revoke all on sequence public.price_calls_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.price_calls_id_seq to backup_reader;
revoke all on sequence public.questions_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.questions_id_seq to backup_reader;
revoke all on sequence public.rates_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.rates_id_seq to backup_reader;
revoke all on sequence public.requests_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.requests_id_seq to backup_reader;
revoke all on sequence public.settings_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.settings_id_seq to backup_reader;
revoke all on sequence public.transactions_id_seq from public, anon, authenticated, service_role, backup_reader;
grant select on sequence public.transactions_id_seq to backup_reader;
