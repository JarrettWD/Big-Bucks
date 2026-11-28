-- Stage 12 block 1, item 5: fixed trades labelled on the Graphs tab (Dad, 2026-11-16;
-- docs/plans/block-1-plan.md, "Item 5").
--
-- "Fix a close" never changes a trade's ledger lines (append-only); it adds correction lines
-- (fix:close:<fund>:<day>:<request>, plus :money or :dividends) and corrects the stored close.
-- fund_chart read only the original lines, so a fixed trade's label kept the old price, and a
-- fixed sale of everything left out the money the fix added.
--
-- This version of the read-only fund_chart gives each trade a "fixed" tag:
--   * 'fixed': the fix added units or money for this trade. The label shows the fixed close; a buy
--     shows its units with the added ones; a sale shows the units it really used and the money it
--     should have paid: ceil(units × fixed close), never less than she got (the same sums as
--     close_fix_adjustments). The interest added with the money isn't part of the sale.
--   * 'kept': the close was fixed but the fix changed nothing for her (the old close was in her
--     favour): the price she got.
--   * null: the close was never fixed (a fix that only confirmed the same close doesn't count).
-- Everything else in fund_chart is unchanged. No money function, table or nightly change.
-- Also one glossary entry for the label's ?, which Dad can edit in Settings → ? explanations.

-- fund_chart: from 20261010000000_graphs.sql (1 change: each trade's fixed price and tag).
create or replace function public.fund_chart(p_account_id uuid, p_fund_id text, p_from date)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_first numeric;
  v_last numeric;
  v_growth record;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.funds f where f.id = p_fund_id) then
    raise exception 'There''s no fund called %.', coalesce(p_fund_id, 'that');
  end if;
  if p_from is null or p_from > v_today or v_today - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  select fp.close into v_first from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today order by fp.price_date limit 1;
  select fp.close into v_last from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today order by fp.price_date desc limit 1;

  -- Her growth in this fund over the range: the same time-weighted measure as the growth graph.
  select g.growth_pct, g.earned_cents into v_growth
    from public.growth_by_option(p_account_id, p_from, v_today) g
   where g.option = p_fund_id
   order by g.day desc limit 1;

  return jsonb_build_object(
    'fund_id', p_fund_id,
    'from', p_from,
    'today', v_today,
    -- Each close in the range, with its change since the range's first close.
    'closes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'd', fp.price_date,
               'c', trim_scale(fp.close),
               'pct', round((fp.close - v_first) * 100 / v_first, 2)) order by fp.price_date), '[]'::jsonb)
        from public.fund_prices fp
       where fp.fund_id = p_fund_id and fp.price_date between p_from and v_today),
    'change_pct', case when v_first > 0 then round((v_last - v_first) * 100 / v_first, 2) end,
    -- Her buys and sells: the day, the price, units, and the money (paid, or received), as fixed
    -- by "Fix a close" if it was, with the tag saying so.
    'trades', (
      -- (jsonb_strip_nulls: a trade at a close never fixed looks exactly as before.)
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'd', x.d,
               'side', x.side,
               'price', trim_scale(case when x.fix_lines > 0 then x.fixed_close else x.unit_price end),
               'units', trim_scale(x.units_now),
               'amount_cents', case when x.fix_lines > 0 and x.side = 'sell'
                                    then greatest(ceil(x.units_now * x.fixed_close * 100)::bigint, x.got_cents)
                                    else x.got_cents end,
               'fixed', case when x.fix_lines > 0 then 'fixed' when x.corrected then 'kept' end))
               order by x.at, x.id), '[]'::jsonb)
        from (
          select s.id, s.effective_at as at, y.d,
                 case when s.type = 'transfer_in' then 'buy' else 'sell' end as side,
                 s.unit_price, abs(sv.amount_cents) as got_cents,
                 -- A buy's added units, or a sale's units put back.
                 abs(s.units) + case when s.type = 'transfer_in' then 1 else -1 end * coalesce(fx.units, 0) as units_now,
                 coalesce(fx.lines, 0) as fix_lines,
                 (select fp.close from public.fund_prices fp
                   where fp.fund_id = s.fund_id and fp.price_date = y.d) as fixed_close,
                 exists (select 1 from public.fund_price_corrections c
                          where c.fund_id = s.fund_id and c.price_date = y.d and c.new_close <> c.old_close) as corrected
            from public.transactions s
            join public.transactions sv
              on sv.request_id = s.request_id and sv.vehicle = 'savings' and sv.account_id = s.account_id
            cross join lateral (select public.edmonton_local(s.effective_at)::date as d) y
            cross join lateral (
              select count(*) as lines, sum(f.units) filter (where f.vehicle = 'stock') as units
                from public.transactions f
               where f.account_id = s.account_id and f.type = 'correction'
                 and (f.posting_key = 'fix:close:' || s.fund_id || ':' || y.d || ':' || s.request_id
                      or f.posting_key like 'fix:close:' || s.fund_id || ':' || y.d || ':' || s.request_id || ':%')) fx
           where s.account_id = p_account_id and s.fund_id = p_fund_id and s.vehicle = 'stock'
             and s.type in ('transfer_in', 'transfer_out')
             and s.effective_at >= public.edmonton_start(p_from)
             and s.effective_at < public.edmonton_start(v_today + 1)) x),
    -- The market-move notes for this fund in the range.
    'notes', (
      select coalesce(jsonb_agg(jsonb_build_object('d', n.note_date, 'body', n.body) order by n.note_date, n.id),
                      '[]'::jsonb)
        from public.notes n
       where n.audience = 'kids' and n.fund_id = p_fund_id and n.note_date between p_from and v_today),
    -- Her return in the range (time-weighted, with dividends), or null if she held none of it.
    'range_growth_pct', v_growth.growth_pct,
    'range_earned_cents', v_growth.earned_cents,
    -- What she holds now: gain against what she paid for the units she holds (the
    -- "since first purchase" figure, the same as Home's).
    'holding', (
      select jsonb_build_object('units', trim_scale(fp.units), 'value_cents', fp.value_cents,
                                'cost_cents', fp.cost_cents, 'gain_cents', fp.gain_cents,
                                'return_pct', fp.return_pct)
        from public.fund_positions fp
       where fp.account_id = p_account_id and fp.fund_id = p_fund_id and fp.units > 0));
end;
$$;

comment on function public.fund_chart(uuid, text, date) is
  'A fund''s closes since a date (each with its % change), her buys and sells (as fixed by "Fix a close", tagged), its market-move notes, her growth in the range and what she holds now.';

revoke all on function public.fund_chart(uuid, text, date) from public, anon, authenticated, service_role;
grant execute on function public.fund_chart(uuid, text, date) to authenticated, service_role;

-- The label's ? (MESSAGES §10).
insert into public.glossary (term, kid_text) values
  ('Price fixed',
   'The price Big Bucks first used for this day was wrong. Mom and Dad fixed it, and you got everything '
   || 'you were owed. Your notice has the details.')
on conflict (term) do nothing;
