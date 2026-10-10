-- Stage 4 Part B follow-up (Dad, 2026-10-10): the health check in plain words.
--
-- 1. A job counts as "behind" only once it could have run since the first account
--    opened. Before, the morning after the first account opened always failed for
--    savings interest (a day's interest is worked out the next evening), and every
--    job failed until the first evening run: false alarms.
-- 2. health_check() gains a summary line, in plain words, which the GitHub email
--    shows: "Nightly jobs haven't finished since Oct 9 (interest, settle)." or
--    "1 open alert: open the parent Dashboard to see it." It holds only job names,
--    dates and counts, never anyone's name (the workflow log may be public).
-- 3. parent_nightly_status(): the same words about jobs for Dad's Dashboard, which
--    showed "No open alerts" while the email said to look there.

-- 1. Which jobs are behind ----------------------------------------------------------------------------

-- Each daily job, how far it should have got by this morning (jobs: yesterday;
-- savings interest: the day before, since a day's interest is worked out once the
-- day is over), and how far it has got. Only counted once the first account had
-- opened by then: before that there was nothing for the job to do.
create function public.jobs_behind()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_first date := public.first_account_day();
  v_r record;
  v_last date;
  v_out jsonb := '[]'::jsonb;
begin
  if v_first is null then
    return v_out;
  end if;
  for v_r in
    select j.name, j.due
      from (values (1, 'expire', 1), (2, 'splits', 1), (3, 'settle', 1), (4, 'gic_maturity', 1),
                   (5, 'auto_move', 1), (6, 'dividends', 1), (7, 'monthly', 1), (8, 'rate_notices', 1),
                   (9, 'interest', 2), (10, 'reconcile', 1)) j(ord, name, due)
     order by j.ord
  loop
    -- reconcile counts when it ran at all: the problems it finds are alerts.
    if v_r.name = 'reconcile' then
      select max(jr.run_for_date) into v_last from public.job_runs jr where jr.job = 'reconcile';
    else
      select max(jr.run_for_date) into v_last from public.job_runs jr
       where jr.job::text = v_r.name and jr.status = 'ok';
    end if;
    if v_today - v_r.due >= v_first and coalesce(v_last, v_first - 1) < v_today - v_r.due then
      v_out := v_out || jsonb_build_object('job', v_r.name, 'done_through', v_last);
    end if;
  end loop;
  return v_out;
end;
$$;

-- The jobs part of the summary, or null when no job is behind.
create function public.jobs_behind_words(p_behind jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select case
           when coalesce(jsonb_array_length(p_behind), 0) = 0 then null
           when bool_and(b ->> 'done_through' is null)
             then 'Nightly jobs haven''t run yet (' || string_agg(b ->> 'job', ', ') || ').'
           else 'Nightly jobs haven''t finished since '
                || public.fmt_date(min((b ->> 'done_through')::date))
                || case when bool_or(b ->> 'done_through' is null) then ', and some haven''t run yet' else '' end
                || ' (' || string_agg(b ->> 'job', ', ') || ').'
         end
    from jsonb_array_elements(coalesce(p_behind, '[]'::jsonb)) b;
$$;

-- 2. The health check, with its summary ----------------------------------------------------------------

create or replace function public.health_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_problems jsonb := '[]'::jsonb;
  v_behind jsonb := public.jobs_behind();
  v_r record;
  v_alerts integer := 0;
  v_jobs text;
  v_summary text;
begin
  for v_r in
    select al.id, al.kind, al.account_id, al.message, al.created_at from public.alerts al
     where al.resolved_at is null and not al.is_quiet order by al.id
  loop
    v_problems := v_problems || jsonb_build_object('kind', 'alert', 'alert_id', v_r.id, 'alert_kind', v_r.kind,
                                                   'account_id', v_r.account_id, 'message', v_r.message,
                                                   'since', v_r.created_at);
    v_alerts := v_alerts + 1;
  end loop;

  for v_r in select b ->> 'job' as job, (b ->> 'done_through')::date as done from jsonb_array_elements(v_behind) b loop
    v_problems := v_problems || jsonb_build_object('kind', 'behind', 'job', v_r.job, 'done_through', v_r.done,
      'message', 'The ' || v_r.job || ' job has only finished through '
                 || coalesce(to_char(v_r.done, 'Mon DD, YYYY'), 'never') || '.');
  end loop;

  v_jobs := public.jobs_behind_words(v_behind);
  v_summary := concat_ws(' ',
    case when v_alerts = 1 then '1 open alert: open the parent Dashboard to see it.'
         when v_alerts > 1 then v_alerts || ' open alerts: open the parent Dashboard to see them.' end,
    v_jobs || case when v_jobs is not null
                   then ' They catch up by themselves at the next evening run; if they don''t, see RUNBOOK, "How the nightly run works".'
              end);

  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'checked_at', public.app_now(),
                            'summary', coalesce(nullif(v_summary, ''), 'All well.'),
                            'problems', v_problems);
end;
$$;

-- 3. The same words for Dad's Dashboard ---------------------------------------------------------------

create function public.parent_nightly_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_behind jsonb;
begin
  perform public.require_parent();
  v_behind := public.jobs_behind();
  return jsonb_build_object('behind', jsonb_array_length(v_behind) > 0,
                            'text', public.jobs_behind_words(v_behind));
end;
$$;
comment on function public.parent_nightly_status() is
  'For Dad''s Dashboard: whether the nightly jobs are behind, in the same words as the health check.';

revoke all on function public.jobs_behind() from public, anon, authenticated, service_role;
revoke all on function public.jobs_behind_words(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.parent_nightly_status() from public, anon, authenticated, service_role;
grant execute on function public.parent_nightly_status() to authenticated;
