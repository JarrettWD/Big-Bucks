-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). Fund prices.
--
-- 1. A close counts only once it's final: fetched after its market closed
--    (final_close). Settlement, dividends and market-move notes use only final
--    closes (their new versions are in 20261018020000_audit_jobs.sql), so a price
--    fetched during the trading day can never become a settlement price.
-- 2. fund_prices and fund_splits are append-only, like the ledger. A wrong close
--    is fixed with correct_fund_price (Dad, with the authenticator code, logged),
--    and only while nothing has used it: no trade settled at it and no dividend
--    paid from it. Each fix keeps the old value in fund_price_corrections.
-- 3. record_market_closure (Dad, with the authenticator code, logged): a market
--    closed on a day it normally trades (a national day of mourning, an outage).
--    Without it, a close that never comes would hold up that market's trades and
--    dividends forever. Trades waiting for that day move to the next close, and
--    the girls with one are told.

-- 1. Final closes ----------------------------------------------------------------------------------

-- The close for a fund's trading day, only if it was fetched after that market closed.
create function public.final_close(p_fund_id text, p_date date)
returns numeric
language sql stable
set search_path = ''
as $$
  select fp.close
    from public.fund_prices fp join public.funds f on f.id = fp.fund_id
   where fp.fund_id = p_fund_id and fp.price_date = p_date
     and fp.fetched_at >= public.close_time(f.market, p_date);
$$;
comment on function public.final_close(text, date) is
  'A fund''s close for a day, only once it is final (fetched after the market closed). Null otherwise.';

-- 2. Append-only prices and splits -----------------------------------------------------------------

create table public.fund_price_corrections (
  id            bigint generated always as identity primary key,
  fund_id       text not null references public.funds (id),
  price_date    date not null,
  old_close     numeric(20,8) not null,
  new_close     numeric(20,8) not null check (new_close > 0),
  note          text not null check (btrim(note) <> ''),
  corrected_by  uuid not null,
  corrected_at  timestamptz not null default public.app_now()
);
comment on table public.fund_price_corrections is
  'Every fix to a stored close: the old and new value, why, who and when (append-only). Parent only.';
create trigger fund_price_corrections_no_update_delete before update or delete on public.fund_price_corrections
  for each row execute function public.reject_append_only_change();
create trigger fund_price_corrections_no_truncate before truncate on public.fund_price_corrections
  for each statement execute function public.reject_append_only_change();
alter table public.fund_price_corrections enable row level security;
create policy fund_price_corrections_read on public.fund_price_corrections for select to authenticated
  using ((select public.is_parent()));
revoke all on public.fund_price_corrections from public, anon, authenticated, service_role;
grant select on public.fund_price_corrections to authenticated, service_role;

-- fund_prices: no delete or truncate ever; an update only from correct_fund_price,
-- and then only the close and when it was fetched.
create function public.fund_prices_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and coalesce(current_setting('bigbucks.price_fix', true), '') = 'on'
     and new.fund_id = old.fund_id and new.price_date = old.price_date then
    return new;
  end if;
  raise exception 'fund_prices is append-only: % is not allowed. A wrong close is fixed with correct_fund_price.',
    lower(tg_op);
end;
$$;
create trigger fund_prices_no_update_delete before update or delete on public.fund_prices
  for each row execute function public.fund_prices_guard();
create trigger fund_prices_no_truncate before truncate on public.fund_prices
  for each statement execute function public.reject_append_only_change();
create trigger fund_splits_no_update_delete before update or delete on public.fund_splits
  for each row execute function public.reject_append_only_change();
create trigger fund_splits_no_truncate before truncate on public.fund_splits
  for each statement execute function public.reject_append_only_change();

