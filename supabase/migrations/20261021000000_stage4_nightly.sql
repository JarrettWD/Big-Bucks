-- Stage 4, Part A1 (plan approved by Dad, 2026-10-09): real closes, the nightly
-- run on a timer, and the alerts that tell Dad when something is wrong.
--
-- 1. fund_prices.source: 'daily' (a real daily close) or 'weekly_backfill' (a
--    weekly close from the one-time history load, for the graphs). Only daily
--    closes are ever final, so no trade, dividend or market-move note can use a
--    weekly one, and a weekly close is refused on or after the day the first
--    account opened.
-- 2. store_close(): the server's only way to save a close. It refuses a close
--    before that market has closed and a day the market doesn't trade, never
--    overwrites a stored close, and raises a quiet alert when a close moves more
--    than 25% from the one before with no split recorded in between. Storing a
--    close settles the open "missing close" alert for it.
-- 3. record_split(): splits from the price provider, for a future date, or today
--    before tonight's split job has run. Too late for that means units would
--    already be wrong, so Dad gets an alert instead.
-- 4. The price-call budget: at most 20 calls to the price provider per Alberta
--    day (the free key allows 25), each one logged in price_calls.
-- 5. nightly_kick(), run by pg_cron every 30 minutes from 22:00 to 04:30 UTC
--    (4:00 pm to 10:30 pm in Alberta, UTC−6 all year). It does nothing before
--    4:30 pm Alberta time, nothing once tonight's work is finished, and nothing
--    when the nightly function's address and key aren't in Vault (so your own
--    computer never calls anything). Otherwise it queues one call to the nightly
--    Edge Function through the outbox. From 9:00 pm it also raises one
--    "missing close" alert per fund and day. set_nightly_vault() puts the
--    address and a new key in Vault (production setup, RUNBOOK), so the key is
--    never typed into a query.
-- 6. send_outbox(): the one named sender. It stops at once in a preview, and
--    only knows how to call the nightly function (address and key from Vault, at
--    send time, so the key is never stored in a table).
-- 7. Two alerts from the daily health check: the database size, past about 400 MB
--    of the free plan's 500 MB, and "Send test alert".
-- 8. pg_cron and pg_net, and the schedule.

-- 1. Where a close came from --------------------------------------------------------------------------

alter type public.alert_kind add value if not exists 'database_size';
alter type public.alert_kind add value if not exists 'price_jump';
alter type public.alert_kind add value if not exists 'late_split';

alter table public.fund_prices add column source text not null default 'daily'
  check (source in ('daily', 'weekly_backfill'));
comment on column public.fund_prices.source is
  'daily: a real daily close. weekly_backfill: a weekly close from the history load, for graphs only (never final).';

-- Only a daily close, fetched after its market closed, is final.
create or replace function public.final_close(p_fund_id text, p_date date)
returns numeric
language sql stable
set search_path = ''
as $$
  select fp.close
    from public.fund_prices fp join public.funds f on f.id = fp.fund_id
   where fp.fund_id = p_fund_id and fp.price_date = p_date and fp.source = 'daily'
     and fp.fetched_at >= public.close_time(f.market, p_date);
$$;
comment on function public.final_close(text, date) is
  'A fund''s daily close for a day, only once it is final (fetched after the market closed). Null otherwise, and always null for a weekly backfill close.';

-- The Alberta date the first account opened: from then on, closes matter for money.
create function public.first_account_day()
returns date
language sql stable
set search_path = ''
as $$
  select min(public.edmonton_local(a.created_at)::date) from public.accounts a;
$$;

-- 2. Saving a close --------------------------------------------------------------------------------------

