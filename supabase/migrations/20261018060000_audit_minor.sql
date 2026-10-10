-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). The minor items.
--
-- 1. Approvals could show no history line for an older question: parent_inbox
--    asked my_activity for 100,000 lines but it always stopped at 200. The
--    200-line cap now applies to the girls' app only; Dad's screens and the
--    server may ask for more.
-- 2. A regular rate change hidden behind a running special told the girls the
--    rate "drops from X to Y today", though the rate they get didn't change. Now
--    the notice says the new rate applies after the special ends.
-- 3. whats_new_seen and whats_new_features also refuse TRUNCATE, like every other
--    append-only table.
-- (The 1,000-row API limit that would have cut off long graph ranges is raised in
-- supabase/config.toml, and on production by hand: docs/RUNBOOK.md.)

-- 1. Her history: the 200-line cap is for the girls' app only ------------------------------------

create or replace function public.my_activity(p_account_id uuid, p_limit integer default 20,
                                   p_before_at timestamptz default null, p_before_key text default null)
returns table (
  item_key text, at timestamptz, on_day date, kind text, request_type text, amount_cents bigint,
  fund_id text, gic_id bigint, gic_term integer, rate numeric, units numeric, unit_price numeric,
  note text, transaction_ids bigint[], request_id bigint, fixes text)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  return query
  with tx as (
    -- The two sides of a move share a posting key apart from the last part
    -- (gic_buy:7:savings and gic_buy:7:gic), so they group into one line.
    select t.*,
           coalesce(regexp_replace(t.posting_key, ':(gic|savings|in|out|fund)$', ''), 'tx:' || t.id) as gkey
      from public.transactions t
     where t.account_id = p_account_id
  ),
  grouped as (
    select tx.gkey,
           max(tx.effective_at) as at,
           case
             when bool_or(tx.type = 'correction') then 'correction'
             when bool_or(tx.type = 'penalty') then 'penalty'
             when bool_or(tx.type = 'deposit') then 'deposit'
             when bool_or(tx.type = 'withdraw') then 'withdraw'
             when bool_or(tx.type = 'dividend') then 'dividend'
             when bool_or(tx.type = 'split_adjust') then 'split'
             when bool_or(tx.type = 'interest' and tx.vehicle = 'gic') then 'gic_interest'
             when bool_or(tx.type = 'interest') then 'interest'
             when tx.gkey like 'gic\_buy:%' then 'gic_buy'
             when tx.gkey like 'gic\_break:%' then 'gic_break'
             when tx.gkey like 'gic\_release:%' then 'gic_to_savings'
             when tx.gkey like 'gic\_renew:%' then 'gic_renew'
             when tx.gkey like 'trade:%' then
               case when bool_or(tx.vehicle = 'stock' and tx.units > 0) then 'fund_buy' else 'fund_sell' end
             else 'other'
           end as kind,
           sum(tx.amount_cents) as net_cents,
           max(abs(tx.amount_cents)) filter (where tx.vehicle = 'savings') as savings_cents,
           max(abs(tx.amount_cents)) as biggest_cents,
           max(tx.fund_id) as fund_id,
           max(tx.gic_id) as gic_id,
           max(abs(tx.units)) filter (where tx.vehicle = 'stock') as units,
           max(tx.unit_price) filter (where tx.vehicle = 'stock') as unit_price,
           (array_agg(tx.note order by (tx.vehicle = 'savings') desc, tx.id) filter (where tx.note is not null))[1] as note,
           array_agg(tx.id order by tx.id) as ids,
           max(tx.request_id) as request_id,
           max(tx.corrects_id) as corrects_id,
           max(tx.corrects_request_id) as corrects_request_id,
           max(tx.question_id) as question_id
      from tx
     group by tx.gkey
  ),
  lines as (
    select g.gkey as item_key, g.at, g.kind, null::text as request_type,
           (case when g.kind = 'correction' then g.net_cents
                 else coalesce(g.savings_cents, g.biggest_cents) end)::bigint as amount_cents,
           g.fund_id, g.gic_id, gh.term_months::integer as gic_term, gh.rate,
           g.units, g.unit_price, g.note, g.ids as transaction_ids, g.request_id,
           g.corrects_id, g.corrects_request_id, g.question_id
      from grouped g
      left join public.gic_holdings gh on gh.id = g.gic_id
    union all
    select 'req:' || r.id, case when r.status = 'pending' then r.created_at else coalesce(r.decided_at, r.created_at) end,
           'request_' || r.status::text,
           case r.type
             when 'move' then case when r.from_vehicle = 'stock' then 'sell' when r.to_vehicle = 'stock' then 'buy' else 'move' end
             else r.type::text
           end,
           r.amount_cents, r.fund_id, r.gic_id, r.gic_term::integer, null::numeric,
           nullif(r.held_units, 0), null::numeric, r.parent_note, null::bigint[], r.id,
           null::bigint, null::bigint, null::bigint
      from public.requests r
     where r.account_id = p_account_id and r.status in ('pending', 'declined', 'expired')
  )
  select l.item_key, l.at, public.edmonton_local(l.at)::date, l.kind, l.request_type, l.amount_cents,
         l.fund_id, l.gic_id, l.gic_term, l.rate, l.units, l.unit_price, l.note, l.transaction_ids, l.request_id,
         case when l.kind = 'correction' then coalesce(
           (select public.line_words(c.kind, c.request_type, c.fund_id, c.gic_term, c.rate, c.note)
                   || ' on ' || public.fmt_date(public.edmonton_local(c.at)::date)
              from lines c
             where (l.corrects_id is not null and l.corrects_id = any (c.transaction_ids))
                or (l.corrects_request_id is not null and c.item_key = 'req:' || l.corrects_request_id)
             limit 1),
           (select 'your question from ' || public.fmt_date(public.edmonton_local(q.created_at)::date)
              from public.questions q where q.id = l.question_id))
         end
    from lines l
   where p_before_at is null or (l.at, l.item_key) < (p_before_at, coalesce(p_before_key, ''))
   order by l.at desc, l.item_key desc
   -- The app shows her history 200 lines at a time at most; Dad's screens (and the server) may ask
   -- for more, so Approvals can always find the line a question is about (pre-launch audit).
   limit least(greatest(coalesce(p_limit, 20), 1),
               case when public.is_parent() or auth.uid() is null then 100000 else 200 end);
