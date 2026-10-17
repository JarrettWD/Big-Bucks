-- Stage 11: the learning features (plan approved by Dad 2026-10-17, with his five additions:
-- docs/plans/stage11-plan.md). Each is behind its own switch.
--
-- Nothing here posts, moves, rounds-and-stores or changes money, and no money function is
-- changed or calls anything here. Every figure is worked out from the ledger, rates,
-- settings and closes, in integer cents, each time it's asked for. The only new writes are
-- her reflection on a sale (its own append-only table) and her view mode.
--
-- 1. Switches and What's new: six new features.
-- 2. sell_reflections: "Why did you sell?", one per sale, append-only; the pre-launch reset clears it.
-- 3. View modes: kid_view_mode, kid_set_view_mode (accounts.view_mode, since stage 1).
-- 4. Statements: statement_fund_gains (on its own, never a remainder), statement_figures,
--    statement_ready, kid_statement_months, kid_statement.
-- 5. The what-if: kid_what_if (savings, 1-year GICs, the Nasdaq-100), by the real rules.
-- 6. Compare the markets: kid_market_compare.
-- 7. The inflation view: kid_inflation.
-- 8. "View as" reads them all (parent_view).
-- Known answers: supabase/tests/statements_test.sql and learning_test.sql.

-- 1. Switches and What's new -------------------------------------------------------------------------------

create or replace function public.feature_list()
returns table (name text, sort_order integer)
language sql immutable
set search_path = ''
as $$
  values ('wishlist', 1), ('personalisation', 2), ('badges', 3), ('inflation', 4), ('whatif', 5),
         ('markets', 6), ('reflection', 7), ('statements', 8), ('viewmodes', 9);
$$;

insert into public.whats_new_features (feature, title, lines, link) values
  ('inflation', 'New: what will it buy? 💡', $l$[
     "Prices slowly go up over time. That's called inflation.",
     "Turn on \"What will it buy?\" on Home to see what your money will buy later."]$l$::jsonb, '/kid'),
  ('whatif', 'New: what if? 🤔', $l$[
     "See what would have happened if all your money had gone into just one place.",
     "It's a look back, not a scorecard."]$l$::jsonb, '/kid/graphs?g=whatif'),
  ('markets', 'New: compare the markets 🌎', $l$[
     "See how the three funds did over the same time.",
     "Different markets go up and down differently."]$l$::jsonb, '/kid/graphs?g=markets'),
  ('reflection', 'New: why did you sell? ✏️', $l$[
     "After you sell part of a fund, you can write down why.",
     "Later, you can look back and see what you were thinking."]$l$::jsonb, null),
  ('statements', 'New: your monthly statement 📄', $l$[
     "Each month, see where your money started, what came in and went out, what it earned, and where it ended."]$l$::jsonb,
   '/kid/statements'),
  ('viewmodes', 'New: a simpler view 👀', $l$[
     "Like big numbers and fewer graphs? Tap \"Simpler view\" at the bottom of Home.",
     "You can switch back any time."]$l$::jsonb, '/kid');

-- 2. "Why did you sell?" ------------------------------------------------------------------------------------

create table public.sell_reflections (
  request_id bigint primary key references public.requests (id),
  account_id uuid not null references public.accounts (id),
  reflection text not null check (btrim(reflection) <> '' and char_length(reflection) <= 300),
  created_at timestamptz not null default public.app_now()
);
comment on table public.sell_reflections is
  'Stage 11: her own words on why she sold, one per fund sale. Append-only. Her rows, or the parent.';
create index sell_reflections_account_idx on public.sell_reflections (account_id, created_at desc);
create trigger sell_reflections_no_update_delete
  before update or delete on public.sell_reflections
  for each row execute function public.reject_append_only_change();
create trigger sell_reflections_no_truncate
  before truncate on public.sell_reflections
  for each statement execute function public.reject_append_only_change();
alter table public.sell_reflections enable row level security;
create policy sell_reflections_read on public.sell_reflections for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
revoke all on public.sell_reflections from public, anon, authenticated, service_role;
grant select on public.sell_reflections to authenticated, service_role;

