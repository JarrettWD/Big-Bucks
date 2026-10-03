-- Stage 2: the money engine's building blocks.
--
-- Rounding, formatting, dates and market closes, rate and setting lookups, and
-- the notice writer. Helpers that views need are granted to signed-in users
-- (they only read); the rest have no grants and are called only from the
-- SECURITY DEFINER engine functions.

-- Dates and rounding ----------------------------------------------------------------

-- Midnight in Edmonton at the start of a date. "End of day d" is edmonton_start(d + 1).
create function public.edmonton_start(p_date date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select p_date::timestamp at time zone 'America/Edmonton';
$$;

-- Fund units are kept to 8 decimal places.
create function public.round_up_units(p numeric)
returns numeric
language sql immutable
set search_path = ''
as $$
  select (ceil(p * 100000000) / 100000000)::numeric(20,8);
$$;

create function public.round_down_units(p numeric)
returns numeric
language sql immutable
set search_path = ''
as $$
  select (floor(p * 100000000) / 100000000)::numeric(20,8);
$$;

-- GIC interest: principal × locked rate × term months ÷ 12, rounded up to the cent.
-- Rates are percent, so the exact amount in cents is principal × rate × term ÷ 1200.
create function public.gic_interest_cents(p_principal_cents bigint, p_rate numeric, p_term_months integer)
returns bigint
language sql immutable
set search_path = ''
as $$
  select ceil(p_principal_cents * p_rate * p_term_months / 1200)::bigint;
$$;

-- What breaking a GIC on p_as_of would give up: the full-term interest × days held
-- ÷ days in the term, rounded up. For the warning only; nothing is ever posted.
create function public.gic_interest_so_far_cents(
  p_principal_cents bigint, p_rate numeric, p_term_months integer,
  p_start date, p_maturity date, p_as_of date)
returns bigint
language sql immutable
set search_path = ''
as $$
  select ceil(p_principal_cents * p_rate * p_term_months / 1200
              * least(greatest(p_as_of - p_start, 0), p_maturity - p_start)
              / (p_maturity - p_start))::bigint;
$$;

-- Formatting for notices and "How was this calculated?" ---------------------------------

create function public.fmt_money(p_cents numeric)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p_cents < 0 then '-' else '' end
         || '$' || to_char(abs(p_cents) / 100, 'FM999,999,999,990.00');
$$;

-- Four decimal places, for showing the exact amount before rounding ($0.2083).
create function public.fmt_money4(p_cents numeric)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p_cents < 0 then '-' else '' end
         || '$' || to_char(abs(p_cents) / 100, 'FM999,999,999,990.0000');
$$;

-- 2.000 → "2.0%", 2.250 → "2.25%"
create function public.fmt_rate(p numeric)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p = round(p, 1) then to_char(p, 'FM990.0')
              else rtrim(to_char(p, 'FM990.000'), '0') end || '%';
$$;

create function public.fmt_units(p numeric)
returns text
language sql immutable
set search_path = ''
as $$
  select to_char(p, 'FM999999999990.00000000');
$$;

-- "Nov 1"
create function public.fmt_date(p date)
returns text
language sql immutable
set search_path = ''
as $$
  select to_char(p, 'Mon FMDD');
$$;

-- "Oct 6 at 10:00 am", in Edmonton time
create function public.fmt_moment(p timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select to_char(p at time zone 'America/Edmonton', 'Mon FMDD "at" FMHH12:MI am');
$$;

-- 1 → "1-month", 12 → "1-year", 24 → "2-year"
create function public.term_label(p_term integer)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_term when 12 then '1-year' when 24 then '2-year' else p_term || '-month' end;
$$;

-- Ends a sentence with a full stop if it has no ending punctuation.
create function public.as_sentence(p text)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p is null or btrim(p) = '' then null
              when btrim(p) ~ '[.!?]$' then btrim(p)
              else btrim(p) || '.' end;
$$;

-- Rates and settings ----------------------------------------------------------------------

-- The rate on a date: a special covering that date wins; otherwise the latest
-- regular rate effective on or before it. Newest row breaks ties.
create function public.rate_on(p_vehicle public.vehicle, p_gic_term integer, p_date date,
                               out rate numeric, out rate_id bigint)
language sql stable
set search_path = ''
as $$
  select r.rate, r.id
    from public.rates r
   where r.vehicle = p_vehicle
     and r.gic_term is not distinct from p_gic_term
     and r.effective_date <= p_date
     and (not r.is_special or r.end_date >= p_date)
   order by r.is_special desc, r.effective_date desc, r.id desc
   limit 1;
$$;

-- A dated setting's value on a date: the newest row effective on or before it.
create function public.setting_on(p_key text, p_date date)
returns text
language sql stable
set search_path = ''
as $$
  select s.value
    from public.settings s
   where s.key = p_key and s.effective_date <= p_date
   order by s.effective_date desc, s.id desc
   limit 1;
$$;

-- Market days and closes --------------------------------------------------------------------
-- Closes are 4:00 pm Eastern (2:00 pm Edmonton), or the early-close time in
-- market_holidays (1:00 pm Eastern, 11:00 am Edmonton). Dates here are exchange
-- (Eastern) dates.

create function public.is_trading_day(p_market public.market, p_date date)
returns boolean
language sql stable
set search_path = ''
as $$
  select extract(isodow from p_date) < 6
     and not exists (select 1 from public.market_holidays h
                      where h.market = p_market and h.holiday_date = p_date and h.kind = 'closed');
$$;

create function public.close_time(p_market public.market, p_date date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select (p_date + coalesce(
            (select h.closes_at from public.market_holidays h
              where h.market = p_market and h.holiday_date = p_date and h.kind = 'early_close'),
            time '16:00')) at time zone 'America/Toronto';
$$;

-- The first close of this market strictly after a moment. A request at exactly
-- the close waits for the next one.
create function public.next_close(p_market public.market, p_after timestamptz)
returns timestamptz
language plpgsql stable
set search_path = ''
as $$
declare
  v_day date := (p_after at time zone 'America/Toronto')::date;
  v_close timestamptz;
begin
  for i in 0..60 loop
    if public.is_trading_day(p_market, v_day) then
      v_close := public.close_time(p_market, v_day);
      if v_close > p_after then
        return v_close;
      end if;
    end if;
    v_day := v_day + 1;
  end loop;
  raise exception 'No % trading day found in the 60 days after %.', p_market, p_after;
end;
$$;

create function public.first_trading_day_from(p_market public.market, p_date date)
returns date
language plpgsql stable
set search_path = ''
as $$
declare
  v_day date := p_date;
begin
  while not public.is_trading_day(p_market, v_day) loop
    v_day := v_day + 1;
  end loop;
  return v_day;
end;
$$;

create function public.last_trading_day_before(p_market public.market, p_date date)
returns date
language plpgsql stable
set search_path = ''
as $$
declare
  v_day date := p_date - 1;
begin
  while not public.is_trading_day(p_market, v_day) loop
    v_day := v_day - 1;
  end loop;
  return v_day;
end;
$$;

-- Balances (used inside engine functions) ---------------------------------------------------

-- Sum of one vehicle's ledger rows that count before a moment ('infinity' = now and ever).
create function public.vehicle_cents(p_account_id uuid, p_vehicle public.vehicle,
                                     p_before timestamptz default 'infinity')
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(sum(t.amount_cents), 0)::bigint
    from public.transactions t
   where t.account_id = p_account_id and t.vehicle = p_vehicle and t.effective_at < p_before;
$$;

create function public.held_cents(p_account_id uuid)
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(sum(r.held_cents), 0)::bigint
    from public.requests r
   where r.account_id = p_account_id and r.status = 'pending';
$$;

create function public.fund_units(p_account_id uuid, p_fund_id text, p_before timestamptz default 'infinity')
returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce(sum(t.units), 0)
    from public.transactions t
   where t.account_id = p_account_id and t.fund_id = p_fund_id and t.vehicle = 'stock'
     and t.effective_at < p_before;
$$;

create function public.held_units(p_account_id uuid, p_fund_id text)
returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce(sum(r.held_units), 0)
    from public.requests r
   where r.account_id = p_account_id and r.fund_id = p_fund_id
     and r.status = 'pending' and r.from_vehicle = 'stock';
$$;

-- Approved deposits minus approved withdrawals.
create function public.net_deposits_cents(p_account_id uuid)
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(sum(t.amount_cents), 0)::bigint
    from public.transactions t
   where t.account_id = p_account_id and t.type in ('deposit', 'withdraw');
$$;

create function public.pending_deposits_cents(p_account_id uuid)
returns bigint
language sql stable
set search_path = ''
as $$
  select coalesce(sum(r.amount_cents), 0)::bigint
    from public.requests r
   where r.account_id = p_account_id and r.type = 'deposit' and r.status = 'pending';
$$;

-- Callers ------------------------------------------------------------------------------------

-- The calling kid's account, locked for this transaction so two actions from the
-- same account can't race. Anyone else is refused.
create function public.kid_account()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_account uuid := public.my_account_id();
begin
  if v_account is null then
    raise exception 'Only a kid''s account can do this.' using errcode = '42501';
  end if;
  perform 1 from public.accounts a where a.id = v_account for update;
  return v_account;
end;
$$;

create function public.require_parent()
returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if not public.is_parent() then
    raise exception 'Only a parent signed in with the second step (the authenticator code) can do this.'
      using errcode = '42501';
  end if;
end;
$$;

-- Notices -------------------------------------------------------------------------------------

-- Writes one notice. A dedupe key makes it safe to call again: the second call does nothing.
create function public.notify(
  p_account_id uuid, p_type public.notification_type, p_title text, p_body text, p_dedupe_key text,
  p_rate_id bigint default null, p_request_id bigint default null, p_gic_id bigint default null)
returns void
language sql
set search_path = ''
as $$
  insert into public.notifications (account_id, type, title, body, dedupe_key,
                                    related_rate_id, related_request_id, related_gic_id)
  values (p_account_id, p_type, p_title, coalesce(p_body, ''), p_dedupe_key, p_rate_id, p_request_id, p_gic_id)
  on conflict (dedupe_key) do nothing;
$$;

