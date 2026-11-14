-- The price fix, part 6 (Dad's review, 2026-11-14): the dividends a fixed trade's missing units
-- would have earned.
--
-- "Fix a close" adds a buy's missing units (or puts back units a sale by amount gave up too many of).
-- Dad: pay what those units would have earned since the trade day, rounded up, the same
-- "makes her whole" rule as the interest on missing cents. So:
--   1. A dividend paid after the fix counts those units from the trade day: dividend_unit_days counts a
--      "Fix a close" units line from the time of the trade it fixes, for any dividend worked out after
--      the fix (p_as_of).
--   2. A dividend already paid between the trade and the fix: "Fix a close" adds what those units would
--      have earned, rounded up, plus the savings interest on it from the day it was paid, rounded up
--      (close_fix_dividends), as its own correction (fix:close:<fund>:<day>:<request>:dividends). Her
--      notice says "...and the dividends it would have earned".
--   3. Reconcile checks each dividend as it was worked out when paid (p_as_of = its posted_at), so a
--      dividend paid before a fix still checks out.
-- And: a fund that split after the close is refused ("Ask Buck"): the units owed would need the split.

-- 1. Units held each day, as of a moment ------------------------------------------------------------

-- dividend_unit_days: from 20261018020000_audit_jobs.sql, with p_as_of (a "Fix a close" units line
-- posted by then counts from its trade's time) and optional extra units from a day (what a fix would add).
create function public.dividend_unit_days(p_account uuid, p_fund text, p_qstart date, p_qend date, p_last date,
                                          p_as_of timestamptz, p_extra_units numeric, p_extra_from date,
                                          out unit_days_x_den numeric, out den bigint, out days_held integer)
language plpgsql stable
set search_path = ''
as $$
declare
  v_splits public.fund_splits[];
  v_s public.fund_splits;
  v_day date;
  v_mult bigint;
  v_units numeric;
begin
  select coalesce(array_agg(s order by s.split_date), '{}') into v_splits from public.fund_splits s
   where s.fund_id = p_fund and s.split_date > p_qstart and s.split_date <= p_last;
  den := 1;
  foreach v_s in array v_splits loop
    den := den * v_s.ratio_from;
  end loop;
  unit_days_x_den := 0;
  days_held := 0;
  for v_day in select d::date from generate_series(p_qstart, p_qend, interval '1 day') d loop
    -- Splits after this day: their "to" side; splits on or before it: their "from" side.
    v_mult := 1;
    foreach v_s in array v_splits loop
      v_mult := v_mult * case when v_s.split_date > v_day then v_s.ratio_to else v_s.ratio_from end;
    end loop;
    select coalesce(sum(t.units), 0) into v_units from public.transactions t
     where t.account_id = p_account and t.fund_id = p_fund and t.vehicle = 'stock'
       and case when t.type = 'correction' and t.posting_key like 'fix:close:%' and t.posted_at <= p_as_of
                then coalesce((select c.effective_at from public.transactions c where c.id = t.corrects_id), t.effective_at)
                else t.effective_at end < public.edmonton_start(v_day + 1);
    if p_extra_from is not null and v_day >= p_extra_from then
      v_units := v_units + coalesce(p_extra_units, 0);
    end if;
    unit_days_x_den := unit_days_x_den + v_mult * v_units;
    if v_units > 0 then
      days_held := days_held + 1;
    end if;
  end loop;
end;
$$;

-- The five-argument version (pay_quarterly_dividends): as of now.
create or replace function public.dividend_unit_days(p_account uuid, p_fund text, p_qstart date, p_qend date, p_last date,
                                                     out unit_days_x_den numeric, out den bigint, out days_held integer)
language sql stable
set search_path = ''
as $$
  select x.unit_days_x_den, x.den, x.days_held
    from public.dividend_unit_days(p_account, p_fund, p_qstart, p_qend, p_last, public.app_now(), 0, null) x;
$$;

-- 2. What the missing units would have earned -------------------------------------------------------

-- For p_extra units she should have held from p_from: each dividend of this fund already paid for a
-- quarter ending on or after p_from, worked out again with them (at the close it was paid at), less
-- what she got, rounded up; plus the savings interest on it from the day it was paid to the fix.
create function public.close_fix_dividends(p_account uuid, p_fund text, p_extra numeric, p_from date,
                                           out cents bigint, out interest_cents bigint, out words text)
language plpgsql stable
set search_path = ''
as $$
declare
  v_market public.market;
  v_to date := public.edmonton_local(public.savings_moment(public.app_now()))::date - 1;
  v_d record;
  v_qstart date;
  v_qfrom date;
  v_last date;
  v_days integer;
  v_yield numeric;
  v_old record;
  v_new record;
  v_close numeric;
  v_amount bigint;
  v_miss bigint;
  v_exact numeric;
  v_int bigint;
  v_paid_on date;
begin
  cents := 0;
  interest_cents := 0;
  if coalesce(p_extra, 0) <= 0 then
    return;
  end if;
  select f.market into v_market from public.funds f where f.id = p_fund;
  for v_d in
    select t.* from public.transactions t
     where t.account_id = p_account and t.fund_id = p_fund and t.type = 'dividend'
       and t.posting_key = 'dividend:' || split_part(t.posting_key, ':', 2) || ':' || p_fund || ':' || p_account
     order by t.id
  loop
    v_qstart := public.dividend_quarter_start(v_d.posting_key);
    continue when v_qstart - 1 < p_from;
    v_qfrom := (v_qstart - interval '3 months')::date;
    v_days := v_qstart - v_qfrom;
    v_last := public.last_trading_day_before(v_market, v_qstart);
    v_yield := coalesce(public.setting_on('dividend_yield:' || p_fund,
                                          public.first_trading_day_from(v_market, v_qstart))::numeric, 0);
    select * into v_old from public.dividend_unit_days(p_account, p_fund, v_qfrom, v_qstart - 1, v_last,
                                                       v_d.posted_at, 0, null);
    -- The close it was paid at (a later fix of that close has its own correction).
    select c into v_close from public.day_closes(p_fund, v_last) c
     where public.ceil_div(v_old.unit_days_x_den * c * v_yield, 4 * v_days * v_old.den) = v_d.amount_cents
     limit 1;
    v_close := coalesce(v_close, public.final_close(p_fund, v_last));
    continue when v_close is null;
    select * into v_new from public.dividend_unit_days(p_account, p_fund, v_qfrom, v_qstart - 1, v_last,
                                                       v_d.posted_at, p_extra, p_from);
    v_amount := public.ceil_div(v_new.unit_days_x_den * v_close * v_yield, 4 * v_days * v_new.den);
    v_miss := v_amount - v_d.amount_cents;
    continue when v_miss <= 0;
    v_paid_on := public.edmonton_local(v_d.effective_at)::date;
    v_exact := case when v_to >= v_paid_on then public.late_interest_exact(v_miss, v_paid_on, v_to) else 0 end;
    v_int := ceil(v_exact)::bigint;
    cents := cents + v_miss;
    interest_cents := interest_cents + v_int;
    words := concat_ws(' ', words,
      'Your ' || public.fmt_date(public.first_trading_day_from(v_market, v_qstart)) || ' dividend with those units would have been '
        || public.fmt_money(v_amount) || '; you got ' || public.fmt_money(v_d.amount_cents) || ', so '
        || public.fmt_money(v_miss) || ' was added'
        || case when v_int > 0 then ', with ' || public.fmt_money(v_int) || ' of interest from '
                  || public.fmt_date(v_paid_on) || ' (' || public.fmt_money4(v_exact) || ', rounded up)' else '' end
        || '.');
  end loop;
end;
$$;
comment on function public.close_fix_dividends(uuid, text, numeric, date) is
  'What units "Fix a close" adds would have earned in dividends already paid since the trade, rounded up, with their interest (Dad, 2026-11-14).';

-- 3. close_fix_adjustments: from 20261113010000_close_fix.sql (adds each trade's missing dividends;
--    a dividend from the close is worked out as it was when paid; a split since the close is refused).
create or replace function public.close_fix_adjustments(p_fund_id text, p_date date, p_new_close numeric)
returns setof jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_at timestamptz := public.savings_moment(public.app_now());
  v_to date;
  v_t record;
  v_should numeric;
  v_extra numeric;
  v_cents bigint;
  v_exact numeric;
  v_interest_exact numeric;
  v_interest bigint;
  v_from date;
  v_qstart date;
  v_label text;
  v_qfrom date;
  v_days integer;
  v_last date;
  v_yield numeric;
  v_ud record;
  v_new_amount bigint;
  v_old_need numeric;
  v_line text;
  v_div record;
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  v_to := public.edmonton_local(v_at)::date - 1;
  -- A split since the close would change the units owed: Buck works that one out by hand.
  if exists (select 1 from public.fund_splits s where s.fund_id = p_fund_id and s.split_date > p_date) then
    raise exception 'The % fund split after %, so this fix needs working out by hand. Ask Buck.',
      v_fund.name, public.fmt_date(p_date);
  end if;
  v_line := 'The ' || v_fund.name || ' close for ' || public.fmt_date(p_date) || ' was fixed to '
            || public.fmt_money(p_new_close * 100) || '. ';

  -- Trades that settled at this close.
  for v_t in
    select r.id as request_id, r.account_id, r.amount_cents, r.sell_all, r.to_vehicle,
           fl.id as fund_line, fl.units, fl.unit_price, sl.id as savings_line, sl.amount_cents as savings_cents,
           sl.effective_at as savings_at
      from public.transactions fl
      join public.requests r on r.id = fl.request_id
      join public.transactions sl on sl.posting_key = 'trade:' || r.id || ':savings'
     where fl.fund_id = p_fund_id and fl.vehicle = 'stock' and fl.posting_key = 'trade:' || r.id || ':fund'
       and fl.effective_at = public.close_time(v_fund.market, p_date)
     order by r.id
  loop
    if v_t.to_vehicle = 'stock' then
      -- A buy: units = amount ÷ close, rounded up.
      v_should := round(public.round_up_units(v_t.amount_cents / 100.0 / p_new_close), 8);
      v_extra := v_should - v_t.units;
      if v_extra <= 0 then
        return next jsonb_build_object('kind', 'no_change', 'side', 'buy', 'account_id', v_t.account_id,
          'request_id', v_t.request_id, 'got_units', v_t.units, 'should_units', v_should,
          'words', 'No change: this one was in her favour.');
        continue;
      end if;
      select * into v_div from public.close_fix_dividends(v_t.account_id, p_fund_id, v_extra, p_date);
      return next jsonb_build_object('kind', 'buy', 'side', 'buy', 'account_id', v_t.account_id,
        'request_id', v_t.request_id, 'line_id', v_t.fund_line, 'vehicle', 'stock',
        'got_units', v_t.units, 'should_units', v_should, 'extra_units', v_extra, 'cents', 0, 'interest_cents', 0,
        'dividend_cents', v_div.cents, 'dividend_interest_cents', v_div.interest_cents,
        'worth', public.fix_worth_words(v_extra * p_new_close * 100 + v_div.cents + v_div.interest_cents),
        'words', 'Adds ' || public.fmt_units(v_extra) || ' units'
                   || case when v_div.cents > 0 then ' and the dividends they would have earned ('
                             || public.fix_cents_words(v_div.cents + v_div.interest_cents) || ')' else '' end || ', '
                   || public.fix_worth_words(v_extra * p_new_close * 100 + v_div.cents + v_div.interest_cents) || '.',
        'note', v_line || public.fmt_money(v_t.amount_cents) || ' ÷ ' || public.fmt_money(p_new_close * 100) || ' = '
                  || public.fmt_units(v_should) || ' units, rounded up; you got ' || public.fmt_units(v_t.units)
                  || ', so ' || public.fmt_units(v_extra) || ' more units were added.' || coalesce(' ' || v_div.words, ''));
      continue;
    end if;

    -- A sale. Too high a close was in her favour.
    if p_new_close <= v_t.unit_price then
      return next jsonb_build_object('kind', 'no_change', 'side', 'sell', 'account_id', v_t.account_id,
        'request_id', v_t.request_id, 'words', 'No change: this one was in her favour.');
      continue;
    end if;
    v_from := public.edmonton_local(v_t.savings_at)::date;
    v_old_need := case when v_t.sell_all then null
                       else public.round_down_units(v_t.amount_cents / 100.0 / v_t.unit_price) end;

    if not v_t.sell_all and v_old_need <= -v_t.units then
      -- By amount: she should have given up fewer units.
      v_should := round(public.round_down_units(v_t.amount_cents / 100.0 / p_new_close), 8);
      v_extra := -v_t.units - v_should;
      v_cents := greatest(ceil(v_should * p_new_close * 100)::bigint - v_t.savings_cents, 0);
      v_interest_exact := case when v_cents > 0 and v_to >= v_from then public.late_interest_exact(v_cents, v_from, v_to) else 0 end;
      v_interest := ceil(v_interest_exact)::bigint;
      if v_extra <= 0 and v_cents = 0 then
        return next jsonb_build_object('kind', 'no_change', 'side', 'sell', 'account_id', v_t.account_id,
          'request_id', v_t.request_id, 'words', 'No change: this one was in her favour.');
        continue;
      end if;
      select * into v_div from public.close_fix_dividends(v_t.account_id, p_fund_id, greatest(v_extra, 0), p_date);
      return next jsonb_build_object('kind', 'sale', 'side', 'sell', 'account_id', v_t.account_id,
        'request_id', v_t.request_id, 'line_id', v_t.fund_line, 'savings_line', v_t.savings_line, 'vehicle', 'stock',
        'got_units', -v_t.units, 'should_units', v_should, 'extra_units', greatest(v_extra, 0),
        'cents', v_cents, 'interest_cents', v_interest,
        'dividend_cents', v_div.cents, 'dividend_interest_cents', v_div.interest_cents,
        'worth', public.fix_worth_words(greatest(v_extra, 0) * p_new_close * 100 + v_cents + v_interest
                                        + v_div.cents + v_div.interest_cents),
        'words', 'Puts back ' || public.fmt_units(greatest(v_extra, 0)) || ' units'
                   || case when v_cents + v_div.cents > 0
                           then ' and adds ' || public.fix_cents_words(v_cents + v_interest + v_div.cents + v_div.interest_cents)
                           else '' end
                   || ', ' || public.fix_worth_words(greatest(v_extra, 0) * p_new_close * 100 + v_cents + v_interest
                                                     + v_div.cents + v_div.interest_cents) || '.',
        'note', v_line || public.fmt_money(v_t.amount_cents) || ' ÷ ' || public.fmt_money(p_new_close * 100) || ' = '
                  || public.fmt_units(v_should) || ' units, rounded down; your sale used ' || public.fmt_units(-v_t.units)
                  || ', so ' || public.fmt_units(greatest(v_extra, 0)) || ' units were put back.'
                  || case when v_cents > 0 then ' Its money should have been ' || public.fmt_money(v_t.savings_cents + v_cents)
                            || ', so ' || public.fmt_money(v_cents) || ' was added, with '
                            || public.fmt_money(v_interest) || ' of interest.' else '' end
                  || coalesce(' ' || v_div.words, ''));
      continue;
    end if;

    -- Everything (or by amount, but the price had fallen so she sold everything): the missing money.
    v_exact := -v_t.units * p_new_close * 100;
    v_cents := ceil(v_exact)::bigint - v_t.savings_cents;
    if v_cents <= 0 then
      return next jsonb_build_object('kind', 'no_change', 'side', 'sell', 'account_id', v_t.account_id,
        'request_id', v_t.request_id, 'words', 'No change: this one was in her favour.');
      continue;
    end if;
    v_interest_exact := case when v_to >= v_from then public.late_interest_exact(v_cents, v_from, v_to) else 0 end;
    v_interest := ceil(v_interest_exact)::bigint;
    return next jsonb_build_object('kind', 'sale_all', 'side', 'sell', 'account_id', v_t.account_id,
      'request_id', v_t.request_id, 'line_id', v_t.savings_line, 'vehicle', 'savings',
      'got_cents', v_t.savings_cents, 'should_cents', v_t.savings_cents + v_cents,
      'cents', v_cents, 'interest_cents', v_interest,
      'worth', public.fix_cents_words(v_cents + v_interest),
      'words', 'Adds ' || public.fix_cents_words(v_cents + v_interest) || ' (' || public.fix_cents_words(v_cents)
                 || ' missing, plus ' || public.fix_cents_words(v_interest) || ' of interest).',
      'note', v_line || public.fmt_units(-v_t.units) || ' units × ' || public.fmt_money(p_new_close * 100) || ' = '
                || public.fmt_money4(v_exact) || ', rounded up to ' || public.fmt_money(v_t.savings_cents + v_cents)
                || '; you got ' || public.fmt_money(v_t.savings_cents) || ', so ' || public.fmt_money(v_cents)
                || ' was missing.'
                || case when v_interest > 0 then ' The interest it would have earned from ' || public.fmt_date(v_from)
                          || ' to ' || public.fmt_date(v_to) || ' at the savings rate: ' || public.fmt_money4(v_interest_exact)
                          || ', rounded up to ' || public.fmt_money(v_interest) || '.' else '' end);
  end loop;

  -- Dividends paid from this close: it's a quarter's last close and that quarter's dividend is paid.
  v_qstart := (date_trunc('quarter', p_date) + interval '3 months')::date;
  if p_date = public.last_trading_day_before(v_fund.market, v_qstart) then
    v_label := to_char(v_qstart, 'YYYY') || 'Q' || extract(quarter from v_qstart);
    v_qfrom := (v_qstart - interval '3 months')::date;
    v_days := v_qstart - v_qfrom;
    v_last := p_date;
    v_yield := coalesce(public.setting_on('dividend_yield:' || p_fund_id,
                                          public.first_trading_day_from(v_fund.market, v_qstart))::numeric, 0);
    for v_t in
      select t.id, t.account_id, t.amount_cents, t.effective_at, t.posted_at from public.transactions t
       where t.type = 'dividend' and t.fund_id = p_fund_id and t.posting_key like 'dividend:' || v_label || ':' || p_fund_id || ':%'
       order by t.id
    loop
      select * into v_ud from public.dividend_unit_days(v_t.account_id, p_fund_id, v_qfrom, v_qstart - 1, v_last,
                                                        v_t.posted_at, 0, null);
      v_new_amount := public.ceil_div(v_ud.unit_days_x_den * p_new_close * v_yield, 4 * v_days * v_ud.den);
      v_cents := v_new_amount - v_t.amount_cents;
      if v_cents <= 0 then
        return next jsonb_build_object('kind', 'no_change', 'side', 'dividend', 'account_id', v_t.account_id,
          'dividend_id', v_t.id, 'words', 'No change: this one was in her favour.');
        continue;
      end if;
      v_from := public.edmonton_local(v_t.effective_at)::date;
      v_interest_exact := case when v_to >= v_from then public.late_interest_exact(v_cents, v_from, v_to) else 0 end;
      v_interest := ceil(v_interest_exact)::bigint;
      return next jsonb_build_object('kind', 'dividend', 'side', 'dividend', 'account_id', v_t.account_id,
        'dividend_id', v_t.id, 'line_id', v_t.id, 'vehicle', 'savings',
        'got_cents', v_t.amount_cents, 'should_cents', v_new_amount, 'cents', v_cents, 'interest_cents', v_interest,
        'worth', public.fix_cents_words(v_cents + v_interest),
        'words', 'Adds ' || public.fix_cents_words(v_cents + v_interest) || ' (' || public.fix_cents_words(v_cents)
                   || ' missing, plus ' || public.fix_cents_words(v_interest) || ' of interest).',
        'note', v_line || 'Your dividend at that close is ' || public.fmt_money(v_new_amount) || '; you got '
                  || public.fmt_money(v_t.amount_cents) || ', so ' || public.fmt_money(v_cents) || ' was missing.'
                  || case when v_interest > 0 then ' The interest it would have earned from ' || public.fmt_date(v_from)
                            || ' to ' || public.fmt_date(v_to) || ' at the savings rate: ' || public.fmt_money4(v_interest_exact)
                            || ', rounded up to ' || public.fmt_money(v_interest) || '.' else '' end);
    end loop;
  end if;
end;
$$;

-- 4. correct_fund_price: from 20261113010000_close_fix.sql (posts the missing dividends; her notice says so).
create or replace function public.correct_fund_price(p_fund_id text, p_date date, p_close numeric, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_prices;
  v_a jsonb;
  v_key text;
  v_at timestamptz := public.savings_moment(public.app_now());
  v_body text;
  v_trades integer := 0;
  v_dividends integer := 0;
  v_same integer := 0;
  v_done jsonb := '[]'::jsonb;
  v_parts text[] := '{}';
  v_head text;
begin
  perform public.require_parent();
  perform pg_advisory_xact_lock(hashtext('close:' || p_fund_id || ':' || p_date));
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  select * into v_old from public.fund_prices fp where fp.fund_id = p_fund_id and fp.price_date = p_date for update;
  if not found then
    raise exception 'There''s no close stored for % on %.', v_fund.name, public.fmt_date(p_date);
  end if;
  if p_close is null or p_close <= 0 or p_close <> round(p_close, 8) then
    raise exception 'A close is a price above $0, with at most 8 decimal places.';
  end if;
  -- The same value confirms a close that isn't final yet.
  if p_close = v_old.close and v_old.fetched_at >= public.close_ready_at(v_fund.market, p_date) then
    raise exception 'That''s the close already stored, and it''s already final.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say where the right close comes from, so the fix explains itself.';
  end if;
  if public.app_now() < public.close_time(v_fund.market, p_date) then
    raise exception 'The market hasn''t closed yet that day, so there''s no final close to type in.';
  end if;
  if public.app_now() < public.close_ready_at(v_fund.market, p_date) then
    raise exception 'The % close for % is confirmed at 9:00 pm Alberta time, so wait until then to fix it.',
      v_fund.name, public.fmt_date(p_date);
  end if;

  -- Everything that used the close, in her favour.
  if p_close <> v_old.close then
    for v_a in select a from public.close_fix_adjustments(p_fund_id, p_date, p_close) a loop
      if v_a ->> 'kind' = 'no_change' then
        v_same := v_same + 1;
        v_done := v_done || v_a;
        continue;
      end if;
      perform 1 from public.accounts ac where ac.id = (v_a ->> 'account_id')::uuid for update;
      v_key := 'fix:close:' || p_fund_id || ':' || p_date || ':'
               || case when v_a ->> 'kind' = 'dividend' then 'dividend:' || (v_a ->> 'account_id')
                       else v_a ->> 'request_id' end;

      if v_a ->> 'vehicle' = 'stock' then
        -- Units, at no cost, on the fund side.
        if (v_a ->> 'extra_units')::numeric > 0 then
          insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units,
                                           posting_key, effective_at, note, corrects_id)
          values ((v_a ->> 'account_id')::uuid, 'stock', p_fund_id, 'correction', 0, (v_a ->> 'extra_units')::numeric,
                  v_key, public.app_now(), v_a ->> 'note', (v_a ->> 'line_id')::bigint);
        end if;
        -- The dividends those units would have earned since the trade (Dad, 2026-11-14).
        if coalesce((v_a ->> 'dividend_cents')::bigint, 0) > 0 then
          insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key,
                                           effective_at, note, corrects_id, counts_as)
          values ((v_a ->> 'account_id')::uuid, 'savings', 'correction',
                  (v_a ->> 'dividend_cents')::bigint + (v_a ->> 'dividend_interest_cents')::bigint,
                  v_key || ':dividends', v_at, v_a ->> 'note', (v_a ->> 'line_id')::bigint, 'earned');
        end if;
        -- And any missing money for a sale by amount.
        if (v_a ->> 'cents')::bigint > 0 then
          insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key,
                                           effective_at, note, corrects_id, counts_as)
          values ((v_a ->> 'account_id')::uuid, 'savings', 'correction',
                  (v_a ->> 'cents')::bigint + (v_a ->> 'interest_cents')::bigint,
                  v_key || ':money', v_at, v_a ->> 'note', (v_a ->> 'savings_line')::bigint, 'earned');
        end if;
      else
        -- Money, with the interest it would have earned, in savings.
        insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key,
                                         effective_at, note, corrects_id, counts_as)
        values ((v_a ->> 'account_id')::uuid, 'savings', 'correction',
                (v_a ->> 'cents')::bigint + (v_a ->> 'interest_cents')::bigint,
                v_key, v_at, v_a ->> 'note', (v_a ->> 'line_id')::bigint, 'earned');
      end if;

      -- Her notice: money first; the units and the working are under "How was this calculated?".
      v_body := 'The ' || v_fund.name || ' fund''s ' || public.fmt_date(p_date) || ' close was really '
                || public.fmt_money(p_close * 100) || ', not ' || public.fmt_money(v_old.close * 100) || ', so your '
                || case v_a ->> 'kind'
                     when 'buy' then 'buy should have got a little more. We added the missing bit'
                                     || case when coalesce((v_a ->> 'dividend_cents')::bigint, 0) > 0
                                             then ' and the dividends it would have earned' else '' end
                                     || ' — ' || (v_a ->> 'worth')
                     when 'sale' then 'sale should have used a little less of your fund. We put the extra back'
                                      || case when coalesce((v_a ->> 'dividend_cents')::bigint, 0) > 0
                                              then ' and the dividends it would have earned' else '' end
                                      || ' — ' || (v_a ->> 'worth')
                     when 'sale_all' then 'sale should have paid a little more. We added the missing money'
                                          || case when (v_a ->> 'interest_cents')::bigint > 0
                                                  then ' and the interest it would have earned' else '' end
                                          || ' — ' || (v_a ->> 'worth')
                     else 'dividend should have been a little more. We added the missing money'
                          || case when (v_a ->> 'interest_cents')::bigint > 0
                                  then ' and the interest it would have earned' else '' end
                          || ' — ' || (v_a ->> 'worth')
                   end
                || '. A fix like this can only add, never take away.';
      perform public.notify((v_a ->> 'account_id')::uuid, 'correction', 'A price was fixed', v_body, v_key,
                            p_request_id => (v_a ->> 'request_id')::bigint);
      if v_a ->> 'kind' = 'dividend' then
        v_dividends := v_dividends + 1;
      else
        v_trades := v_trades + 1;
      end if;
      v_done := v_done || v_a;
    end loop;
  end if;

  insert into public.fund_price_corrections (fund_id, price_date, old_close, new_close, note, corrected_by)
  values (p_fund_id, p_date, v_old.close, p_close, btrim(p_note), auth.uid());
  perform set_config('bigbucks.price_fix', 'on', true);
  update public.fund_prices set close = p_close, fetched_at = public.app_now()
   where fund_id = p_fund_id and price_date = p_date;
  perform set_config('bigbucks.price_fix', '', true);

  if v_trades > 0 then
    v_parts := v_parts || (v_trades || ' trade' || case when v_trades > 1 then 's' else '' end || ' corrected');
  end if;
  if v_dividends > 0 then
    v_parts := v_parts || (v_dividends || ' dividend' || case when v_dividends > 1 then 's' else '' end || ' corrected');
  end if;
  if v_same > 0 then
    v_parts := v_parts || (v_same || ' left as ' || case when v_same > 1 then 'they were' else 'it was' end
                           || ': no change (in her favour)');
  end if;
  v_head := case when p_close = v_old.close then 'Confirmed the ' else 'Fixed the ' end || v_fund.name || ' close for '
            || public.fmt_date(p_date) || ': ' || public.fmt_money4(v_old.close * 100) || ' → '
            || public.fmt_money4(p_close * 100) || '.';
  perform public.log_parent_action('correct_fund_price', null, null,
    v_head || case when cardinality(v_parts) > 0 then ' ' || array_to_string(v_parts, '; ') || '.' else '' end,
    jsonb_build_object('fund_id', p_fund_id, 'price_date', p_date, 'old_close', v_old.close,
                       'new_close', p_close, 'note', btrim(p_note), 'adjustments', v_done));