create function public.store_close(p_fund_id text, p_date date, p_close numeric, p_source text default 'daily')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_prices;
  v_prev public.fund_prices;
  v_first date := public.first_account_day();
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_date is null then
    raise exception 'A close needs its day.';
  end if;
  if p_close is null or p_close <= 0 or p_close <> round(p_close, 8) then
    raise exception 'A close is a price above $0, with at most 8 decimal places.';
  end if;
  if p_source is null or p_source not in ('daily', 'weekly_backfill') then
    raise exception 'A close comes from the daily series or the weekly backfill.';
  end if;
  if not public.is_trading_day(v_fund.market, p_date) then
    raise exception 'The % market doesn''t trade on %, so there''s no close to store.', v_fund.market, p_date;
  end if;
  if public.app_now() < public.close_time(v_fund.market, p_date) then
    raise exception 'The % market hasn''t closed yet on %, so that price isn''t a close.', v_fund.market, p_date;
  end if;
  if p_source = 'weekly_backfill' and v_first is not null and p_date >= v_first then
    raise exception 'A weekly backfill close is only for days before the first account opened (%).', v_first;
  end if;

  -- Takes turns with settlement and price fixes on the same fund and day.
  perform pg_advisory_xact_lock(hashtext('close:' || p_fund_id || ':' || p_date));

  select * into v_old from public.fund_prices fp where fp.fund_id = p_fund_id and fp.price_date = p_date;
  if found then
    -- Never overwritten: a wrong close is fixed by Dad (correct_fund_price).
    return case when v_old.close = p_close then 'already' else 'differs' end;
  end if;

  -- A big move with no split recorded between the two closes: worth a look.
  select * into v_prev from public.fund_prices fp
   where fp.fund_id = p_fund_id and fp.price_date < p_date
   order by fp.price_date desc limit 1;
  if found and abs(p_close - v_prev.close) > 0.25 * v_prev.close
     and not exists (select 1 from public.fund_splits s
                      where s.fund_id = p_fund_id and s.split_date > v_prev.price_date and s.split_date <= p_date) then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('price_jump', true,
            'The ' || v_fund.name || ' close for ' || public.fmt_date(p_date) || ' ('
              || public.fmt_money4(p_close * 100) || ') moved more than 25% from the one before ('
              || public.fmt_money4(v_prev.close * 100) || ', ' || public.fmt_date(v_prev.price_date)
              || ') and no split is recorded. Check it against the exchange; if it''s wrong, fix it.',
            jsonb_build_object('fund_id', p_fund_id, 'date', p_date, 'close', p_close,
                               'previous_date', v_prev.price_date, 'previous_close', v_prev.close));
  end if;

  insert into public.fund_prices (fund_id, price_date, close, source) values (p_fund_id, p_date, p_close, p_source);

  -- Its "missing close" alert, if there was one, is settled.
  update public.alerts al set resolved_at = public.app_now()
   where al.kind = 'missing_price' and al.resolved_at is null
     and al.details ->> 'fund_id' = p_fund_id and al.details ->> 'date' = p_date::text;
  return 'stored';
end;
$$;
comment on function public.store_close(text, date, numeric, text) is
  'The server''s only way to save a close. Refuses a close before the market closed, a non-trading day, and a weekly close once accounts exist. Never overwrites.';

-- Several closes for one fund at once (the nightly function and the backfill). Each
-- goes through store_close; a refused one is reported, not fatal.
create function public.store_closes(p_fund_id text, p_closes jsonb, p_source text default 'daily')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_status text;
  v_counts jsonb := '{}'::jsonb;
  v_refused jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_closes) is distinct from 'array' then
    raise exception 'Closes come as a list of {date, close}.';
  end if;
  for v_row in select * from jsonb_array_elements(p_closes) loop
    begin
      v_status := public.store_close(p_fund_id, (v_row ->> 'date')::date, (v_row ->> 'close')::numeric, p_source);
    exception when others then
      v_status := 'refused';
      v_refused := v_refused || jsonb_build_object('date', v_row ->> 'date', 'why', sqlerrm);
    end;
    v_counts := v_counts || jsonb_build_object(v_status, coalesce((v_counts ->> v_status)::int, 0) + 1);
  end loop;
  return jsonb_build_object('fund_id', p_fund_id, 'counts', v_counts, 'refused', v_refused);
end;
$$;

-- 3. Splits ----------------------------------------------------------------------------------------------

create function public.record_split(p_fund_id text, p_date date, p_ratio_from integer, p_ratio_to integer,
                                    p_source text default 'price provider')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_splits;
  v_had boolean;
  v_today date := public.app_today();
  v_first date := public.first_account_day();
