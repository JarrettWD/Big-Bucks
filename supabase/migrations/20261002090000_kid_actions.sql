-- Stage 2: what a kid can do. Each function is one transaction: it checks who is
-- calling (a kid, acting only on her own account), checks the house rules, then
-- writes. Messages are written for a 9-year-old.
--
-- Minimums: $5 for savings (deposits and withdrawals), $10 for GICs and funds.
-- Holds: a withdrawal holds its amount in savings, a fund buy holds its amount,
-- a fund sale holds units. Held money is "pending requests' held_cents".

-- Deposit request: waits for Dad. Holds nothing, but counts toward the cap while pending.
create function public.request_deposit(p_amount_cents bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_cap bigint;
  v_room bigint;
  v_id bigint;
begin
  if p_amount_cents is null or p_amount_cents < 500 then
    raise exception 'The smallest deposit is $5.00.';
  end if;

  v_cap := coalesce(public.setting_on('deposit_cap_cents', public.app_today()), '0')::bigint;
  v_room := greatest(v_cap - public.net_deposits_cents(v_account) - public.pending_deposits_cents(v_account), 0);
  if p_amount_cents > v_room then
    if v_room = 0 then
      raise exception 'You''ve reached the deposit limit of % for now. Money your savings earns doesn''t count toward it.',
        public.fmt_money(v_cap);
    end if;
    raise exception 'That''s over your deposit limit. You can put in up to % more.', public.fmt_money(v_room);
  end if;

  insert into public.requests (account_id, type, to_vehicle, amount_cents)
  values (v_account, 'deposit', 'savings', p_amount_cents)
  returning id into v_id;
  return v_id;
end;
$$;

-- Withdrawal request: from savings only, waits for Dad (24 hours at least), holds the amount.
create function public.request_withdrawal(p_amount_cents bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_available bigint;
  v_id bigint;
begin
  v_available := public.vehicle_cents(v_account, 'savings') - public.held_cents(v_account);
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Choose how much to take out.';
  end if;
  if p_amount_cents > v_available then
    raise exception 'You have % available to take out.', public.fmt_money(v_available);
  end if;
  -- Under $5 is fine only when it empties savings, so a few cents never get stuck.
  if p_amount_cents < 500 and p_amount_cents <> v_available then
    raise exception 'The smallest withdrawal is $5.00, unless you''re taking out everything that''s left.';
  end if;

  insert into public.requests (account_id, type, from_vehicle, amount_cents, held_cents)
  values (v_account, 'withdraw', 'savings', p_amount_cents, p_amount_cents)
  returning id into v_id;
  return v_id;
end;
$$;

-- Buy a GIC from savings, right away, at today's rate for that term (a special included).
create function public.buy_gic(p_amount_cents bigint, p_term_months integer)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_today date := public.app_today();
  v_available bigint;
  v_rate record;
  v_gic bigint;
  v_req bigint;
begin
  if p_term_months is null or p_term_months not in (1, 3, 6, 9, 12, 24) then
    raise exception 'A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.';
  end if;
  if p_amount_cents is null or p_amount_cents < 1000 then
    raise exception 'The smallest GIC is $10.00.';
  end if;
  v_available := public.vehicle_cents(v_account, 'savings') - public.held_cents(v_account);
  if p_amount_cents > v_available then
    raise exception 'You have % available.', public.fmt_money(v_available);
  end if;

  select r.rate, r.rate_id into v_rate from public.rate_on('gic', p_term_months, v_today) r;
  if v_rate.rate is null then
    raise exception 'There is no rate for a % GIC yet.', public.term_label(p_term_months);
  end if;

  insert into public.gic_holdings (account_id, principal_cents, rate, rate_id, term_months, start_date, maturity_date)
  values (v_account, p_amount_cents, v_rate.rate, v_rate.rate_id, p_term_months, v_today,
          (v_today + make_interval(months => p_term_months))::date)
  returning id into v_gic;

  insert into public.requests (account_id, type, from_vehicle, to_vehicle, gic_term, gic_id, amount_cents,
                               status, decided_at, settled_at)
  values (v_account, 'move', 'savings', 'gic', p_term_months, v_gic, p_amount_cents,
          'settled', public.app_now(), public.app_now())
  returning id into v_req;

  insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, request_id, posting_key, note) values
    (v_account, 'savings', v_gic, 'transfer_out', -p_amount_cents, v_req, 'gic_buy:' || v_gic || ':savings',
     'Bought a ' || public.term_label(p_term_months) || ' GIC at ' || public.fmt_rate(v_rate.rate) || '.'),
    (v_account, 'gic', v_gic, 'transfer_in', p_amount_cents, v_req, 'gic_buy:' || v_gic || ':gic',
     'Bought a ' || public.term_label(p_term_months) || ' GIC at ' || public.fmt_rate(v_rate.rate) || '.');
  return v_gic;
end;
$$;

-- Break a GIC early: the whole GIC, principal back to savings, all interest given up.
create function public.break_gic(p_gic_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_today date := public.app_today();
  v_gic public.gic_holdings;
  v_balance bigint;
  v_lost bigint;
  v_note text;
  v_req bigint;
begin
  select * into v_gic from public.gic_holdings g where g.id = p_gic_id for update;
  if not found or v_gic.account_id <> v_account then
    raise exception 'That GIC isn''t yours.' using errcode = '42501';
  end if;
  if v_gic.status <> 'active' then
    raise exception 'This GIC has already %.', case v_gic.status when 'matured' then 'matured' else 'been broken' end;
  end if;
  if v_gic.maturity_date <= v_today then
    raise exception 'This GIC reaches its maturity date today, so you won''t lose any interest. It will be ready to choose soon.';
  end if;

  select coalesce(sum(t.amount_cents), 0) into v_balance
    from public.transactions t where t.gic_id = p_gic_id and t.vehicle = 'gic';
  v_lost := public.gic_interest_so_far_cents(v_gic.principal_cents, v_gic.rate, v_gic.term_months,
                                             v_gic.start_date, v_gic.maturity_date, v_today);
  v_note := 'Broke a ' || public.term_label(v_gic.term_months) || ' GIC early: your '
            || public.fmt_money(v_balance) || ' came back, and the ' || public.fmt_money(v_lost)
            || ' of interest earned so far was given up.';

  update public.gic_holdings set status = 'broken' where id = p_gic_id;

  insert into public.requests (account_id, type, from_vehicle, to_vehicle, gic_id, amount_cents,
                               status, decided_at, settled_at)
  values (v_account, 'move', 'gic', 'savings', p_gic_id, v_balance, 'settled', public.app_now(), public.app_now())
  returning id into v_req;

  insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, request_id, posting_key, note) values
    (v_account, 'gic', p_gic_id, 'transfer_out', -v_balance, v_req, 'gic_break:' || p_gic_id || ':gic', v_note),
    (v_account, 'savings', p_gic_id, 'transfer_in', v_balance, v_req, 'gic_break:' || p_gic_id || ':savings', v_note);
  return v_req;
end;
$$;

-- What happens to a matured GIC: renew (same term, today's rate), a new term, or
-- savings. The whole amount (principal + interest) follows her choice. She has
-- until the start of day 7 after maturity; then the daily job moves it to savings.
create function public.choose_maturity(p_gic_id bigint, p_choice public.maturity_choice, p_new_term integer default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_today date := public.app_today();
  v_gic public.gic_holdings;
  v_amount bigint;
  v_term integer;
  v_rate record;
  v_new bigint;
begin
  select * into v_gic from public.gic_holdings g where g.id = p_gic_id for update;
  if not found or v_gic.account_id <> v_account then
    raise exception 'That GIC isn''t yours.' using errcode = '42501';
  end if;
  if v_gic.status = 'active' then
    raise exception 'This GIC hasn''t matured yet.';
  end if;
  if v_gic.status = 'broken' then
    raise exception 'This GIC was broken early, so there''s nothing to choose.';
  end if;
  if v_gic.maturity_choice is not null then
    raise exception 'You already chose what happens to this GIC.';
  end if;
  if public.app_now() >= public.edmonton_start(v_gic.maturity_date + 7) then
    raise exception 'The 7 days to choose are over, so this money is moving to savings.';
  end if;
  if p_choice is null then
    raise exception 'Choose renew, a new term, or savings.';
  end if;

  select coalesce(sum(t.amount_cents), 0) into v_amount
    from public.transactions t where t.gic_id = p_gic_id and t.vehicle = 'gic';

  if p_choice = 'to_savings' then
    insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, note) values
      (v_account, 'gic', p_gic_id, 'transfer_out', -v_amount, 'gic_release:' || p_gic_id,
       'Moved your matured GIC to savings.'),
      (v_account, 'savings', p_gic_id, 'transfer_in', v_amount, 'gic_release:' || p_gic_id || ':savings',
       'Moved your matured GIC to savings.');
  else
    v_term := case when p_choice = 'renew' then v_gic.term_months else p_new_term end;
    if v_term is null or v_term not in (1, 3, 6, 9, 12, 24) then
      raise exception 'A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.';
    end if;
    select r.rate, r.rate_id into v_rate from public.rate_on('gic', v_term, v_today) r;
    if v_rate.rate is null then
      raise exception 'There is no rate for a % GIC yet.', public.term_label(v_term);
    end if;

    insert into public.gic_holdings (account_id, principal_cents, rate, rate_id, term_months, start_date,
                                     maturity_date, renewed_from_id)
    values (v_account, v_amount, v_rate.rate, v_rate.rate_id, v_term, v_today,
            (v_today + make_interval(months => v_term))::date, p_gic_id)
    returning id into v_new;

    insert into public.transactions (account_id, vehicle, gic_id, type, amount_cents, posting_key, note) values
      (v_account, 'gic', p_gic_id, 'transfer_out', -v_amount, 'gic_renew:' || p_gic_id || ':out',
       'Moved into a new ' || public.term_label(v_term) || ' GIC at ' || public.fmt_rate(v_rate.rate) || '.'),
      (v_account, 'gic', v_new, 'transfer_in', v_amount, 'gic_renew:' || p_gic_id || ':in',
       'A new ' || public.term_label(v_term) || ' GIC at ' || public.fmt_rate(v_rate.rate)
       || ', from your matured GIC (' || public.fmt_money(v_gic.principal_cents) || ' + '
       || public.fmt_money(v_amount - v_gic.principal_cents) || ' interest).');
  end if;

  update public.gic_holdings set maturity_choice = p_choice where id = p_gic_id;
  return v_new;
end;
$$;

-- Buy or sell a fund. Buys are by amount; sells by amount or "sell all". Both
-- settle at the fund's next close (settle_trades). One trade per fund per day.
create function public.request_trade(p_fund_id text, p_side text, p_amount_cents bigint default null,
                                     p_sell_all boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_fund public.funds;
  v_available bigint;
  v_units numeric;
  v_close numeric;
  v_hold numeric;
  v_id bigint;
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_side is null or p_side not in ('buy', 'sell') then
    raise exception 'Choose buy or sell.';
  end if;
  if coalesce(p_sell_all, false) then
    if p_side = 'buy' then
      raise exception '"Sell all" is only for selling.';
    end if;
    if p_amount_cents is not null then
      raise exception 'Choose an amount or "sell all", not both.';
    end if;
  elsif p_amount_cents is null or p_amount_cents < 1000 then
    raise exception 'The smallest trade is $10.00.';
  end if;

  if exists (select 1 from public.requests r
              where r.account_id = v_account and r.fund_id = p_fund_id and r.type = 'move'
                and r.status in ('pending', 'settled')
                and (r.created_at at time zone 'America/Edmonton')::date = public.app_today()) then
    raise exception 'You''ve already traded the % fund today. You can trade it again tomorrow.', v_fund.name;
  end if;

  if p_side = 'buy' then
    v_available := public.vehicle_cents(v_account, 'savings') - public.held_cents(v_account);
    if p_amount_cents > v_available then
      raise exception 'You have % available.', public.fmt_money(v_available);
    end if;
    insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, held_cents)
    values (v_account, 'move', 'savings', 'stock', p_fund_id, p_amount_cents, p_amount_cents)
    returning id into v_id;
    return v_id;
  end if;

  v_units := public.fund_units(v_account, p_fund_id) - public.held_units(v_account, p_fund_id);
  if v_units <= 0 then
    raise exception 'You don''t have any % units to sell.', v_fund.name;
  end if;

  if coalesce(p_sell_all, false) then
    v_hold := v_units;
  else
    select fp.close into v_close from public.fund_prices fp
     where fp.fund_id = p_fund_id and fp.price_date <= public.app_today()
     order by fp.price_date desc limit 1;
    if v_close is null then
      raise exception 'There''s no price for the % fund yet, so it can''t be sold by amount.', v_fund.name;
    end if;
    if p_amount_cents > v_units * v_close * 100 then
      raise exception 'Your % units are worth about %, so you can sell up to that (or choose "sell all").',
        v_fund.name, public.fmt_money(floor(v_units * v_close * 100));
    end if;
    -- Hold the units the amount needs at the latest close. If the price falls by
    -- the close, settlement sells what she has (see settle_trades).
    v_hold := least(v_units, public.round_up_units(p_amount_cents / 100.0 / v_close));
  end if;

  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all, held_units)
  values (v_account, 'move', 'stock', 'savings', p_fund_id, p_amount_cents, coalesce(p_sell_all, false), v_hold)
  returning id into v_id;
  return v_id;
end;
$$;

-- "Something looks wrong?": a question to Dad, optionally about one ledger line.
create function public.ask_question(p_message text, p_transaction_id bigint default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_id bigint;
begin
  if p_message is null or btrim(p_message) = '' then
    raise exception 'Write your question first.';
  end if;
  if length(p_message) > 2000 then
    raise exception 'That''s a long question! Please keep it under 2,000 letters.';
  end if;
  if p_transaction_id is not null and not exists (
       select 1 from public.transactions t where t.id = p_transaction_id and t.account_id = v_account) then
    raise exception 'That line isn''t in your history.' using errcode = '42501';
  end if;

  insert into public.questions (account_id, transaction_id, message)
  values (v_account, p_transaction_id, btrim(p_message))
  returning id into v_id;
  return v_id;
end;
$$;