end;
$$;

-- 2. A rate change hidden by a running special ------------------------------------------------------

create or replace function public.add_rate_unlogged(p_vehicle public.vehicle, p_gic_term integer, p_rate numeric,
                                                    p_effective_date date default null, p_note text default null,
                                                    p_end_date date default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_effective date := coalesce(p_effective_date, public.app_today() + 7);
  v_note text := public.as_sentence(p_note);
  v_special boolean := p_end_date is not null;
  v_old numeric;
  v_after numeric;
  v_in_force numeric;
  v_special_end date;
  v_label text;
  v_title text;
  v_body text;
  v_id bigint;
  v_account uuid;
begin
  perform public.require_parent();

  if p_vehicle is null or p_vehicle not in ('savings', 'gic') then
    raise exception 'Rates are only for savings and GICs.';
  end if;
  if p_vehicle = 'savings' and p_gic_term is not null then
    raise exception 'The savings rate has no term.';
  end if;
  if p_vehicle = 'gic' and (p_gic_term is null or p_gic_term not in (1, 3, 6, 9, 12, 24)) then
    raise exception 'GIC terms are 1, 3, 6, 9, 12 or 24 months.';
  end if;
  if p_rate is null or p_rate < 0 or p_rate >= 100 then
    raise exception 'A rate must be between 0%% and 99.999%%.';
  end if;
  if p_rate <> round(p_rate, 3) then
    raise exception 'Use at most 3 decimal places (for example 2.125).';
  end if;
  if v_effective < v_today then
    raise exception 'A rate change can''t start in the past: it would change interest already earned.';
  end if;
  if v_special and p_end_date < v_effective then
    raise exception 'A special can''t end before it starts.';
  end if;

  v_old := (public.rate_on(p_vehicle, p_gic_term, v_effective - 1)).rate;

  insert into public.rates (vehicle, gic_term, rate, effective_date, end_date, is_special, note, created_by)
  values (p_vehicle, p_gic_term, p_rate, v_effective, p_end_date, v_special, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  v_label := case when p_vehicle = 'savings' then 'Savings rate' else public.term_label(p_gic_term) || ' GIC rate' end;
  -- What the girls actually get on the first day: a running special can hide a regular change.
  v_in_force := (public.rate_on(p_vehicle, p_gic_term, v_effective)).rate;
  if not v_special and v_in_force is distinct from p_rate then
    select r.end_date into v_special_end from public.rates r
     where r.is_special and r.vehicle = p_vehicle and r.gic_term is not distinct from p_gic_term
       and r.effective_date <= v_effective and r.end_date >= v_effective
       and not exists (select 1 from public.cancellations c where c.rate_id = r.id)
     order by r.id desc limit 1;
  end if;

  if v_special then
    v_after := (public.rate_on(p_vehicle, p_gic_term, p_end_date + 1)).rate;
    v_title := 'Special: '
      || case when p_vehicle = 'savings' then 'savings' else public.term_label(p_gic_term) || ' GICs' end
      || ' at ' || public.fmt_rate(p_rate) || ' from ' || public.fmt_date(v_effective) || ' to ' || public.fmt_date(p_end_date);
    v_body := concat_ws(' ', v_note,
      'After ' || public.fmt_date(p_end_date) || ' the rate goes back to ' || public.fmt_rate(v_after) || '.',
      case when p_vehicle = 'gic' then 'A GIC bought during the special keeps ' || public.fmt_rate(p_rate) || ' until it matures.' end);
  elsif v_special_end is not null then
    -- Hidden behind a running special: nothing changes for her until it ends.
    v_title := v_label || ' after the special: ' || public.fmt_rate(p_rate);
    v_body := concat_ws(' ', v_note,
      'The special at ' || public.fmt_rate(v_in_force) || ' keeps going until ' || public.fmt_date(v_special_end)
        || '. After that, the rate will be ' || public.fmt_rate(p_rate) || '.',
      case when p_vehicle = 'gic' then 'GICs you already have keep their locked-in rate.' end);
  else
    v_title := v_label || ' '
      || case when v_old is null or p_rate = v_old then 'is ' || public.fmt_rate(p_rate)
              when p_rate < v_old then 'drops from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(p_rate)
              else 'goes up from ' || public.fmt_rate(v_old) || ' to ' || public.fmt_rate(p_rate) end
      || case when v_effective = v_today then ' today' else ' on ' || public.fmt_date(v_effective) end;
    v_body := concat_ws(' ', v_note,
      case when v_effective > v_today and v_old is not null and p_rate < v_old then
             case when p_vehicle = 'savings' then 'Tip: GICs bought before then keep today''s rates.'
                  else 'Tip: a GIC bought before then keeps today''s rate.' end
           when p_vehicle = 'gic' then 'GICs you already have keep their locked-in rate.' end);
  end if;

  for v_account in select a.id from public.accounts a loop
    perform public.notify(v_account, 'rate_change', v_title, v_body,
      'rate_change:' || v_id || ':' || v_account, p_rate_id => v_id);
  end loop;
  return v_id;
end;
$$;

-- 3. TRUNCATE, refused like the rest ---------------------------------------------------------------

create trigger whats_new_seen_no_truncate before truncate on public.whats_new_seen
  for each statement execute function public.reject_append_only_change();
create trigger whats_new_features_no_truncate before truncate on public.whats_new_features
  for each statement execute function public.reject_append_only_change();

revoke all on function public.add_rate_unlogged(public.vehicle, integer, numeric, date, text, date)
  from public, anon, authenticated, service_role;