-- The app calls this only after her sell request has succeeded: the sell never depends on it.
create function public.kid_save_reflection(p_request_id bigint, p_text text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.kid_account();
  v_text text := btrim(coalesce(p_text, ''));
begin
  if not exists (select 1 from public.requests r
                  where r.id = p_request_id and r.account_id = v_acct
                    and r.type = 'move' and r.from_vehicle = 'stock') then
    raise exception 'That isn''t one of your fund sales.' using errcode = '42501';
  end if;
  if not public.feature_enabled('reflection', v_acct) then
    raise exception 'Why did you sell? isn''t switched on for you yet.' using errcode = '42501';
  end if;
  if v_text = '' then
    raise exception 'Type why, or tap Skip.';
  end if;
  if char_length(v_text) > 300 then
    raise exception 'Keep it to 300 letters or fewer.';
  end if;
  if exists (select 1 from public.sell_reflections s where s.request_id = p_request_id) then
    raise exception 'You already said why you sold.';
  end if;
  insert into public.sell_reflections (request_id, account_id, reflection) values (p_request_id, v_acct, v_text);
end;
$$;

create function public.kid_reflections(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own reflections.' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('request_id', s.request_id, 'text', s.reflection,
                                                       'created_at', s.created_at) order by s.created_at desc, s.request_id desc)
                     from public.sell_reflections s where s.account_id = p_account_id), '[]'::jsonb);
end;
$$;

create or replace function private.prelaunch_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['public.transactions', 'public.interest_accruals', 'public.gic_holdings', 'public.requests',
               'public.notifications', 'public.questions', 'public.goals', 'public.badges',
               'public.wishlist_items', 'public.wishlist_parent_marks', 'public.wishlist_photos',
               'public.agreement_signatures', 'public.whats_new_seen', 'public.alerts', 'public.login_attempts',
               'public.outbox', 'private.kid_pin_resets', 'public.sell_reflections'];
$$;