end;
$$;

-- 5. reconcile_account_core: from 20261113010000_close_fix.sql (each dividend checked as it was worked out when paid).
create or replace function public.reconcile_account_core(p_account uuid, p_date date, p_jobs_done date, p_interest_done date)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_end timestamptz := public.edmonton_start(p_date + 1);
  v_is_today boolean := p_date = public.app_today();
  v_opened date;
  v_problems jsonb := '[]'::jsonb;
  v_savings bigint;
  v_gic bigint;
  v_fund_value bigint := 0;
  v_fund_cost bigint := 0;
  v_cat bigint;
  v_realised bigint := 0;
  v_r record;
  v_g record;
  v_req public.requests;
  v_gh public.gic_holdings;
  v_close numeric;
  v_close_at timestamptz;
  v_expected numeric;
  v_units numeric;
  v_n bigint;
  v_day date;
  v_last date;
  v_qstart date;
  v_yield numeric;
  v_month_from date;
  v_split public.fund_splits;
  v_market public.market;
  v_db record;
  v_view record;
  v_held bigint;
  v_ud record;
  v_days integer;
  v_src public.transactions;
  v_from date;
  v_stock_at timestamptz;
  v_savings_at timestamptz;
begin
  select public.edmonton_local(a.created_at)::date into v_opened from public.accounts a where a.id = p_account;

  -- 1. Nothing negative at the end of the day ---------------------------------
  select coalesce(sum(t.amount_cents), 0) into v_savings from public.transactions t
   where t.account_id = p_account and t.vehicle = 'savings' and t.effective_at < v_end;
  select coalesce(sum(t.amount_cents), 0) into v_gic from public.transactions t
   where t.account_id = p_account and t.vehicle = 'gic' and t.effective_at < v_end;
  if v_savings < 0 then
    v_problems := v_problems || public.recon_problem('negative', 'Savings is below zero.',
      jsonb_build_object('savings_cents', v_savings));
  end if;
  for v_r in
    select t.gic_id, sum(t.amount_cents) as bal from public.transactions t
     where t.account_id = p_account and t.vehicle = 'gic' and t.effective_at < v_end
     group by t.gic_id having sum(t.amount_cents) < 0
  loop
    v_problems := v_problems || public.recon_problem('negative', 'A GIC is below zero.',
      jsonb_build_object('gic_id', v_r.gic_id, 'balance_cents', v_r.bal));
  end loop;

  -- Fund units, cost and value (to the nearest cent, as the screens show it).
  for v_r in
    select t.fund_id, sum(t.units) as units, sum(t.amount_cents)::bigint as cost
      from public.transactions t
     where t.account_id = p_account and t.vehicle = 'stock' and t.effective_at < v_end
     group by t.fund_id
  loop
    if v_r.units < 0 then
      v_problems := v_problems || public.recon_problem('negative', 'A fund has fewer than zero units.',
        jsonb_build_object('fund', v_r.fund_id, 'units', v_r.units));
    end if;
    if v_r.units = 0 and v_r.cost <> 0 then
      v_problems := v_problems || public.recon_problem('fund_cost', 'A fund with no units still has a cost.',
        jsonb_build_object('fund', v_r.fund_id, 'cost_cents', v_r.cost));
    end if;
    select fp.close into v_close from public.fund_prices fp
     where fp.fund_id = v_r.fund_id and fp.price_date <= p_date order by fp.price_date desc limit 1;
    v_fund_value := v_fund_value + coalesce(round(v_r.units * v_close * 100), 0)::bigint;
    v_fund_cost := v_fund_cost + v_r.cost;
  end loop;

  -- 2. Every ledger line explained by its rule, with the right amount ------------
  -- Lines that a correction reverses are settled by that correction, so skip them.
  for v_r in
    select t.* from public.transactions t
     where t.account_id = p_account and t.effective_at < v_end
       and t.type not in ('transfer_in', 'transfer_out')
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
     order by t.id
  loop
    if v_r.type in ('deposit', 'withdraw') then
      select * into v_req from public.requests r where r.id = v_r.request_id;
      if not found or v_req.account_id <> p_account or v_req.type::text <> v_r.type::text
         or v_req.status <> 'approved'
         or v_r.amount_cents <> (case v_r.type when 'deposit' then v_req.amount_cents else -v_req.amount_cents end) then
        v_problems := v_problems || public.recon_problem('posting',
          'A ' || v_r.type || ' line doesn''t match an approved request.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'request_id', v_r.request_id));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'savings' and v_r.posting_key like 'late\_interest:%' then
      -- Interest for money that reached savings late: the line it follows, from the day
      -- it should have counted to the day before it did, at each day's savings rate.
      select * into v_src from public.transactions t
       where t.account_id = p_account and t.vehicle = 'savings'
         and t.posting_key = case when v_r.posting_key like 'late\_interest:trade:%'
                                  then substr(v_r.posting_key, 15) || ':savings'
                                  else substr(v_r.posting_key, 15) end;
      v_from := null;
      if v_src.id is not null and v_src.type = 'dividend' then
        select f.market into v_market from public.funds f where f.id = v_src.fund_id;
        v_from := public.first_trading_day_from(v_market, public.dividend_quarter_start(v_src.posting_key));
      elsif v_src.id is not null then
        select * into v_req from public.requests r where r.id = v_src.request_id;
        select f.market into v_market from public.funds f where f.id = v_req.fund_id;
        v_from := public.edmonton_local(public.next_close(v_market, v_req.created_at))::date;
      end if;
      v_expected := case when v_from is not null
                         then ceil(public.late_interest_exact(v_src.amount_cents, v_from,
                                                              public.edmonton_local(v_src.effective_at)::date - 1)) end;
      if v_src.id is null or v_r.effective_at <> v_src.effective_at or v_expected is null
         or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A late-money interest line isn''t the interest that money missed, rounded up.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'savings' then
      v_day := public.edmonton_local(v_r.effective_at)::date;
      v_month_from := (v_day - interval '1 month')::date;
      select ceil(coalesce(sum(ia.accrued), 0)) into v_expected from public.interest_accruals ia
       where ia.account_id = p_account and ia.accrual_date >= v_month_from and ia.accrual_date < v_day;
      if extract(day from v_day) <> 1 or v_r.effective_at <> public.edmonton_start(v_day)
         or v_r.posting_key is distinct from 'interest:' || to_char(v_month_from, 'YYYY-MM') || ':' || p_account
         or v_r.amount_cents <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A savings interest line isn''t last month''s accruals rounded up.',
          jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents, 'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'interest' and v_r.vehicle = 'gic' then
      select * into v_gh from public.gic_holdings g where g.id = v_r.gic_id;
      v_expected := ceil(v_gh.principal_cents * v_gh.rate * v_gh.term_months / 1200);
      if v_gh.account_id <> p_account or v_gh.status = 'broken' or v_r.amount_cents <> v_expected
         or v_r.effective_at <> public.edmonton_start(v_gh.maturity_date)
         or (select count(*) from public.transactions x
              where x.gic_id = v_r.gic_id and x.vehicle = 'gic' and x.type = 'interest') <> 1 then
        v_problems := v_problems || public.recon_problem('posting',
          'A GIC interest line isn''t principal × rate × term ÷ 12, rounded up, on its maturity date.',
          jsonb_build_object('transaction_id', v_r.id, 'gic_id', v_r.gic_id, 'amount_cents', v_r.amount_cents,
                             'expected_cents', v_expected));
      end if;

    elsif v_r.type = 'dividend' then
      -- The quarter comes from the posting key (dividend:2027Q1:dow:<account>): it's paid
      -- on that quarter's first trading day, or later if the close came late.
      select f.market into v_market from public.funds f where f.id = v_r.fund_id;
      v_qstart := public.dividend_quarter_start(v_r.posting_key);
      v_day := public.first_trading_day_from(v_market, v_qstart);
      v_last := public.last_trading_day_before(v_market, v_qstart);
      v_close := public.final_close(v_r.fund_id, v_last);
      v_yield := coalesce(public.setting_on('dividend_yield:' || v_r.fund_id, v_day)::numeric, 0);
      v_days := v_qstart - (v_qstart - interval '3 months')::date;
      select * into v_ud from public.dividend_unit_days(p_account, v_r.fund_id, (v_qstart - interval '3 months')::date,
                                                        v_qstart - 1, v_last, v_r.posted_at, 0, null);
      v_expected := case when v_close is not null
                         then public.ceil_div(v_ud.unit_days_x_den * v_close * v_yield, 4 * v_days * v_ud.den) end;
      if v_r.posting_key is distinct from
            'dividend:' || to_char(v_qstart, 'YYYY') || 'Q' || extract(quarter from v_qstart) || ':' || v_r.fund_id || ':' || p_account
         or v_r.effective_at < public.edmonton_start(v_day)
         or (v_r.effective_at > public.edmonton_start(v_day)
             and v_r.effective_at <> public.edmonton_start(public.edmonton_local(v_r.effective_at)::date))
         or v_expected is null
         or not exists (select 1 from public.day_closes(v_r.fund_id, v_last) c
                         where public.ceil_div(v_ud.unit_days_x_den * c * v_yield, 4 * v_days * v_ud.den) = v_r.amount_cents) then
        v_problems := v_problems || public.recon_problem('posting',
          'A dividend line isn''t the units held each day ÷ the quarter''s days × close × yield ÷ 4, rounded up, '
            || 'on the quarter''s first trading day.',
          jsonb_build_object('transaction_id', v_r.id, 'fund', v_r.fund_id, 'amount_cents', v_r.amount_cents,
                             'expected_cents', v_expected));
      elsif v_r.effective_at > public.edmonton_start(v_day) and not exists (
              select 1 from public.transactions x where x.posting_key = 'late_interest:' || v_r.posting_key)
            and ceil(public.late_interest_exact(v_r.amount_cents, v_day,
                                                public.edmonton_local(v_r.effective_at)::date - 1)) > 0 then
        v_problems := v_problems || public.recon_problem('posting',
          'A dividend reached savings late without the interest it missed.',
          jsonb_build_object('transaction_id', v_r.id));
      end if;

    elsif v_r.type = 'split_adjust' then
      v_day := public.edmonton_local(v_r.effective_at)::date;
      select * into v_split from public.fund_splits s where s.fund_id = v_r.fund_id and s.split_date = v_day;
      select coalesce(sum(t.units), 0) into v_units from public.transactions t
       where t.account_id = p_account and t.fund_id = v_r.fund_id and t.vehicle = 'stock' and t.effective_at < v_r.effective_at;
      v_expected := ceil(v_units * v_split.ratio_to / v_split.ratio_from * 100000000) / 100000000 - v_units;
      if v_split.fund_id is null or v_r.effective_at <> public.edmonton_start(v_day) or v_r.units <> v_expected then
        v_problems := v_problems || public.recon_problem('posting',
          'A split line doesn''t scale her units by the split ratio.',
          jsonb_build_object('transaction_id', v_r.id, 'units', v_r.units, 'expected_units', v_expected));
      end if;

    elsif v_r.type = 'correction' then
      null; -- An open, noted fix (the table insists on the note). Counted in total worth below.

    else
      v_problems := v_problems || public.recon_problem('posting',
        'A ' || v_r.type || ' line has no rule that explains it.',
        jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents));
    end if;
  end loop;

  -- Moves between vehicles come in pairs that share a posting-key stem.
  for v_r in
    select t.* from public.transactions t
     where t.account_id = p_account and t.effective_at < v_end
       and t.type in ('transfer_in', 'transfer_out')
       and (t.posting_key is null
            or split_part(t.posting_key, ':', 1) not in ('gic_buy', 'gic_break', 'gic_release', 'gic_renew', 'trade'))
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
  loop
    v_problems := v_problems || public.recon_problem('posting', 'A move line has no rule that explains it.',
      jsonb_build_object('transaction_id', v_r.id, 'amount_cents', v_r.amount_cents));
  end loop;

  for v_g in
    select split_part(t.posting_key, ':', 1) as kind, split_part(t.posting_key, ':', 2)::bigint as ref,
           count(*) as n, sum(t.amount_cents)::bigint as net,
           count(distinct t.effective_at) as moments, min(t.effective_at) as at,
           min(t.effective_at) filter (where t.vehicle = 'stock') as stock_at,
           min(t.effective_at) filter (where t.vehicle = 'savings') as savings_at,
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'savings'), 0)::bigint as savings_cents,
           coalesce(sum(t.amount_cents) filter (where t.vehicle = 'stock'), 0)::bigint as stock_cents,
           sum(t.units) filter (where t.vehicle = 'stock') as units,
           max(t.unit_price) as unit_price,
           array_agg(t.id order by t.id) as ids
      from public.transactions t
     where t.account_id = p_account
       and t.type in ('transfer_in', 'transfer_out')
       and split_part(t.posting_key, ':', 1) in ('gic_buy', 'gic_break', 'gic_release', 'gic_renew', 'trade')
       and not exists (select 1 from public.transactions c where c.reverses_id = t.id)
     group by 1, 2
    having min(t.effective_at) < v_end
  loop
    if v_g.kind = 'trade' then
      -- A trade's fund side counts from its close; its savings side too, or from a later
      -- Alberta midnight when the close came after that day's interest was worked out.
      select * into v_req from public.requests r where r.id = v_g.ref;
      select f.market into v_market from public.funds f where f.id = v_req.fund_id;
      v_close_at := public.next_close(v_market, v_req.created_at);
      v_close := public.final_close(v_req.fund_id, (v_close_at at time zone 'America/Toronto')::date);
      if v_g.n <> 2 or v_g.stock_at is null or v_g.savings_at is null then
        v_problems := v_problems || public.recon_problem('posting', 'A move isn''t exactly two matching lines.',
          jsonb_build_object('transaction_ids', to_jsonb(v_g.ids)));
        continue;
      end if;
      if v_req.account_id <> p_account or v_req.status <> 'settled' or v_g.stock_at <> v_close_at
         or v_close is null
         or not exists (select 1 from public.day_closes(v_req.fund_id, (v_close_at at time zone 'America/Toronto')::date) c
                         where c = v_g.unit_price)
         or (v_g.savings_at <> v_close_at
             and (v_g.savings_at < v_close_at
                  or v_g.savings_at <> public.edmonton_start(public.edmonton_local(v_g.savings_at)::date))) then
        v_problems := v_problems || public.recon_problem('posting',
          'A trade didn''t settle at its own close.',
          jsonb_build_object('request_id', v_g.ref, 'settled_at', v_g.stock_at, 'expected_at', v_close_at));
      elsif v_req.to_vehicle = 'stock' then
        -- A buy: what she paid leaves savings; units = amount ÷ close, rounded up at 8 places.
        v_expected := ceil(v_req.amount_cents / 100.0 / v_g.unit_price * 100000000) / 100000000;
        if v_g.net <> 0 or v_g.savings_cents <> -v_req.amount_cents or v_g.units <> v_expected then
          v_problems := v_problems || public.recon_problem('posting',
            'A fund buy doesn''t match amount ÷ close.',
            jsonb_build_object('request_id', v_g.ref, 'units', v_g.units, 'expected_units', v_expected));
        end if;
      else
        -- A sale: proceeds = units × close, rounded up. The difference from the cost is her realised gain.
        v_expected := ceil(-v_g.units * v_g.unit_price * 100);
        if v_g.units >= 0 or v_g.savings_cents <> v_expected then
          v_problems := v_problems || public.recon_problem('posting',
            'A fund sale''s proceeds aren''t units × close, rounded up.',
            jsonb_build_object('request_id', v_g.ref, 'proceeds_cents', v_g.savings_cents, 'expected_cents', v_expected));
        elsif v_g.savings_at > v_close_at and not exists (
                select 1 from public.transactions x where x.posting_key = 'late_interest:trade:' || v_g.ref)
              and ceil(public.late_interest_exact(v_g.savings_cents, public.edmonton_local(v_close_at)::date,
                                                  public.edmonton_local(v_g.savings_at)::date - 1)) > 0 then
          v_problems := v_problems || public.recon_problem('posting',
            'A sale''s money reached savings late without the interest it missed.',
            jsonb_build_object('request_id', v_g.ref));
        end if;
        -- Realised gain counts once both sides have happened.
        if v_g.savings_at < v_end then
          v_realised := v_realised + v_g.net;
        end if;
      end if;
      continue;
    end if;

    if v_g.n <> 2 or v_g.moments <> 1 then
      v_problems := v_problems || public.recon_problem('posting', 'A move isn''t exactly two matching lines.',
        jsonb_build_object('transaction_ids', to_jsonb(v_g.ids)));
      continue;
    end if;

    -- GIC moves: the money comes out of one place and into the other, nothing lost.
    select * into v_gh from public.gic_holdings g where g.id = v_g.ref;
    if v_g.net <> 0 or v_gh.account_id <> p_account then
      v_problems := v_problems || public.recon_problem('posting', 'A GIC move doesn''t balance.',
        jsonb_build_object('gic_id', v_g.ref, 'transaction_ids', to_jsonb(v_g.ids)));
      continue;
    end if;
    select coalesce(sum(t.amount_cents), 0) into v_n from public.transactions t
     where t.gic_id = v_g.ref and t.vehicle = 'gic' and t.type = 'interest';
    if (v_g.kind = 'gic_buy' and (v_g.savings_cents <> -v_gh.principal_cents or v_gh.renewed_from_id is not null))
       or (v_g.kind = 'gic_break' and (v_gh.status <> 'broken' or v_g.savings_cents <> v_gh.principal_cents or v_n <> 0))
       or (v_g.kind = 'gic_release' and (v_gh.status <> 'matured' or v_g.savings_cents <> v_gh.principal_cents + v_n
                                         or v_g.at < public.edmonton_start(v_gh.maturity_date)
                                         or v_g.at > public.edmonton_start(v_gh.choice_ends)))
       or (v_g.kind = 'gic_renew' and (v_gh.status <> 'matured'
            or not exists (select 1 from public.gic_holdings n
                            where n.renewed_from_id = v_gh.id and n.principal_cents = v_gh.principal_cents + v_n
                              and exists (select 1 from public.transactions x
                                           where x.gic_id = n.id and x.id = any (v_g.ids) and x.amount_cents = n.principal_cents)))) then
      v_problems := v_problems || public.recon_problem('posting',
        'A GIC ' || replace(v_g.kind, 'gic_', '') || ' moved the wrong amount.',
        jsonb_build_object('gic_id', v_g.ref, 'transaction_ids', to_jsonb(v_g.ids)));
    end if;
  end loop;

  -- 3. Total worth = money in − money out + earnings ---------------------------
  -- Approved deposits − withdrawals + interest + dividends + corrections − penalties
  -- + realised gains (sale proceeds − cost) + unrealised gains (value − cost).
  -- A late trade whose savings side hasn't happened yet by the end of the day: its fund
  -- side has (units and cost in or out), so that cost is counted here until the money
  -- moves (+ what a buy paid, − the cost a sale took out).
  select coalesce(sum(t.amount_cents) filter (where t.type in ('deposit', 'withdraw', 'interest', 'dividend',
                                                                 'penalty', 'correction')), 0)
    into v_cat from public.transactions t
   where t.account_id = p_account and t.effective_at < v_end;
  select coalesce(sum(t.amount_cents), 0) into v_n from public.transactions t
   where t.account_id = p_account and t.vehicle = 'stock' and t.type in ('transfer_in', 'transfer_out')
     and t.posting_key like 'trade:%' and t.effective_at < v_end
     and exists (select 1 from public.transactions s where s.posting_key = split_part(t.posting_key, ':', 1) || ':'
                                                                        || split_part(t.posting_key, ':', 2) || ':savings'
                                                       and s.effective_at >= v_end);
  if v_cat + v_realised + (v_fund_value - v_fund_cost) + v_n <> v_savings + v_gic + v_fund_value then
    v_problems := v_problems || public.recon_problem('worth',
      'Total worth doesn''t equal money in − money out + earnings.',
      jsonb_build_object('by_vehicle_cents', v_savings + v_gic + v_fund_value,
                         'by_source_cents', v_cat + v_realised + (v_fund_value - v_fund_cost) + v_n));
  end if;

  -- 4. The app's figures match a fresh count -----------------------------------
  select * into v_db from public.daily_balances(p_account, p_date, p_date);
  if v_db.savings_cents <> v_savings or v_db.gic_cents <> v_gic or v_db.stock_cents <> v_fund_value
     or v_db.total_cents <> v_savings + v_gic + v_fund_value then
    v_problems := v_problems || public.recon_problem('app_figures', 'The graph figures don''t match the ledger.',
      jsonb_build_object('shown', to_jsonb(v_db), 'savings_cents', v_savings, 'gic_cents', v_gic,
                         'stock_cents', v_fund_value));
  end if;

  if v_is_today then
    select coalesce(sum(r.held_cents), 0) into v_held from public.requests r
     where r.account_id = p_account and r.status = 'pending';
    select * into v_view from public.account_balances ab where ab.account_id = p_account;
    if v_view.savings_cents <> v_savings or v_view.gic_cents <> v_gic or v_view.stock_value_cents <> v_fund_value
       or v_view.total_worth_cents <> v_savings + v_gic + v_fund_value
       or v_view.held_cents <> v_held or v_view.available_cents <> v_savings - v_held then
      v_problems := v_problems || public.recon_problem('app_figures', 'The balances shown don''t match the ledger.',
        jsonb_build_object('shown', to_jsonb(v_view), 'savings_cents', v_savings, 'gic_cents', v_gic,
                           'stock_cents', v_fund_value, 'held_cents', v_held));
    end if;

    for v_r in
      select fp.fund_id, fp.units, fp.value_cents,
             (select sum(t.units) from public.transactions t
               where t.account_id = p_account and t.fund_id = fp.fund_id and t.vehicle = 'stock') as ledger_units,
             (select round(sum(t.units) * (select p.close from public.fund_prices p
                                            where p.fund_id = fp.fund_id and p.price_date <= p_date
                                            order by p.price_date desc limit 1) * 100)
                from public.transactions t
               where t.account_id = p_account and t.fund_id = fp.fund_id and t.vehicle = 'stock') as ledger_value
        from public.fund_positions fp where fp.account_id = p_account
    loop
      if v_r.units <> v_r.ledger_units or v_r.value_cents <> coalesce(v_r.ledger_value, 0) then
        v_problems := v_problems || public.recon_problem('app_figures', 'A fund holding shown doesn''t match the ledger.',
          jsonb_build_object('fund', v_r.fund_id, 'shown_units', v_r.units, 'ledger_units', v_r.ledger_units,
                             'shown_cents', v_r.value_cents, 'ledger_cents', v_r.ledger_value));
      end if;
    end loop;

    for v_r in
      select gp.gic_id, gp.balance_cents,
             (select coalesce(sum(t.amount_cents), 0) from public.transactions t
               where t.gic_id = gp.gic_id and t.vehicle = 'gic') as ledger
        from public.gic_positions gp where gp.account_id = p_account
    loop
      if v_r.balance_cents <> v_r.ledger then
        v_problems := v_problems || public.recon_problem('app_figures', 'A GIC shown doesn''t match the ledger.',
          jsonb_build_object('gic_id', v_r.gic_id, 'shown_cents', v_r.balance_cents, 'ledger_cents', v_r.ledger));
      end if;
    end loop;

    -- Held money never exceeds what it's held against.
    if v_held > v_savings then
      v_problems := v_problems || public.recon_problem('held', 'More money is held than savings has.',
        jsonb_build_object('held_cents', v_held, 'savings_cents', v_savings));
    end if;
    for v_r in
      select r.fund_id, sum(r.held_units) as held,
             (select coalesce(sum(t.units), 0) from public.transactions t
               where t.account_id = p_account and t.fund_id = r.fund_id and t.vehicle = 'stock') as units
        from public.requests r
       where r.account_id = p_account and r.status = 'pending' and r.from_vehicle = 'stock'
       group by r.fund_id
    loop
      if v_r.held > v_r.units then
        v_problems := v_problems || public.recon_problem('held', 'More fund units are held for sales than she has.',
          jsonb_build_object('fund', v_r.fund_id, 'held_units', v_r.held, 'units', v_r.units));
      end if;
    end loop;
    for v_r in
      select r.id from public.requests r
       where r.account_id = p_account and r.status = 'pending'
         and r.held_cents <> case when r.type = 'withdraw' or r.to_vehicle = 'stock' then r.amount_cents else 0 end
    loop
      v_problems := v_problems || public.recon_problem('held', 'A pending request holds the wrong amount.',
        jsonb_build_object('request_id', v_r.id));
    end loop;
  end if;

  -- 5. Every GIC adds up --------------------------------------------------------
  for v_r in
    select g.*,
           (select coalesce(sum(t.amount_cents), 0) from public.transactions t
             where t.gic_id = g.id and t.vehicle = 'gic' and t.effective_at < v_end) as balance,
           (select coalesce(sum(t.amount_cents), 0) from public.transactions t
             where t.gic_id = g.id and t.vehicle = 'gic' and t.type = 'interest' and t.effective_at < v_end) as interest,
           exists (select 1 from public.transactions t
                    where t.gic_id = g.id and t.vehicle = 'gic' and t.type = 'transfer_in'
                      and t.amount_cents = g.principal_cents) as has_purchase
      from public.gic_holdings g
     where g.account_id = p_account and g.start_date <= p_date
  loop
    if not v_r.has_purchase then
      v_problems := v_problems || public.recon_problem('gic', 'A GIC has no purchase line for its principal.',
        jsonb_build_object('gic_id', v_r.id, 'principal_cents', v_r.principal_cents));
    elsif v_is_today and v_r.balance <> (case
            when v_r.status = 'active' then v_r.principal_cents
            when v_r.status = 'matured' and v_r.maturity_choice is null then v_r.principal_cents + v_r.interest
            else 0 end) then
      v_problems := v_problems || public.recon_problem('gic', 'A GIC''s balance doesn''t match its status.',
        jsonb_build_object('gic_id', v_r.id, 'status', v_r.status, 'balance_cents', v_r.balance));
    end if;
    if v_r.status = 'active' and v_r.maturity_date <= p_jobs_done and v_r.maturity_date <= p_date then
      v_problems := v_problems || public.recon_problem('missed', 'A GIC passed its maturity date without maturing.',
        jsonb_build_object('gic_id', v_r.id, 'maturity_date', v_r.maturity_date));
    end if;
  end loop;

  -- 6. Every day's interest accrual is there and right -------------------------
  -- A line reversed by a correction counts as never having happened, and so does
  -- the correction that reverses it: otherwise a mistake fixed today would leave
  -- every day between the mistake and the fix looking wrong forever.
  for v_r in
    with days as (
      select d::date as day
        from generate_series(v_opened, least(p_date - 1, p_interest_done), interval '1 day') d),
    ledger as (
      select t.* from public.transactions t
       where t.account_id = p_account and t.reverses_id is null
         and not exists (select 1 from public.transactions c where c.reverses_id = t.id)),
    expected as (
      select dd.day,
             (select coalesce(sum(t.amount_cents), 0) from ledger t
               where t.vehicle = 'savings'
                 and t.effective_at < public.edmonton_start(dd.day + 1))::bigint as savings,
             (select coalesce(sum(t.amount_cents), 0) from ledger t
                join public.gic_holdings g on g.id = t.gic_id
               where t.vehicle = 'gic' and g.status = 'matured'
                 and g.maturity_date <= dd.day
                 and t.effective_at < public.edmonton_start(dd.day + 1))::bigint as waiting,
             (select r.rate from public.rate_on('savings', null, dd.day) r) as rate,
             case when extract(doy from make_date(extract(year from dd.day)::int, 12, 31)) = 366
                  then 366 else 365 end as diy
        from days dd)
    select e.*, ia.balance_cents, ia.gic_waiting_cents, ia.rate as row_rate, ia.days_in_year, ia.accrued,
           ia.account_id is not null as has_row
      from expected e
      left join public.interest_accruals ia on ia.account_id = p_account and ia.accrual_date = e.day
     where (e.savings + e.waiting > 0) <> (ia.account_id is not null)
        or (ia.account_id is not null and (
              ia.balance_cents <> e.savings or ia.gic_waiting_cents <> e.waiting or ia.rate <> e.rate
              or ia.days_in_year <> e.diy
              or abs(ia.accrued - (e.savings + e.waiting) * e.rate / 100 / e.diy) > 0.000000001))
     order by e.day
     limit 5
  loop
    v_problems := v_problems || public.recon_problem('accrual',
      case when not v_r.has_row then 'A day''s savings interest is missing.'
           when v_r.savings + v_r.waiting = 0 then 'Interest was accrued on an empty balance.'
           else 'A day''s savings interest was worked out on the wrong balance or rate.' end,
      jsonb_build_object('date', v_r.day, 'expected_balance_cents', v_r.savings + v_r.waiting,
                         'row_balance_cents', coalesce(v_r.balance_cents, 0) + coalesce(v_r.gic_waiting_cents, 0),
                         'accrued', v_r.accrued));
  end loop;

  -- Each finished month with interest earned has its "Interest paid" line.
  for v_r in
    select date_trunc('month', ia.accrual_date)::date as month_from, ceil(sum(ia.accrued)) as due
      from public.interest_accruals ia
     where ia.account_id = p_account
       and (date_trunc('month', ia.accrual_date) + interval '1 month')::date <= least(p_date, p_jobs_done)
     group by 1
    having ceil(sum(ia.accrued)) > 0
  loop
    if not exists (select 1 from public.transactions t
                    where t.posting_key = 'interest:' || to_char(v_r.month_from, 'YYYY-MM') || ':' || p_account) then
      v_problems := v_problems || public.recon_problem('missed', 'A month''s savings interest was never paid.',
        jsonb_build_object('month', to_char(v_r.month_from, 'YYYY-MM'), 'due_cents', v_r.due));
    end if;
  end loop;

  -- 7. No posting key used twice (the table refuses it; this is a second look) --
  for v_r in
    select t.posting_key from public.transactions t
     where t.account_id = p_account and t.posting_key is not null
     group by t.posting_key having count(*) > 1
  loop
    v_problems := v_problems || public.recon_problem('duplicate', 'Something was posted twice.',
      jsonb_build_object('posting_key', v_r.posting_key));
  end loop;

  return v_problems;
end;
$$;

revoke all on function public.dividend_unit_days(uuid, text, date, date, date, timestamptz, numeric, date)
  from public, anon, authenticated, service_role;
revoke all on function public.close_fix_dividends(uuid, text, numeric, date) from public, anon, authenticated, service_role;