begin
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_date is null or p_ratio_from is null or p_ratio_to is null or p_ratio_from <= 0 or p_ratio_to <= 0
     or p_ratio_from = p_ratio_to then
    raise exception 'A split needs its day and two different whole numbers (2-for-1 is from 1, to 2).';
  end if;

  select * into v_old from public.fund_splits s where s.fund_id = p_fund_id and s.split_date = p_date;
  v_had := found;
  if v_had and v_old.ratio_from::numeric / v_old.ratio_to = p_ratio_from::numeric / p_ratio_to then
    return 'already';
  end if;

  if v_had
     or p_date < v_today
     or (p_date = v_today and exists (select 1 from public.job_runs jr
                                       where jr.job = 'splits' and jr.run_for_date = p_date and jr.status = 'ok')) then
    -- Before any account (old history), it doesn't matter.
    if not v_had and (v_first is null or p_date < v_first) then
      return 'history';
    end if;
    if not exists (select 1 from public.alerts al
                    where al.kind = 'late_split' and al.details ->> 'fund_id' = p_fund_id
                      and al.details ->> 'date' = p_date::text) then
      insert into public.alerts (kind, is_quiet, message, details)
      values ('late_split', false,
              'The price provider reports a ' || p_ratio_to || '-for-' || p_ratio_from || ' ' || v_fund.name
                || ' split on ' || public.fmt_date(p_date) || ', '
                || case when v_had then 'different from the one recorded'
                        else 'too late to apply automatically' end
                || '. Holdings may need a correction. Check it before approving anything for this fund.',
              jsonb_build_object('fund_id', p_fund_id, 'date', p_date, 'ratio_from', p_ratio_from,
                                 'ratio_to', p_ratio_to, 'source', p_source));
    end if;
    return case when v_had then 'differs' else 'too_late' end;
  end if;

  insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to, source)
  values (p_fund_id, p_date, p_ratio_from, p_ratio_to, p_source);
  return 'recorded';
end;
$$;
comment on function public.record_split(text, date, integer, integer, text) is
  'A split from the price provider: for a future day, or today before the split job ran. Too late raises an alert for Dad.';

-- 4. The price-call budget ------------------------------------------------------------------------------

create table public.price_calls (
  id         bigint generated always as identity primary key,
  call_date  date not null,
  kind       text not null check (kind in ('daily', 'weekly', 'splits')),
  symbol     text not null check (btrim(symbol) <> ''),
  called_at  timestamptz not null default public.app_now(),
  ok         boolean,
  note       text
);
comment on table public.price_calls is
  'Every call to the price provider (at most 20 per Alberta day), and how it went. Server writes; Dad reads.';
create index price_calls_day_idx on public.price_calls (call_date, kind, symbol);
alter table public.price_calls enable row level security;
create policy price_calls_read on public.price_calls for select to authenticated using ((select public.is_parent()));
revoke all on public.price_calls from public, anon, authenticated, service_role;
grant select on public.price_calls to authenticated, service_role;

