-- Rate-notice wording and the fund ?s (Dad, 2026-10-19, approving the beta fixes).
--
-- 1. Rate notices say "until it matures", like the special notice (not "finishes"):
--      a savings change: "This doesn't change GIC rates. A GIC keeps the rate it was bought at until it matures."
-- 2. A GIC increase keeps "GICs you already have keep their locked-in rate." and adds what to do:
--      "A 6-month GIC bought from Oct 26 gets 4.5%." ("from today" when it starts today).
--    Like the cut's tip, it's only given when nothing contradicts it: the new rate is what that
--    term really pays on its first day (no special running then), and no other change for that
--    term is already planned after it.
-- Everything else in add_rate_unlogged is exactly as in 20261030000000_rate_notice_tips.sql.
-- Notices already sent keep their words (they're stored when sent).
--
-- 3. The kid screens now call each fund by the real fund it follows ("TSX fund (XIC)"); each of
--    those labels gets a glossary ? saying the price isn't the index's points.
--
-- Known answers: supabase/tests/rate_notice_tips_test.sql.

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
      case
        -- A savings change never changes GIC rates (Dad, 2026-10-19): a true, neutral line, never
        -- a tip to buy a GIC first (it misled on Oct 19, when a 1-month special began the same day).
        when p_vehicle = 'savings' then
          'This doesn''t change GIC rates. A GIC keeps the rate it was bought at until it matures.'
        -- A GIC cut later: buying that term before then keeps today's rate, but only when today's
        -- rate for that term really holds every day until then (no special or other change between).
        when v_effective > v_today and v_old is not null and p_rate < v_old
             and (select count(distinct (public.rate_on('gic', p_gic_term, d::date)).rate)
                    from generate_series(v_today, v_effective - 1, interval '1 day') d) = 1 then
          'Tip: a ' || public.term_label(p_gic_term) || ' GIC bought before ' || public.fmt_date(v_effective)
            || ' keeps today''s ' || public.fmt_rate((public.rate_on('gic', p_gic_term, v_today)).rate) || '.'
        -- A GIC increase (Dad, 2026-10-19): her GICs keep their rate, and a new one gets the new
        -- rate, but only said when nothing contradicts it: that term really pays the new rate on
        -- its first day (no special then), and no other change for that term is planned after it.
        when v_old is not null and p_rate > v_old
             and (public.rate_on('gic', p_gic_term, v_effective)).rate = p_rate
             and not exists (select 1 from public.rates r
                              where r.vehicle = 'gic' and r.gic_term = p_gic_term and r.id <> v_id
                                and case when r.is_special then r.end_date >= v_effective   -- a special then or later
                                         else r.effective_date > v_effective end           -- a later change
                                and not exists (select 1 from public.cancellations c where c.rate_id = r.id)) then
          'GICs you already have keep their locked-in rate. A ' || public.term_label(p_gic_term) || ' GIC bought '
            || case when v_effective = v_today then 'from today' else 'from ' || public.fmt_date(v_effective) end
            || ' gets ' || public.fmt_rate(p_rate) || '.'
        else 'GICs you already have keep their locked-in rate.'
      end);
  end if;

  for v_account in select a.id from public.accounts a loop
    perform public.notify(v_account, 'rate_change', v_title, v_body,
      'rate_change:' || v_id || ':' || v_account, p_rate_id => v_id);
  end loop;
  return v_id;
end;
$$;

-- The fund ?s: the label on the kid screens is the glossary term (src/kid/fundNames.ts).
insert into public.glossary (term, kid_text) values
  ('Dow Jones fund (DIA)',
   'On the news, the Dow Jones is measured in points (about 45,000). Your fund''s price is the price of one unit of DIA, '
   || 'a real fund that follows the Dow Jones. When the Dow Jones goes up 1%, DIA goes up about 1% too. '
   || 'Watch the percent, not the number.'),
  ('Nasdaq-100 fund (QQQ)',
   'On the news, the Nasdaq-100 is measured in points. Your fund''s price is the price of one unit of QQQ, '
   || 'a real fund that follows the Nasdaq-100. When the Nasdaq-100 goes up 1%, QQQ goes up about 1% too. '
   || 'Watch the percent, not the number.'),
  ('TSX fund (XIC)',
   'On the news, the TSX (the S&P/TSX Composite) is measured in points. Your fund''s price is the price of one unit of XIC, '
   || 'a real fund that follows the TSX. When the TSX goes up 1%, XIC goes up about 1% too. '
   || 'Watch the percent, not the number.')
on conflict (term) do nothing;