-- Which switches are on for her, in one call (the app's screens decide what to show from it).
create function public.kid_features(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $func$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  return (select jsonb_object_agg(f.name, public.feature_enabled(f.name, p_account_id)) from public.feature_list() f);
end;
$func$;

-- 3. View modes --------------------------------------------------------------------------------------------

-- Her mode: her choice while the switch is on for her, otherwise detailed (today's screens).
create function public.kid_view_mode(p_account_id uuid)
returns text
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own view.' using errcode = '42501';
  end if;
  if not public.feature_enabled('viewmodes', p_account_id) then
    return 'detailed';
  end if;
  return (select a.view_mode::text from public.accounts a where a.id = p_account_id);
end;
$$;

create function public.kid_set_view_mode(p_mode text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.kid_account();
begin
  if not public.feature_enabled('viewmodes', v_acct) then
    raise exception 'The simpler view isn''t switched on for you yet.' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('basic', 'detailed') then
    raise exception 'Pick basic or detailed.';
  end if;
  update public.accounts a set view_mode = p_mode::public.view_mode where a.id = v_acct;
  return p_mode;
end;
$$;

-- 4. Statements --------------------------------------------------------------------------------------------

-- Her funds' gains or losses from one day to another, on their own (never what's left over):
-- for each fund, its value at the end (units × that day's close, to the cent, as the graphs
-- show it), minus its value the day before the start, minus what she paid for units bought,
-- plus what she got for units sold (both from the savings side of each trade).
create function public.statement_fund_gains(p_account uuid, p_from date, p_to date)
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(sum(public.fund_value_at(p_account, f.id, p_to) - public.fund_value_at(p_account, f.id, p_from - 1)
           + coalesce((select sum(t.amount_cents) from public.transactions t
                        where t.account_id = p_account and t.fund_id = f.id and t.vehicle = 'savings'
                          and t.type in ('transfer_out', 'transfer_in')
                          and t.effective_at >= public.edmonton_start(p_from)
                          and t.effective_at < public.edmonton_start(p_to + 1)), 0)), 0)::bigint
    from public.funds f;
$$;
comment on function public.statement_fund_gains(uuid, date, date) is
  'Stage 11: fund gains for a statement: value at the end - value before the start - paid for buys + got from sells.';

-- Every figure for a statement from one day to another, from the ledger. A money line counts on
-- the day it's dated (effective_at): October's savings interest, dated Nov 1, is November's.
-- Interest still accruing is never counted (as on Home and the graphs).
create function public.statement_figures(p_account uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_lo timestamptz := public.edmonton_start(p_from);
  v_hi timestamptz := public.edmonton_start(p_to + 1);
  v_start bigint;
  v_end bigint;
  v_in bigint;
  v_out bigint;
  v_interest bigint;
  v_dividends bigint;
  v_fixes bigint;
  v_gains bigint;
  v_uncounted bigint;
  v_funds jsonb;
begin
  select coalesce((select b.total_cents from public.daily_balances(p_account, p_from - 1, p_from - 1) b), 0) into v_start;
  select b.total_cents into v_end from public.daily_balances(p_account, p_to, p_to) b;
  select coalesce(sum(t.amount_cents) filter (where t.type = 'deposit'
                                                 or (t.type = 'correction' and t.counts_as = 'money' and t.amount_cents > 0)), 0),
         -coalesce(sum(t.amount_cents) filter (where t.type = 'withdraw'
                                                  or (t.type = 'correction' and t.counts_as = 'money' and t.amount_cents < 0)), 0),
         coalesce(sum(t.amount_cents) filter (where t.type in ('interest', 'penalty')), 0),
         coalesce(sum(t.amount_cents) filter (where t.type = 'dividend'), 0),
         coalesce(sum(t.amount_cents) filter (where t.type = 'correction' and coalesce(t.counts_as, 'earned') = 'earned'), 0),
         count(*) filter (where t.type not in ('deposit', 'withdraw', 'interest', 'penalty', 'dividend', 'correction',
                                               'transfer_in', 'transfer_out', 'split_adjust'))
    into v_in, v_out, v_interest, v_dividends, v_fixes, v_uncounted
    from public.transactions t
   where t.account_id = p_account and t.effective_at >= v_lo and t.effective_at < v_hi;
  v_gains := public.statement_fund_gains(p_account, p_from, p_to);
  select coalesce(jsonb_agg(jsonb_build_object(
           'fund', f.id, 'name', f.name,
           'start_cents', public.fund_value_at(p_account, f.id, p_from - 1),
           'end_cents', public.fund_value_at(p_account, f.id, p_to),
           'paid_cents', -coalesce((select sum(t.amount_cents) from public.transactions t
                                     where t.account_id = p_account and t.fund_id = f.id and t.vehicle = 'savings'
                                       and t.type = 'transfer_out' and t.effective_at >= v_lo and t.effective_at < v_hi), 0),
           'got_cents', coalesce((select sum(t.amount_cents) from public.transactions t
                                   where t.account_id = p_account and t.fund_id = f.id and t.vehicle = 'savings'
                                     and t.type = 'transfer_in' and t.effective_at >= v_lo and t.effective_at < v_hi), 0))
           order by f.sort_order), '[]'::jsonb)
    into v_funds
    from public.funds f
   where exists (select 1 from public.transactions t where t.account_id = p_account and t.fund_id = f.id
                    and t.vehicle = 'stock' and t.effective_at < v_hi);
  return jsonb_build_object(
    'start_cents', v_start, 'money_in_cents', v_in, 'money_out_cents', v_out, 'interest_cents', v_interest,
    'dividends_cents', v_dividends, 'fund_gains_cents', v_gains, 'fixes_cents', v_fixes, 'end_cents', v_end,
    'uncounted', v_uncounted, 'funds', v_funds,
    'balanced', v_uncounted = 0
                and v_end = v_start + v_in - v_out + v_interest + v_dividends + v_gains + v_fixes);
end;
$$;

-- A month is final once it's over, its nightly jobs (both chains) have finished through its
-- last day, and her figures aren't "Updating…". After that nothing can change it: anything
-- posted later is dated in a later month.
create function public.statement_ready(p_account uuid, p_last date)
returns boolean
language sql stable
set search_path = ''
as $$
  select public.app_today() > p_last
     and (select count(distinct jr.job) from public.job_runs jr
           where jr.run_for_date = p_last and jr.status = 'ok'
             and jr.job in ('expire', 'splits', 'settle', 'dividends', 'gic_maturity', 'auto_move')) = 6
     and not public.figures_updating(p_account);
$$;

create function public.kid_statement_months(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_opened date;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own statements.' using errcode = '42501';
  end if;
  if not public.feature_enabled('statements', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  select public.edmonton_local(a.created_at)::date into v_opened from public.accounts a where a.id = p_account_id;
  return jsonb_build_object('on', true, 'months', coalesce((
    select jsonb_agg(jsonb_build_object(
             'month', m::date,
             'ready', public.statement_ready(p_account_id, (m + interval '1 month' - interval '1 day')::date),
             'ready_on', (m + interval '1 month')::date) order by m)
      from generate_series(date_trunc('month', v_opened), date_trunc('month', public.app_today()), interval '1 month') m),
    '[]'::jsonb));
end;
$$;

create function public.kid_statement(p_account_id uuid, p_month date)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_opened date;
  v_from date;
  v_to date;
  v_fig jsonb;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own statements.' using errcode = '42501';
  end if;
  if not public.feature_enabled('statements', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  select public.edmonton_local(a.created_at)::date into v_opened from public.accounts a where a.id = p_account_id;
  if p_month is null or v_month < date_trunc('month', v_opened) or v_month > date_trunc('month', public.app_today()) then
    raise exception 'There''s no statement for that month.';
  end if;
  v_from := greatest(v_month, v_opened);
  v_to := (v_month + interval '1 month' - interval '1 day')::date;
  if not public.statement_ready(p_account_id, v_to) then
    return jsonb_build_object('on', true, 'month', v_month, 'ready', false, 'ready_on', v_to + 1);
  end if;
  v_fig := public.statement_figures(p_account_id, v_from, v_to);
  -- Never wrong numbers: one that doesn't add up shows none (the app says it's being checked).
  if not (v_fig ->> 'balanced')::boolean then
    return jsonb_build_object('on', true, 'month', v_month, 'ready', true, 'balanced', false);
  end if;
  return jsonb_build_object('on', true, 'month', v_month, 'ready', true, 'from', v_from, 'to', v_to,
                            'opened_this_month', v_from > v_month or v_from = v_opened) || v_fig;
end;
$$;

-- 5. The what-if ----------------------------------------------------------------------------------------------
-- "If all the money you put in had gone into just one place." Her real money moments (deposits,
-- withdrawals and "money" fixes, at their effective_at), replayed by the real rules:
--   savings: daily accrual at the rate in force that day (specials included), paid on the 1st, rounded up;
--   1-year GICs: each deposit buys one that day at that day's 1-year rate (specials included); at
--     maturity it renews with everything at the rate that day; interest by the GIC rule, rounded up;
--     a withdrawal comes from cash first, then breaks the newest GICs (principal back, no interest);
--   the Nasdaq-100: units at the first final close after each deposit (rounded up at 8 decimals),
--     splits, dividends by the real pro-rata rule kept as cash; a withdrawal sells units at the
--     latest final close before it; the value is units × the latest close, to the cent.
-- Interest counts as her real money's does: savings when paid on the 1st, a GIC when it finishes.

create function public.kid_what_if(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  c_fund constant text := 'nasdaq100';
  v_today date := public.app_today();
  v_first date;
  v_day date;
  e_at timestamptz[];
  e_day date[];
  e_cents bigint[];
  v_k integer;
  v_market public.market;
  -- savings
  s_bal bigint := 0;
  s_acc numeric := 0;
  -- GICs (parallel arrays), and cash from broken GICs
  g_p bigint[] := '{}';
  g_rate numeric[] := '{}';
  g_mat date[] := '{}';
  g_on boolean[] := '{}';
  g_cash bigint := 0;
  v_i integer;
  v_need bigint;
  -- the Nasdaq-100
  n_units numeric := 0;
  n_cash bigint := 0;
  n_divs bigint := 0;
  p_amt bigint[] := '{}';
  p_at timestamptz[] := '{}';
  p_day date[] := '{}';
  p_done boolean[] := '{}';
  h_units numeric[] := '{}';   -- units at the end of each day, from v_first
  v_close numeric;
  v_settle timestamptz;
  v_split record;
  v_sell numeric;
  v_proceeds bigint;
  v_qstart date;
  v_qfrom date;
  v_qto date;
  v_last date;
  v_yield numeric;
  v_ud numeric;
  v_den bigint;
  v_mult bigint;
  v_d date;
  v_u numeric;
  v_paid date[] := '{}';
  v_actual bigint;
  v_n integer;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own what-if.' using errcode = '42501';
  end if;
  if not public.feature_enabled('whatif', p_account_id) then
    return jsonb_build_object('on', false);
  end if;

  -- Her real money moments, in order.
  select coalesce(array_agg(t.effective_at order by t.effective_at, t.id), '{}'),
         coalesce(array_agg(public.edmonton_local(t.effective_at)::date order by t.effective_at, t.id), '{}'),
         coalesce(array_agg(t.amount_cents order by t.effective_at, t.id), '{}')
    into e_at, e_day, e_cents
    from public.transactions t
   where t.account_id = p_account_id
     and (t.type in ('deposit', 'withdraw') or (t.type = 'correction' and t.counts_as = 'money'))
     and t.effective_at < public.edmonton_start(v_today + 1);
  v_first := e_day[1];
  if v_first is null then
    return jsonb_build_object('on', true, 'none', true);
  end if;
  select f.market into v_market from public.funds f where f.id = c_fund;

  -- The Nasdaq-100: when each deposit would buy (its settlement moment and day).
  for v_k in 1 .. coalesce(array_length(e_at, 1), 0) loop
    continue when e_cents[v_k] <= 0;
    v_settle := public.next_settlement(c_fund, e_at[v_k]);
    p_amt := p_amt || e_cents[v_k];
    p_at := p_at || v_settle;
    p_day := p_day || public.edmonton_local(v_settle)::date;
    p_done := p_done || false;
  end loop;

  v_day := v_first;
  while v_day <= v_today loop
    -- Savings: last month's interest is paid on the 1st, rounded up.
    if extract(day from v_day) = 1 then
      s_bal := s_bal + ceil(s_acc)::bigint;
      s_acc := 0;
    end if;
    -- GICs finishing today renew with everything at today's 1-year rate.
    for v_i in 1 .. coalesce(array_length(g_p, 1), 0) loop
      if g_on[v_i] and g_mat[v_i] = v_day then
        g_p[v_i] := g_p[v_i] + public.gic_interest_cents(g_p[v_i], g_rate[v_i], 12);
        g_rate[v_i] := (public.rate_on('gic', 12, v_day)).rate;
        g_mat[v_i] := (v_day + interval '12 months')::date;
      end if;
    end loop;
    -- The Nasdaq-100: a split today (units in after-split terms from today).
    for v_split in select s.* from public.fund_splits s where s.fund_id = c_fund and s.split_date = v_day loop
      n_units := n_units * v_split.ratio_to / v_split.ratio_from;
    end loop;
    -- ...and a quarter's dividend, paid on the quarter's first trading day.
    if extract(month from v_day) in (1, 4, 7, 10) and extract(day from v_day) <= 10 then
      v_qstart := date_trunc('quarter', v_day)::date;
      if public.first_trading_day_from(v_market, v_qstart) = v_day and not (v_qstart = any (v_paid)) then
        v_qfrom := (v_qstart - interval '3 months')::date;
        v_qto := v_qstart - 1;
        v_last := public.last_trading_day_before(v_market, v_qstart);
        v_close := public.final_close(c_fund, v_last);
        v_yield := coalesce(public.setting_on('dividend_yield:' || c_fund, v_day)::numeric, 0);
        if v_close is not null then
          v_paid := v_paid || v_qstart;
          v_den := 1;
          for v_split in select s.* from public.fund_splits s
                          where s.fund_id = c_fund and s.split_date > v_qfrom and s.split_date <= v_last loop
            v_den := v_den * v_split.ratio_from;
          end loop;
          v_ud := 0;
          v_d := v_qfrom;
          while v_d <= v_qto loop
            v_u := case when v_d >= v_first then coalesce(h_units[v_d - v_first + 1], 0) else 0 end;
            if v_u <> 0 then
              v_mult := 1;
              for v_split in select s.* from public.fund_splits s
                              where s.fund_id = c_fund and s.split_date > v_qfrom and s.split_date <= v_last loop
                v_mult := v_mult * case when v_split.split_date > v_d then v_split.ratio_to else v_split.ratio_from end;
              end loop;
              -- As the real rule (dividend_unit_days): that day's units × its split multiplier.
              v_ud := v_ud + v_mult * v_u;
            end if;
            v_d := v_d + 1;
          end loop;
          if v_ud > 0 then
            v_proceeds := public.ceil_div(v_ud * v_close * v_yield, 4 * (v_qstart - v_qfrom) * v_den);
            n_cash := n_cash + v_proceeds;
            n_divs := n_divs + v_proceeds;
          end if;
        end if;
      end if;
    end if;

    -- Today's money moments, in order (a buy settles at its close, before anything after it).
    for v_k in 1 .. coalesce(array_length(e_at, 1), 0) loop
      continue when e_day[v_k] <> v_day;
      -- Nasdaq-100 buys whose close came before this moment.
      for v_i in 1 .. coalesce(array_length(p_amt, 1), 0) loop
        if not p_done[v_i] and p_at[v_i] <= e_at[v_k] then
          v_close := public.final_close(c_fund, p_day[v_i]);
          if v_close is not null then
            n_units := n_units + public.round_up_units(p_amt[v_i] / (v_close * 100));
            p_done[v_i] := true;
          end if;
        end if;
      end loop;
      if e_cents[v_k] > 0 then
        s_bal := s_bal + e_cents[v_k];
        g_p := g_p || e_cents[v_k];
        g_rate := g_rate || (public.rate_on('gic', 12, v_day)).rate;
        g_mat := g_mat || (v_day + interval '12 months')::date;
        g_on := g_on || true;
      else
        v_need := -e_cents[v_k];
        s_bal := greatest(s_bal - v_need, 0);
        -- GICs: cash first, then break the newest.
        v_i := coalesce(array_length(g_p, 1), 0);
        while g_cash < v_need and v_i >= 1 loop
          if g_on[v_i] then
            g_cash := g_cash + g_p[v_i];
            g_on[v_i] := false;
          end if;
          v_i := v_i - 1;
        end loop;
        g_cash := greatest(g_cash - v_need, 0);
        -- The Nasdaq-100: cash first (unbought deposits count as cash), then sell units.
        v_n := 0;
        for v_i in 1 .. coalesce(array_length(p_amt, 1), 0) loop
          if not p_done[v_i] and p_at[v_i] > e_at[v_k] and v_need > 0 then
            v_n := least(v_need, p_amt[v_i]);
            p_amt[v_i] := p_amt[v_i] - v_n;
            v_need := v_need - v_n;
          end if;
        end loop;
        v_n := least(v_need, n_cash);
        n_cash := n_cash - v_n;
        v_need := v_need - v_n;
        if v_need > 0 and n_units > 0 then
          select fp.close into v_close
            from public.fund_prices fp
           where fp.fund_id = c_fund and fp.source = 'daily'
             and fp.fetched_at >= public.close_time(v_market, fp.price_date)
             and public.close_time(v_market, fp.price_date) <= e_at[v_k]
           order by fp.price_date desc limit 1;
          if v_close is not null then
            v_sell := least(n_units, public.round_up_units(v_need / (v_close * 100)));
            v_proceeds := ceil(v_sell * v_close * 100)::bigint;
            n_units := n_units - v_sell;
            n_cash := greatest(n_cash + v_proceeds - v_need, 0);
          end if;
        end if;
      end if;
    end loop;
    -- The rest of today's buys, at today's close.
    for v_i in 1 .. coalesce(array_length(p_amt, 1), 0) loop
      if not p_done[v_i] and p_day[v_i] <= v_day and p_amt[v_i] > 0 then
        v_close := public.final_close(c_fund, p_day[v_i]);
        if v_close is not null then
          n_units := n_units + public.round_up_units(p_amt[v_i] / (v_close * 100));
          p_done[v_i] := true;
        end if;
      end if;
    end loop;
    h_units := h_units || n_units;

    -- Savings: today's interest accrues once the day is over.
    if v_day < v_today then
      s_acc := s_acc + s_bal * (public.rate_on('savings', null, v_day)).rate / 100
                       / (date_trunc('year', v_day + interval '1 year')::date - date_trunc('year', v_day)::date);
    end if;
    v_day := v_day + 1;
  end loop;

  select coalesce(b.total_worth_cents, 0) into v_actual from public.account_balances b where b.account_id = p_account_id;
  select fp.close into v_close from public.fund_prices fp
   where fp.fund_id = c_fund and fp.price_date <= v_today order by fp.price_date desc limit 1;

  return jsonb_build_object(
    'on', true, 'as_of', v_today, 'first_day', v_first,
    'actual_cents', coalesce(v_actual, 0),
    'savings_cents', s_bal,
    'gic_cents', g_cash + coalesce((select sum(g_p[i]) from generate_subscripts(g_p, 1) i where g_on[i]), 0),
    'gics_growing', coalesce((select count(*) from generate_subscripts(g_on, 1) i where g_on[i]), 0),
    'nasdaq_cents', n_cash
                    + coalesce((select sum(p_amt[i]) from generate_subscripts(p_amt, 1) i where not p_done[i]), 0)
                    + coalesce(round(n_units * coalesce(v_close, 0) * 100), 0)::bigint,
    'nasdaq_dividends_cents', n_divs);
end;
$$;

-- 6. Compare the markets -----------------------------------------------------------------------------------
-- Each fund's % change over the same period, from the first close on or after its start, split-
-- adjusted. Daily points up to about 3 months; weekly (each week's last close) beyond.

create function public.kid_market_compare(p_account_id uuid, p_range text)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_start date;
  v_weekly boolean;
  v_funds jsonb;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own graphs.' using errcode = '42501';
  end if;
  if not public.feature_enabled('markets', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  v_start := case p_range
               when '1M' then (v_today - interval '1 month')::date
               when '3M' then (v_today - interval '3 months')::date
               when '1Y' then (v_today - interval '1 year')::date
               when '2Y' then (v_today - interval '2 years')::date
               when 'start' then (select public.edmonton_local(a.created_at)::date from public.accounts a where a.id = p_account_id)
             end;
  if v_start is null then
    raise exception 'Pick 1M, 3M, 1Y, 2Y or since you started.';
  end if;
  v_weekly := v_today - v_start > 100;

  with adj as (
    select fp.fund_id, fp.price_date,
           fp.close * coalesce((select exp(sum(ln(s.ratio_from::numeric / s.ratio_to))) from public.fund_splits s
                                 where s.fund_id = fp.fund_id and s.split_date > fp.price_date
                                   and s.split_date <= v_today), 1) as c
      from public.fund_prices fp
     where fp.price_date >= v_start and fp.price_date <= v_today),
  kept as (
    select z.fund_id, z.price_date, z.c
      from (select a.*, max(a.price_date) over (partition by a.fund_id, date_trunc('week', a.price_date)) as week_last
              from adj a) z
     where not v_weekly or z.price_date = z.week_last),
  base as (
    select distinct on (a.fund_id) a.fund_id, a.c from adj a order by a.fund_id, a.price_date)
  select jsonb_agg(jsonb_build_object(
           'fund', f.id, 'name', f.name, 'colour', f.colour,
           'last_pct', (select round((k.c / b.c - 1) * 100, 2) from kept k where k.fund_id = f.id order by k.price_date desc limit 1),
           'points', (select jsonb_agg(jsonb_build_object('day', k.price_date, 'pct', round((k.c / b.c - 1) * 100, 2))
                                       order by k.price_date)
                        from kept k where k.fund_id = f.id))
           order by f.sort_order)
    into v_funds
    from public.funds f join base b on b.fund_id = f.id;

  return jsonb_build_object('on', true, 'range', p_range,
    'from', (select min(x.d) from (select min(fp.price_date) as d from public.fund_prices fp
                                    where fp.price_date >= v_start and fp.price_date <= v_today group by fp.fund_id) x),
    'weekly', v_weekly, 'funds', coalesce(v_funds, '[]'::jsonb));
end;
$$;

-- 7. The inflation view -------------------------------------------------------------------------------------
-- What her money will buy: savings a year from now at today's regular savings rate (monthly
-- compounding, as the wish list projects), each GIC when it finishes at its locked rate, both
-- divided by the price rise to then at the inflation setting; and each fund's change over the
-- past year, looking back (funds have no set rate). Nearest cent, always worded "about".

create function public.kid_inflation(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_infl numeric := coalesce(public.setting_on('inflation_rate', public.app_today())::numeric, 0);
  v_rate numeric := coalesce(public.wish_savings_rate(public.app_today()), 0);
  v_now bigint;
  v_year numeric;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own money.' using errcode = '42501';
  end if;
  if not public.feature_enabled('inflation', p_account_id) then
    return jsonb_build_object('on', false);
  end if;
  select coalesce(b.savings_cents, 0) into v_now from public.account_balances b where b.account_id = p_account_id;
  v_year := coalesce(v_now, 0) * power(1 + v_rate / 1200, 12);

  return jsonb_build_object(
    'on', true,
    'inflation_rate', public.setting_on('inflation_rate', v_today),
    'savings', jsonb_build_object('now_cents', coalesce(v_now, 0), 'savings_rate', v_rate,
                                  'in_a_year_cents', round(v_year)::bigint,
                                  'buys_like_cents', round(v_year / (1 + v_infl / 100))::bigint),
    'gics', coalesce((
      select jsonb_agg(jsonb_build_object(
               'gic_id', g.id, 'principal_cents', g.principal_cents, 'rate', g.rate, 'term_months', g.term_months,
               'maturity_date', g.maturity_date, 'days', g.maturity_date - v_today,
               'at_maturity_cents', g.principal_cents + public.gic_interest_cents(g.principal_cents, g.rate, g.term_months),
               'buys_like_cents', round((g.principal_cents + public.gic_interest_cents(g.principal_cents, g.rate, g.term_months))
                                        / power(1 + v_infl / 100, greatest(g.maturity_date - v_today, 0) / 365.0))::bigint)
               order by g.maturity_date, g.id)
        from public.gic_holdings g
       where g.account_id = p_account_id and g.status = 'active'), '[]'::jsonb),
    'funds', coalesce((
      select jsonb_agg(jsonb_build_object('fund', x.id, 'name', x.name,
               'year_change_pct', case when x.then_c is null then null else round((x.now_c / x.then_c - 1) * 100, 2) end)
               order by x.sort_order)
        from (select f.id, f.name, f.sort_order, l.close as now_c,
                     (select fp.close * coalesce((select exp(sum(ln(s.ratio_from::numeric / s.ratio_to))) from public.fund_splits s
                                                   where s.fund_id = f.id and s.split_date > fp.price_date
                                                     and s.split_date <= l.price_date), 1)
                        from public.fund_prices fp
                       where fp.fund_id = f.id and fp.price_date <= (l.price_date - interval '1 year')::date
                       order by fp.price_date desc limit 1) as then_c
                from public.funds f
                cross join lateral (select fp.price_date, fp.close from public.fund_prices fp
                                     where fp.fund_id = f.id and fp.source = 'daily' and fp.price_date <= v_today
                                       and fp.fetched_at >= public.close_time(f.market, fp.price_date)
                                     order by fp.price_date desc limit 1) l
               where public.fund_units(p_account_id, f.id) > 0) x), '[]'::jsonb));
end;
$$;

-- 8. "View as" ----------------------------------------------------------------------------------------------

create or replace function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  r jsonb;
begin
  perform public.require_parent();
  if p_account is null or not exists (select 1 from public.accounts x where x.id = p_account) then
    raise exception 'There''s no account to view.';
  end if;

  case p_read
    when 'account' then
      select jsonb_build_object('account_id', x.id, 'name', x.name, 'is_test', x.is_test)
        into r from public.accounts x where x.id = p_account;
    when 'app_today' then
      r := to_jsonb(public.app_today());
    -- Her Home: the same rows her app reads from these views and her notices.
    when 'balances' then
      select to_jsonb(b) into r from public.account_balances b where b.account_id = p_account;
    when 'home_gics' then
      select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]'::jsonb) into r
        from public.gic_positions g
       where g.account_id = p_account
         and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null));
    when 'unread_notices' then
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                                                   'related_gic_id', n.related_gic_id)
                                order by n.created_at desc, n.id desc), '[]'::jsonb) into r
        from public.notifications n where n.account_id = p_account and n.read_at is null;
    when 'unread_count' then
      r := to_jsonb((select count(*) from public.notifications n where n.account_id = p_account and n.read_at is null));
    when 'figures_updating' then
      r := to_jsonb(public.figures_updating(p_account));
    when 'feature_enabled' then
      r := to_jsonb(public.feature_enabled(a ->> 'p_feature', p_account));
    when 'current_rates' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.current_rates() with ordinality t;
    when 'fund_overview' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.fund_overview(p_account) with ordinality t;
    when 'my_activity' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_activity(p_account, coalesce((a ->> 'p_limit')::integer, 20),
                                (a ->> 'p_before_at')::timestamptz, a ->> 'p_before_key') with ordinality t;
    when 'my_notices' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_notices(p_account, coalesce((a ->> 'p_limit')::integer, 50),
                               (a ->> 'p_before_id')::bigint) with ordinality t;
    when 'my_questions' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_questions(p_account) with ordinality t;
    -- B4: her onboarding and her signed agreements.
    when 'onboarding_state' then
      r := public.onboarding_state(p_account);
    when 'my_agreements' then
      r := public.my_agreements(p_account);
    -- Stage 9: her goal card on Home (never the "Got it" marker).
    when 'kid_goal' then
      r := public.kid_goal(p_account);
    -- Stage 10: her look and her badges.
    when 'kid_look' then
      r := public.kid_look(p_account);
    when 'kid_badges' then
      r := public.kid_badges(p_account);
    -- Stage 11: the learning features, read exactly as she reads them.
    when 'kid_features' then
      r := public.kid_features(p_account);
    when 'kid_view_mode' then
      r := to_jsonb(public.kid_view_mode(p_account));
    when 'kid_statement_months' then
      r := public.kid_statement_months(p_account);
    when 'kid_statement' then
      r := public.kid_statement(p_account, (a ->> 'p_month')::date);
    when 'kid_what_if' then
      r := public.kid_what_if(p_account);
    when 'kid_market_compare' then
      r := public.kid_market_compare(p_account, a ->> 'p_range');
    when 'kid_inflation' then
      r := public.kid_inflation(p_account);
    when 'kid_reflections' then
      r := public.kid_reflections(p_account);
    -- Her Graphs.
    when 'graph_ranges' then
      r := public.graph_ranges(p_account);
    when 'daily_balances' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.daily_balances(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'growth_by_option' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.growth_by_option(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'money_in_vs_earned' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.money_in_vs_earned(p_account) with ordinality t;
    when 'my_mix' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_mix(p_account) with ordinality t;
    when 'gic_ladder' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.gic_ladder(p_account) with ordinality t;
    when 'fund_chart' then
      r := public.fund_chart(p_account, a ->> 'p_fund_id', (a ->> 'p_from')::date);
    else
      raise exception 'There''s no "%" to view.', p_read;
  end case;
  return r;
end;
$$;

-- 9. Who may call them -------------------------------------------------------------------------------------

revoke all on function public.kid_save_reflection(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.kid_reflections(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_view_mode(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_features(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_set_view_mode(text) from public, anon, authenticated, service_role;
revoke all on function public.statement_fund_gains(uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function public.statement_figures(uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function public.statement_ready(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.kid_statement_months(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_statement(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.kid_what_if(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_market_compare(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.kid_inflation(uuid) from public, anon, authenticated, service_role;

grant execute on function public.kid_save_reflection(bigint, text) to authenticated;
grant execute on function public.kid_reflections(uuid) to authenticated;
grant execute on function public.kid_view_mode(uuid) to authenticated;
grant execute on function public.kid_features(uuid) to authenticated;
grant execute on function public.kid_set_view_mode(text) to authenticated;
grant execute on function public.kid_statement_months(uuid) to authenticated;
grant execute on function public.kid_statement(uuid, date) to authenticated;
grant execute on function public.kid_what_if(uuid) to authenticated;
grant execute on function public.kid_market_compare(uuid, text) to authenticated;
grant execute on function public.kid_inflation(uuid) to authenticated;