-- A call may go ahead only within today's budget. Null means the budget is used up.
create function public.claim_price_call(p_kind text, p_symbol text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_budget constant integer := 20;
  v_today date := public.app_today();
  v_id bigint;
begin
  perform pg_advisory_xact_lock(hashtext('price_calls'));
  if (select count(*) from public.price_calls pc where pc.call_date = v_today) >= v_budget then
    return null;
  end if;
  insert into public.price_calls (call_date, kind, symbol) values (v_today, p_kind, p_symbol)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.finish_price_call(p_id bigint, p_ok boolean, p_note text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.price_calls set ok = p_ok, note = left(p_note, 500) where id = p_id;
$$;

-- 5. The nightly run --------------------------------------------------------------------------------------

-- The day tonight's run works through: today from 4:30 pm Alberta time, else yesterday.
create function public.nightly_target()
returns date
language sql stable
set search_path = ''
as $$
  select case when public.edmonton_local(public.app_now())::time >= time '16:30'
              then public.app_today() else public.app_today() - 1 end;
$$;

-- Trading days whose close should be stored by now and isn't: from the day the first
-- account opened (before any account, from the day after the last stored close), at
-- most 140 days back (the provider's daily series holds about 100 trading days).
create function public.missing_closes(p_through date)
returns table (fund_id text, symbol text, market public.market, price_date date)
language sql stable
set search_path = ''
as $$
  select f.id, f.proxy_symbol, f.market, d::date
    from public.funds f
   cross join lateral generate_series(
           greatest(coalesce(public.first_account_day(),
                             (select max(fp.price_date) + 1 from public.fund_prices fp where fp.fund_id = f.id),
                             p_through),
                    p_through - 140),
           p_through, interval '1 day') d
   where public.is_trading_day(f.market, d::date)
     and public.close_time(f.market, d::date) <= public.app_now()
     and not exists (select 1 from public.fund_prices fp where fp.fund_id = f.id and fp.price_date = d::date)
   order by f.sort_order, d;
$$;

-- Where tonight's work stands for a day: done when every fund trading that day has
-- its final close, every job has finished it (savings interest the day before, since
-- a day's interest is worked out once the day is over), and it's been reconciled.
create function public.nightly_status(p_date date)
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
begin
  select coalesce(jsonb_agg(f.id order by f.sort_order), '[]'::jsonb) into v_closes
    from public.funds f
   where public.is_trading_day(f.market, p_date) and public.final_close(f.id, p_date) is null;

  select coalesce(jsonb_agg(j.name order by j.ord), '[]'::jsonb) into v_jobs
    from unnest(array['expire', 'splits', 'settle', 'dividends', 'notes', 'gic_maturity', 'auto_move',
                      'monthly', 'rate_notices', 'interest']) with ordinality j(name, ord)
   where not exists (select 1 from public.job_runs jr
                      where jr.job::text = j.name and jr.status = 'ok'
                        and jr.run_for_date = case when j.name = 'interest' then v_interest_day else p_date end);

  v_reconciled := exists (select 1 from public.job_runs jr where jr.job = 'reconcile' and jr.run_for_date = p_date);

  return jsonb_build_object('date', p_date, 'closes_missing', v_closes, 'jobs_waiting', v_jobs,
                            'reconciled', v_reconciled,
                            'done', jsonb_array_length(v_closes) = 0 and jsonb_array_length(v_jobs) = 0 and v_reconciled);
end;
$$;

-- Everything the nightly function needs to know, in one call.
create function public.nightly_plan()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_target date := public.nightly_target();
  v_today date := public.app_today();
begin
  return jsonb_build_object(
    'target', v_target,
    'today', v_today,
    'backfill_from', v_today - 730,
    'status', public.nightly_status(v_target),
    'funds', (select jsonb_agg(jsonb_build_object(
                'fund_id', f.id, 'symbol', f.proxy_symbol, 'market', f.market,
                'missing', coalesce((select jsonb_agg(m.price_date order by m.price_date)
                                       from public.missing_closes(v_target) m where m.fund_id = f.id), '[]'::jsonb),
                'last_close', (select jsonb_build_object('date', fp.price_date, 'close', fp.close::text)
                                 from public.fund_prices fp where fp.fund_id = f.id
                                order by fp.price_date desc limit 1),
                -- The provider's split list, once a week per fund.
                'splits_due', not exists (select 1 from public.price_calls pc
                                           where pc.kind = 'splits' and pc.symbol = f.proxy_symbol
                                             and pc.call_date > v_today - 7))
              order by f.sort_order)
                from public.funds f));
end;
$$;

-- Reconcile every day not yet checked, through a day.
create function public.reconcile_through(p_through date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_day date;
  v_r jsonb;
  v_days jsonb := '[]'::jsonb;
  v_problems integer := 0;
begin
  select max(jr.run_for_date) + 1 into v_from from public.job_runs jr where jr.job = 'reconcile';
  v_day := coalesce(v_from, p_through);
  while v_day <= p_through loop
    v_r := public.reconcile(v_day);
    v_days := v_days || to_jsonb(v_day);
    if v_r ->> 'status' <> 'ok' then
      v_problems := v_problems + 1;
    end if;
    v_day := v_day + 1;
  end loop;
  return jsonb_build_object('reconciled', v_days, 'days_with_problems', v_problems);
end;
$$;

-- From 9:00 pm Alberta time: one "missing close" alert per fund and day still missing.
create function public.raise_missing_price_alerts(p_date date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
  v_n integer := 0;
begin
  for v_m in
    select m.fund_id, f.name, m.price_date from public.missing_closes(p_date) m join public.funds f on f.id = m.fund_id
     order by f.sort_order, m.price_date
  loop
    continue when exists (select 1 from public.alerts al
                           where al.kind = 'missing_price' and al.details ->> 'fund_id' = v_m.fund_id
                             and al.details ->> 'date' = v_m.price_date::text);
    insert into public.alerts (kind, is_quiet, message, details)
    values ('missing_price', false,
            'There''s still no ' || v_m.name || ' close for ' || public.fmt_date(v_m.price_date)
              || '. Its trades and dividends wait until it arrives; savings and GICs carry on. See RUNBOOK, "A close is missing".',
            jsonb_build_object('fund_id', v_m.fund_id, 'date', v_m.price_date));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- A Vault value, or null.
create function private.vault_value(p_name text)
returns text
language sql stable
security definer
set search_path = ''
as $$
  select nullif(btrim(s.decrypted_secret), '') from vault.decrypted_secrets s where s.name = p_name limit 1;
$$;
revoke all on function private.vault_value(text) from public, anon, authenticated, service_role;

-- Production setup (RUNBOOK), by the database owner in the SQL Editor: saves the nightly
-- function's address in Vault and makes its key there, so the key is never typed into
-- a query (the SQL Editor keeps a history). Answers the key once, to copy into the
-- function's NIGHTLY_KEY secret and GitHub's. Running it again makes a new key.
create function public.set_nightly_vault(p_url text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
  v_id uuid;
begin
  if p_url is null or p_url !~ '^https://[a-z]{20}\.supabase\.co/[a-z0-9/]+/nightly$' then
    raise exception 'Use the nightly function''s address from RUNBOOK: https://<project ref>.supabase.co/…/nightly';
  end if;
  select s.id into v_id from vault.secrets s where s.name = 'nightly_function_url';
  if v_id is null then
    perform vault.create_secret(p_url, 'nightly_function_url', 'The nightly Edge Function''s address (stage 4).');
  else
    perform vault.update_secret(v_id, p_url);
  end if;
  v_id := null;
  select s.id into v_id from vault.secrets s where s.name = 'nightly_function_key';
  if v_id is null then
    perform vault.create_secret(v_key, 'nightly_function_key', 'The nightly Edge Function''s key (stage 4).');
  else
    perform vault.update_secret(v_id, v_key);
  end if;
  return v_key;
end;
$$;
comment on function public.set_nightly_vault(text) is
  'Production setup (SQL Editor): the nightly function''s address and a new key in Vault. Answers the key once.';

-- pg_cron calls this every 30 minutes from 22:00 to 04:30 UTC.
create function public.nightly_kick()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_local timestamp := public.edmonton_local(public.app_now());
  v_today date := public.app_today();
begin
  -- Not set up (your own computer, or production before RUNBOOK's Vault step).
  if private.vault_value('nightly_function_url') is null or private.vault_value('nightly_function_key') is null then
    return 'not set up: the nightly function''s address and key aren''t in Vault';
  end if;
  if v_local::time < time '16:30' then
    return 'too early: the run starts at 4:30 pm Alberta time';
  end if;
  if v_local::time >= time '21:00' then
    perform public.raise_missing_price_alerts(v_today);
  end if;
  if (public.nightly_status(v_today) ->> 'done')::boolean then
    return 'done: tonight''s work is finished';
  end if;
  -- One call at a time: the last one may still be working.
  if exists (select 1 from public.outbox o
              where o.kind = 'http' and o.payload ->> 'target' = 'nightly'
                and o.created_at > public.app_now() - interval '25 minutes') then
    return 'waiting: a call went out less than 25 minutes ago';
  end if;
  perform public.queue_outside('http', jsonb_build_object('target', 'nightly', 'for_date', v_today));
  return 'queued';
end;
$$;
comment on function public.nightly_kick() is
  'Run by pg_cron. From 4:30 pm Alberta time, queues one call to the nightly function until tonight''s work is done. Does nothing without its Vault entries.';

-- 6. The one sender ---------------------------------------------------------------------------------------

alter table public.outbox add column net_request_id bigint;

create function public.send_outbox()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.outbox;
  v_url text;
  v_key text;
  v_req bigint;
  v_sent integer := 0;
begin
  if public.in_preview() then
    return 0;
  end if;
  for v_row in
    select * from public.outbox o
     where o.sent_at is null and o.kind = 'http' and o.attempts < 3
     order by o.id
     for update skip locked
  loop
    if v_row.payload ->> 'target' is distinct from 'nightly' then
      update public.outbox set attempts = attempts + 1, last_error = 'no sender for this message'
       where id = v_row.id;
      continue;
    end if;
    v_url := private.vault_value('nightly_function_url');
    v_key := private.vault_value('nightly_function_key');
    if v_url is null or v_key is null then
      update public.outbox set attempts = attempts + 1, last_error = 'the nightly function''s address or key isn''t in Vault'
       where id = v_row.id;
      continue;
    end if;
    -- pg_net sends it after this transaction commits. The function can take a while.
    v_req := net.http_post(url := v_url,
                           body := jsonb_build_object('mode', 'nightly'),
                           headers := jsonb_build_object('Content-Type', 'application/json', 'x-nightly-key', v_key),
                           timeout_milliseconds := 150000);
    update public.outbox set sent_at = public.app_now(), attempts = attempts + 1, net_request_id = v_req, last_error = null
     where id = v_row.id;
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end;
$$;
comment on function public.send_outbox() is
  'The only function that reaches outside the database. Stops at once in a preview. Sends queued calls to the nightly function through pg_net.';

-- 7. Database size and the test alert ------------------------------------------------------------------

-- One open alert past about 400 MB (the free plan holds 500 MB).
create function public.database_size_alert(p_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit constant bigint := 400 * 1024 * 1024;
  v_mb integer := (p_bytes / (1024 * 1024))::integer;
  v_raised boolean := false;
begin
  if p_bytes > v_limit
     and not exists (select 1 from public.alerts al where al.kind = 'database_size' and al.resolved_at is null) then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('database_size', false,
            'The database is ' || v_mb || ' MB of the free plan''s 500 MB. See RUNBOOK, "The database is getting big".',
            jsonb_build_object('bytes', p_bytes, 'limit_bytes', v_limit));
    v_raised := true;
  end if;
  return jsonb_build_object('megabytes', v_mb, 'over_limit', p_bytes > v_limit, 'alert_raised', v_raised);
end;
$$;

-- The health check's "Send test alert": a real alert on Dad's Dashboard, which also
-- fails the check, so GitHub emails him. One open at a time; he acknowledges it.
create function public.raise_test_alert()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  select al.id into v_id from public.alerts al where al.kind = 'test' and al.resolved_at is null limit 1;
  if v_id is null then
    insert into public.alerts (kind, is_quiet, message, details)
    values ('test', false,
            'Test alert from the daily health check. If you see this here and got GitHub''s email, alerts work. Acknowledge it to clear it.',
            jsonb_build_object('source', 'health check'))
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create function public.check_database_size()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.database_size_alert(pg_database_size(current_database()));
$$;

-- Grants: the server only (the nightly and health functions use the service role).
revoke all on function public.first_account_day() from public, anon, authenticated, service_role;
revoke all on function public.store_close(text, date, numeric, text) from public, anon, authenticated, service_role;
revoke all on function public.store_closes(text, jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.record_split(text, date, integer, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.claim_price_call(text, text) from public, anon, authenticated, service_role;
revoke all on function public.finish_price_call(bigint, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.nightly_target() from public, anon, authenticated, service_role;
revoke all on function public.missing_closes(date) from public, anon, authenticated, service_role;
revoke all on function public.nightly_status(date) from public, anon, authenticated, service_role;
revoke all on function public.nightly_plan() from public, anon, authenticated, service_role;
revoke all on function public.reconcile_through(date) from public, anon, authenticated, service_role;
revoke all on function public.raise_missing_price_alerts(date) from public, anon, authenticated, service_role;
revoke all on function public.nightly_kick() from public, anon, authenticated, service_role;
revoke all on function public.send_outbox() from public, anon, authenticated, service_role;
revoke all on function public.database_size_alert(bigint) from public, anon, authenticated, service_role;
revoke all on function public.check_database_size() from public, anon, authenticated, service_role;
revoke all on function public.set_nightly_vault(text) from public, anon, authenticated, service_role;
revoke all on function public.raise_test_alert() from public, anon, authenticated, service_role;

grant execute on function public.store_closes(text, jsonb, text) to service_role;
grant execute on function public.store_close(text, date, numeric, text) to service_role;
grant execute on function public.record_split(text, date, integer, integer, text) to service_role;
grant execute on function public.claim_price_call(text, text) to service_role;
grant execute on function public.finish_price_call(bigint, boolean, text) to service_role;
grant execute on function public.nightly_plan() to service_role;
grant execute on function public.nightly_status(date) to service_role;
grant execute on function public.reconcile_through(date) to service_role;
grant execute on function public.check_database_size() to service_role;
grant execute on function public.raise_test_alert() to service_role;

-- 8. Extensions and the schedule --------------------------------------------------------------------------

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- Every 30 minutes, 22:00 to 04:30 UTC (4:00 pm to 10:30 pm in Alberta). The kick and
-- the sender run together; pg_net sends the call once this commits.
select cron.schedule('big-bucks-nightly', '0,30 22,23,0,1,2,3,4 * * *',
                     'select public.nightly_kick(); select public.send_outbox();');