-- Fix a stored close, while nothing has used it. Dad types the real close from the
-- exchange; it is never a guess.
create function public.correct_fund_price(p_fund_id text, p_date date, p_close numeric, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_prices;
  v_qstart date;
  v_label text;
begin
  perform public.require_parent();
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
  if p_close = v_old.close then
    raise exception 'That''s the close already stored.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say where the right close comes from, so the fix explains itself.';
  end if;
  if public.app_now() < public.close_time(v_fund.market, p_date) then
    raise exception 'The market hasn''t closed yet that day, so there''s no final close to type in.';
  end if;

  -- Used by a trade: one settled at this close.
  if exists (select 1 from public.transactions t
              where t.fund_id = p_fund_id and t.vehicle = 'stock' and t.unit_price is not null
                and t.effective_at = public.close_time(v_fund.market, p_date)) then
    raise exception 'A trade already settled at this close, so it can''t change. Fix that trade with a correction instead.';
  end if;
  -- Used by a dividend: this is a quarter's last close and that quarter's dividend is paid.
  v_qstart := (date_trunc('quarter', p_date) + interval '3 months')::date;
  if p_date = public.last_trading_day_before(v_fund.market, v_qstart) then
    v_label := to_char(v_qstart, 'YYYY') || 'Q' || extract(quarter from v_qstart);
    if exists (select 1 from public.transactions t
                where t.type = 'dividend' and t.posting_key like 'dividend:' || v_label || ':' || p_fund_id || ':%') then
      raise exception 'A dividend was already paid from this close, so it can''t change. Fix it with a correction instead.';
    end if;
  end if;

  insert into public.fund_price_corrections (fund_id, price_date, old_close, new_close, note, corrected_by)
  values (p_fund_id, p_date, v_old.close, p_close, btrim(p_note), auth.uid());
  perform set_config('bigbucks.price_fix', 'on', true);
  update public.fund_prices set close = p_close, fetched_at = public.app_now()
   where fund_id = p_fund_id and price_date = p_date;
  perform set_config('bigbucks.price_fix', '', true);

  perform public.log_parent_action('correct_fund_price', null, null,
    'Fixed the ' || v_fund.name || ' close for ' || public.fmt_date(p_date) || ': '
      || public.fmt_money4(v_old.close * 100) || ' → ' || public.fmt_money4(p_close * 100) || '.',
    jsonb_build_object('fund_id', p_fund_id, 'price_date', p_date, 'old_close', v_old.close,
                       'new_close', p_close, 'note', btrim(p_note)));
end;
$$;

-- 3. Unscheduled market closures ---------------------------------------------------------------------

create function public.record_market_closure(p_market public.market, p_date date, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := case p_market when 'nyse' then 'New York Stock Exchange' else 'Toronto Stock Exchange' end;
  v_req record;
  v_n integer := 0;
  v_ids bigint[];
begin
  perform public.require_parent();
  if p_market is null or p_date is null then
    raise exception 'Choose the market and the day it was closed.';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say why the market was closed (for example "National day of mourning").';
  end if;
  if p_date > public.app_today() + 366 then
    raise exception 'That''s more than a year away.';
  end if;
  if not public.is_trading_day(p_market, p_date) then
    raise exception 'The % already doesn''t trade on %.', v_name, public.fmt_date(p_date);
  end if;
  if exists (select 1 from public.fund_prices fp join public.funds f on f.id = fp.fund_id
              where f.market = p_market and fp.price_date = p_date) then
    raise exception 'There''s already a close for % on %, so the market was open that day.',
      v_name, public.fmt_date(p_date);
  end if;

  -- The trades that were waiting for that day's close, before it's marked closed.
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from public.requests r join public.funds f on f.id = r.fund_id
   where r.status = 'pending' and r.type = 'move' and f.market = p_market
     and (public.next_close(f.market, r.created_at) at time zone 'America/Toronto')::date = p_date;

  insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url)
  values (p_market, p_date, btrim(p_note), 'closed', null, true, 'Recorded by Dad in Big Bucks')
  on conflict (market, holiday_date) do update
    set name = excluded.name, kind = 'closed', closes_at = null, confirmed = true, source_url = excluded.source_url;

  -- They now wait for the next close. Each girl with one is told.
  for v_req in
    select r.id, r.account_id, r.from_vehicle, f.name as fund_name,
           public.next_close(f.market, r.created_at) as next_at
      from public.requests r join public.funds f on f.id = r.fund_id
     where r.id = any (v_ids)
     order by r.id
  loop
    perform public.notify(v_req.account_id, 'request', 'The market was closed',
      'The ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ', so your ' || v_req.fund_name || ' '
        || case when v_req.from_vehicle = 'stock' then 'sale' else 'buy' end
        || ' will happen at the next close, on ' || public.fmt_date(public.edmonton_local(v_req.next_at)::date) || '.',
      'closure:' || p_market || ':' || p_date || ':' || v_req.id, p_request_id => v_req.id);
    v_n := v_n + 1;
  end loop;

  perform public.log_parent_action('record_market_closure', null, null,
    'Recorded that the ' || v_name || ' was closed on ' || public.fmt_date(p_date) || ': ' || btrim(p_note) || '.',
    jsonb_build_object('market', p_market, 'date', p_date, 'note', btrim(p_note), 'trades_told', v_n));
end;
$$;

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement', 'correct_fund_price', 'record_market_closure'));

revoke all on function public.final_close(text, date) from public, anon, authenticated, service_role;
revoke all on function public.fund_prices_guard() from public, anon, authenticated, service_role;
revoke all on function public.correct_fund_price(text, date, numeric, text) from public, anon, authenticated, service_role;
revoke all on function public.record_market_closure(public.market, date, text) from public, anon, authenticated, service_role;
grant execute on function public.correct_fund_price(text, date, numeric, text) to authenticated;
grant execute on function public.record_market_closure(public.market, date, text) to authenticated;
