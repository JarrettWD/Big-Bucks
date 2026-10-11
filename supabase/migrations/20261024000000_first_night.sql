-- The first night (Dad, 2026-10-10). An evening's work is done once, among other
-- things, savings interest for the day before is worked out. But on the evening the
-- first account opens, the day before had no account, so its interest never exists,
-- and the run never counted as done: production's first night (Oct 10, 2026) called
-- the nightly function every 30 minutes until 10:30 pm. No money was affected (no
-- price calls, no alerts), and it settled the next evening.
--
-- Now, as jobs_behind() already does for the health check: the day before's interest
-- is waited for only when an account was open that day. With no account at all (a
-- brand-new project), it isn't waited for either. Everything else is as before.
-- Known answers: supabase/tests/first_night_test.sql, through nightly_kick().

create or replace function public.nightly_status(p_date date)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_closes jsonb;
  v_jobs jsonb;
  v_reconciled boolean;
  v_interest_day date := least(p_date, public.app_today() - 1);
  v_first date := public.first_account_day();
  -- No account was open on the interest day (or there's none yet): no interest is owed for it.
  v_interest_owed boolean := v_first is not null and v_interest_day >= v_first;
begin
  select coalesce(jsonb_agg(f.id order by f.sort_order), '[]'::jsonb) into v_closes
    from public.funds f
   where public.is_trading_day(f.market, p_date) and public.final_close(f.id, p_date) is null;

  select coalesce(jsonb_agg(j.name order by j.ord), '[]'::jsonb) into v_jobs
    from unnest(array['expire', 'splits', 'settle', 'dividends', 'notes', 'gic_maturity', 'auto_move',
                      'monthly', 'rate_notices', 'interest']) with ordinality j(name, ord)
   where (j.name <> 'interest' or v_interest_owed)
     and not exists (select 1 from public.job_runs jr
                      where jr.job::text = j.name and jr.status = 'ok'
                        and jr.run_for_date = case when j.name = 'interest' then v_interest_day else p_date end);

  v_reconciled := exists (select 1 from public.job_runs jr where jr.job = 'reconcile' and jr.run_for_date = p_date);

  return jsonb_build_object('date', p_date, 'closes_missing', v_closes, 'jobs_waiting', v_jobs,
                            'reconciled', v_reconciled,
                            'done', jsonb_array_length(v_closes) = 0 and jsonb_array_length(v_jobs) = 0 and v_reconciled);
end;
$$;
comment on function public.nightly_status(date) is
  'Where tonight''s work stands for a day: closes, jobs (the day before''s interest only when an account was open that day) and the check.';
