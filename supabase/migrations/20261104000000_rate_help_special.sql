-- The ?s during a savings special (Dad, 2026-10-27, reviewing 20261103000000_rate_help.sql).
--
-- Both year projections, the Interest rate ? and the Inflation line, use the regular savings rate,
-- never a special: a special lasts days, not a year. kid_inflation already did (wish_savings_rate);
-- kid_rate_help now does too. The ? says the special in words instead: "Right now you're earning
-- the special {x} until {date}, then {regular}." So kid_rate_help also returns the rate in force
-- today and, during a savings special, its last day.
-- Only kid_rate_help changes; it stays read-only. Known answers: supabase/tests/rate_help_test.sql.

create or replace function public.kid_rate_help(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_now record;                -- the rate in force today (a special included): what Home shows
  v_special_end date;
  v_rate numeric;              -- the regular rate: what both year projections use
  v_infl numeric := coalesce(public.setting_on('inflation_rate', public.app_today())::numeric, 0);
  v_bal bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  select * into v_now from public.rate_on('savings', null, v_today);
  select r.end_date into v_special_end from public.rates r where r.id = v_now.rate_id and r.is_special;
  v_rate := coalesce(public.wish_savings_rate(v_today), v_now.rate, 0);

  select coalesce(b.savings_cents, 0) into v_bal from public.account_balances b where b.account_id = p_account_id;
  v_bal := coalesce(v_bal, 0);
  return jsonb_build_object(
    'today', v_today,
    'savings_rate', v_rate,
    'now_rate', coalesce(v_now.rate, v_rate),
    'special_until', v_special_end,
    'per_100_cents', ceil(v_rate * 100)::bigint,
    'per_100_exact', v_rate * 100 = ceil(v_rate * 100),
    'balance_cents', v_bal,
    'year_cents', case when v_bal > 0 and v_rate > 0 then public.savings_year_cents(v_bal, v_rate) end,
    'inflation_rate', v_infl,
    'infl_100_cents', 10000 + ceil(v_infl * 100)::bigint,
    'infl_exact', v_infl * 100 = ceil(v_infl * 100),
    'need_cents', case when v_bal > 0 then ceil(v_bal * (1 + v_infl / 100))::bigint end);
end;
$$;
comment on function public.kid_rate_help(uuid) is
  'The live figures for the Interest rate and Inflation ?s beside her savings (2026-10-26). Year figures use the regular rate; a running savings special comes with its last day (2026-10-27). Read-only.';

revoke all on function public.kid_rate_help(uuid) from public, anon, authenticated, service_role;
grant execute on function public.kid_rate_help(uuid) to authenticated;
