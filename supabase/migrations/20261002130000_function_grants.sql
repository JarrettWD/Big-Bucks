-- Stage 2: who may run which function, all in one place.
--
-- Postgres lets every role (PUBLIC) run a new function unless told otherwise.
-- Stage 1's per-schema default can't take that away, and changing the global
-- default would also strip functions that extensions install later. So: take
-- every grant off every function in public, then grant exactly what's intended
-- below. Every function not listed here is internal: only the SECURITY DEFINER
-- engine functions (owned by the database owner) call it.
--
-- Later stages: add each new function's grant to a list like this one.

revoke all on all functions in schema public from public, anon, authenticated, service_role;

-- The clock and the stage 1 helpers (used by RLS policies and the app).
grant execute on function public.app_now() to authenticated, service_role;
grant execute on function public.app_today() to authenticated, service_role;
grant execute on function public.my_account_id() to authenticated, service_role;
grant execute on function public.is_parent() to authenticated, service_role;
grant execute on function public.feature_enabled(text, uuid) to authenticated, service_role;

-- Kid actions. Each checks that the caller is a kid acting on her own account.
grant execute on function public.request_deposit(bigint) to authenticated;
grant execute on function public.request_withdrawal(bigint) to authenticated;
grant execute on function public.buy_gic(bigint, integer) to authenticated;
grant execute on function public.break_gic(bigint) to authenticated;
grant execute on function public.choose_maturity(bigint, public.maturity_choice, integer) to authenticated;
grant execute on function public.request_trade(text, text, bigint, boolean) to authenticated;
grant execute on function public.ask_question(text, bigint) to authenticated;

-- Parent actions. Each requires a parent signed in with MFA (aal2).
grant execute on function public.approve_request(bigint, text) to authenticated;
grant execute on function public.decline_request(bigint, text) to authenticated;
grant execute on function public.answer_question(bigint, text) to authenticated;
grant execute on function public.add_rate(public.vehicle, integer, numeric, date, text, date) to authenticated;
grant execute on function public.set_setting(text, text, date, text) to authenticated;

-- Daily jobs: the server only.
grant execute on function public.expire_requests(date) to service_role;
grant execute on function public.apply_split(date) to service_role;
grant execute on function public.settle_trades(date) to service_role;
grant execute on function public.mature_gics(date) to service_role;
grant execute on function public.auto_move_unclaimed_maturities(date) to service_role;
grant execute on function public.pay_quarterly_dividends(date) to service_role;
grant execute on function public.post_monthly_interest(date) to service_role;
grant execute on function public.write_market_move_notes(date) to service_role;
grant execute on function public.send_rate_notices(date) to service_role;
grant execute on function public.accrue_savings_interest(date) to service_role;
grant execute on function public.run_daily(date) to service_role;

-- Reads. These only read, and row-level security or an explicit check limits a
-- kid to her own account. Some are used inside the views, which run as the caller.
grant execute on function public.edmonton_start(date) to authenticated, service_role;
grant execute on function public.gic_interest_cents(bigint, numeric, integer) to authenticated, service_role;
grant execute on function public.gic_interest_so_far_cents(bigint, numeric, integer, date, date, date) to authenticated, service_role;
grant execute on function public.rate_on(public.vehicle, integer, date) to authenticated, service_role;
grant execute on function public.setting_on(text, date) to authenticated, service_role;
grant execute on function public.can_read_account(uuid) to authenticated, service_role;
grant execute on function public.fund_value_at(uuid, text, date) to authenticated, service_role;
grant execute on function public.daily_balances(uuid, date, date) to authenticated, service_role;
grant execute on function public.fund_return(uuid, text, date) to authenticated, service_role;
grant execute on function public.liability_total() to authenticated, service_role;
grant execute on function public.next_settlement(text, timestamptz) to authenticated, service_role;
