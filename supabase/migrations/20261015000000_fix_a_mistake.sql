-- Stage 8 B3: Fix a mistake.
--
-- A correction is a NEW savings line (type 'correction'), never an edit. It is
-- linked to what it fixes: a history line (corrects_id for a ledger line,
-- corrects_request_id for a declined or expired request) and/or the question she
-- asked (question_id). These links are not reverses_id: reconcile treats a
-- reversed line as "never happened", while a correction adds to or takes from her
-- savings from the moment it's posted, like any other line.
--
-- Dad's rules (2026-10-03 and 2026-10-04, and his B3 review):
--   * savings only, in dollars, either direction;
--   * a note she can read is required; her notice and history line name what it fixes;
--   * amounts round in her favour: an addition rounds UP to the cent, a reduction
--     rounds DOWN (Dad may type up to 4 decimal places);
--   * no single correction larger than the deposit cap (use a deposit or withdrawal);
--   * an extra check for every reduction (Dad confirms the amount), and for an
--     addition over $100 Dad must type the exact amount again. The database
--     enforces both: p_confirm must be the same amount as p_amount;
--   * a reduction linked to a line can't take more than that line's amount, less
--     what earlier fixes already took from it; an addition may be more (with a
--     warning in the preview, not a block);
--   * never more than her free savings (savings minus what her requests hold);
--   * the graphs count a correction like the line it fixes: a deposit or withdrawal
--     fix is money in or out; anything else is earned. A fix with no line (only a
--     question) is whichever Dad chooses, "earned" by default (counts_as);
--   * nothing posts twice: each correction has a key from the screen (posting_key
--     'correction:<key>');
--   * logged in parent_actions, in the same transaction;
--   * the preview runs the real action with in_preview() on, then rolls it back.

alter type public.notification_type add value if not exists 'correction';

-- 1. The links -----------------------------------------------------------------------------------

alter table public.transactions
  add column corrects_id bigint references public.transactions (id),
  add column corrects_request_id bigint references public.requests (id),
  add column question_id bigint references public.questions (id),
  add column counts_as text check (counts_as in ('money', 'earned'));
alter table public.transactions add constraint tx_links_only_corrections
  check ((corrects_id is null and corrects_request_id is null and question_id is null and counts_as is null)
         or type = 'correction');
comment on column public.transactions.counts_as is
  'A correction: how the graphs count it. money = money in or out (like a deposit); earned (or null) = earnings.';
comment on column public.transactions.corrects_id is
  'A correction: the ledger line (history line) it fixes. Not a reversal: the line still counts.';
comment on column public.transactions.corrects_request_id is
  'A correction: the declined or expired request (history line) it fixes.';
comment on column public.transactions.question_id is
  'A correction: the "Something looks wrong?" question it came from.';

-- A linked correction is in savings and points at the same kid's line, request or question.
create function public.transactions_check_links()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.corrects_id is null and new.corrects_request_id is null and new.question_id is null then
    return new;
  end if;
  if new.vehicle <> 'savings'
     or (new.corrects_id is not null and not exists (
           select 1 from public.transactions t where t.id = new.corrects_id and t.account_id = new.account_id))
     or (new.corrects_request_id is not null and not exists (
           select 1 from public.requests r where r.id = new.corrects_request_id and r.account_id = new.account_id))
     or (new.question_id is not null and not exists (
           select 1 from public.questions q where q.id = new.question_id and q.account_id = new.account_id)) then
    raise exception 'A correction must be in savings and point at the same kid''s line or question.';
  end if;
  return new;
end;
$$;
create trigger transactions_check_links
  before insert on public.transactions
  for each row execute function public.transactions_check_links();

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings'));

-- 2. A history line in her words (the same titles as src/kid/home/activityText.ts) ----------------

create function public.line_words(p_kind text, p_request_type text, p_fund_id text, p_gic_term integer,
                                  p_rate numeric, p_note text)
returns text
language sql stable
set search_path = ''
as $$
  with w as (
    select coalesce((select f.name from public.funds f where f.id = p_fund_id), 'a fund') as fund,
           case when p_gic_term is null then 'GIC'
                when p_gic_term = 12 then '1-year GIC'
                when p_gic_term = 24 then '2-year GIC'
                else p_gic_term || '-month GIC' end as gic,
           case when p_rate is null then '' else ' at ' || public.fmt_rate(p_rate) end as at)
  select case p_kind
           when 'deposit' then 'Money in'
           when 'withdraw' then 'Money out'
           when 'interest' then 'Savings interest'
           when 'gic_interest' then 'Interest from your ' || w.gic
           when 'dividend' then 'Dividend from ' || w.fund
           when 'gic_buy' then 'Bought a ' || w.gic || w.at
           when 'gic_break' then 'Broke a GIC early'
           when 'gic_to_savings' then case when coalesce(p_note, '') like '%automatically%'
                                           then 'GIC moved to savings automatically' else 'GIC moved to savings' end
           when 'gic_renew' then 'Renewed: a new ' || w.gic || w.at
           when 'fund_buy' then 'Bought ' || w.fund
           when 'fund_sell' then 'Sold ' || w.fund
           when 'split' then w.fund || ' split its units'
           when 'correction' then 'A correction'
           when 'penalty' then 'A penalty'
           when 'request_declined' then case when p_request_type = 'withdraw'
                                             then 'Dad said not this time (money out)'
                                             else 'Dad said not this time (money in)' end
           when 'request_expired' then 'A request ran out of time'
           when 'request_pending' then case p_request_type
                                         when 'deposit' then 'Asked to put money in'
                                         when 'withdraw' then 'Asked to take money out'
                                         when 'buy' then 'Buying ' || w.fund
                                         when 'sell' then 'Selling ' || w.fund
                                         else 'Waiting' end
           else 'A change to your account'
         end
    from w;
$$;

-- 3. Her history says what each correction fixes ---------------------------------------------------
-- my_activity from 20261006000000_alberta_time.sql, with one new column, fixes:
-- for a correction, the line it fixes ("Savings interest on Oct 1") or "your
-- question from Oct 3". Everything else is unchanged.

drop function public.my_activity(uuid, integer, timestamptz, text);
create function public.my_activity(p_account_id uuid, p_limit integer default 20,
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
   limit least(greatest(coalesce(p_limit, 20), 1), 200);
end;
$$;

-- 4. Correcting her savings -------------------------------------------------------------------------

-- Internal: the line and/or question a correction fixes, her savings figures, and
-- the limits that apply. Keys starting with "_" are for correct_savings, not the screen.
--   check_over_cents  an addition over this needs the amount typed again ($100)
--   limit_cents       no single correction may be larger (the deposit cap)
--   line_left_cents   what a reduction may still take from the line (its amount,
--                     less earlier fixes' reductions); null with no line
--   counts_as         how the graphs count it, decided by the line; null with no line
create function public.correction_context(p_account_id uuid, p_line_key text, p_question_id bigint)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_name text;
  v_key text := nullif(btrim(coalesce(p_line_key, '')), '');
  v_q public.questions;
  v_qkey text;
  v_at timestamptz;
  v_line record;
  v_line_json jsonb;
  v_tx_id bigint;
  v_req_id bigint;
  v_taken bigint;
  v_counts text;
  v_savings bigint;
  v_held bigint;
  v_cap bigint;
begin
  select a.name into v_name from public.accounts a where a.id = p_account_id;
  if not found then
    raise exception 'There''s no such account.';
  end if;

  if p_question_id is not null then
    select * into v_q from public.questions q where q.id = p_question_id and q.account_id = p_account_id;
    if not found then
      raise exception 'There''s no question #% from %.', p_question_id, v_name;
    end if;
    if v_q.transaction_id is not null then
      select coalesce(regexp_replace(t.posting_key, ':(gic|savings|in|out|fund)$', ''), 'tx:' || t.id)
        into v_qkey from public.transactions t where t.id = v_q.transaction_id;
      if v_key is not null and v_key <> v_qkey then
        raise exception 'That question is about a different line.';
      end if;
      v_key := v_qkey;
    end if;
  end if;
  if v_key is null and v_q.id is null then
    raise exception 'Choose the history line or question this fixes.';
  end if;

  if v_key is not null then
    -- Find the line's moment, then read just that moment of her history.
    if v_key ~ '^req:[0-9]+$' then
      select case when r.status = 'pending' then r.created_at else coalesce(r.decided_at, r.created_at) end
        into v_at from public.requests r
       where r.id = substr(v_key, 5)::bigint and r.account_id = p_account_id;
    else
      select max(t.effective_at) into v_at from public.transactions t
       where t.account_id = p_account_id
         and coalesce(regexp_replace(t.posting_key, ':(gic|savings|in|out|fund)$', ''), 'tx:' || t.id) = v_key;
    end if;
    if v_at is not null then
      select * into v_line from public.my_activity(p_account_id, 200, v_at + interval '1 microsecond', '') l
       where l.item_key = v_key;
    end if;
    if v_at is null or not found then
      raise exception 'There''s no line "%" in %''s history.', v_key, v_name;
    end if;
    if v_line.kind = 'request_pending' then
      raise exception 'That request is still waiting: approve or decline it instead.';
    end if;
    if v_line.kind like 'request\_%' then
      v_req_id := v_line.request_id;
      v_counts := case when v_line.request_type in ('deposit', 'withdraw') then 'money' else 'earned' end;
    else
      select t.id into v_tx_id from public.transactions t
       where t.id = any (v_line.transaction_ids) order by (t.vehicle = 'savings') desc, t.id limit 1;
      v_counts := case
        when v_line.kind in ('deposit', 'withdraw') then 'money'
        -- A fix to a fix counts the way that fix did.
        when v_line.kind = 'correction' then
          coalesce((select t.counts_as from public.transactions t where t.id = v_tx_id), 'earned')
        else 'earned' end;
    end if;
    -- What earlier fixes already took from this line.
    select coalesce(-sum(t.amount_cents), 0) into v_taken from public.transactions t
     where t.type = 'correction' and t.amount_cents < 0
       and ((v_tx_id is not null and t.corrects_id = v_tx_id)
            or (v_req_id is not null and t.corrects_request_id = v_req_id));
    v_line_json := jsonb_build_object(
      'key', v_line.item_key,
      'words', public.line_words(v_line.kind, v_line.request_type, v_line.fund_id, v_line.gic_term,
                                 v_line.rate, v_line.note),
      'on', public.fmt_date(v_line.on_day),
      'amount_cents', v_line.amount_cents);
  end if;

  v_savings := public.vehicle_cents(p_account_id, 'savings');
  v_held := public.held_cents(p_account_id);
  v_cap := coalesce(public.setting_on('deposit_cap_cents', public.app_today()), '0')::bigint;

  return jsonb_build_object(
    'kid', v_name,
    'line', v_line_json,
    'question', case when v_q.id is null then null else jsonb_build_object(
                  'id', v_q.id, 'message', v_q.message,
                  'asked_on', public.fmt_date(public.edmonton_local(v_q.created_at)::date)) end,
    'savings_cents', v_savings,
    'held_cents', v_held,
    'free_cents', v_savings - v_held,
    'check_over_cents', 10000,
    'limit_cents', v_cap,
    'line_left_cents', case when v_line_json is null then null
                            else greatest(abs(coalesce(v_line.amount_cents, 0)) - v_taken, 0) end,
    'counts_as', v_counts,
    '_taken_cents', v_taken,
    '_tx_id', v_tx_id,
    '_request_id', v_req_id,
    '_question_id', v_q.id);
end;
$$;

-- Internal: dollars as typed ("$1,234.5"), exactly. Null if it isn't an amount.
create function public.correction_dollars(p_text text)
returns numeric
language sql immutable
set search_path = ''
as $$
  select case when x ~ '^[0-9]+(\.[0-9]{1,4})?$' then x::numeric end
    from (select replace(replace(btrim(coalesce(p_text, '')), '$', ''), ',', '') as x) t;
$$;

-- Internal: what Dad typed, in cents, rounded in her favour. Adding rounds up;
-- taking rounds down. exact_cents is the amount before rounding.
create function public.correction_cents(p_direction text, p_amount text, out cents bigint, out exact_cents numeric)
language plpgsql immutable
set search_path = ''
as $$
declare
  v_txt text := replace(replace(btrim(coalesce(p_amount, '')), '$', ''), ',', '');
begin
  if p_direction is null or p_direction not in ('add', 'take') then
    raise exception 'Choose whether to add to her savings or take from it.';
  end if;
  if v_txt !~ '^[0-9]+(\.[0-9]+)?$' then
    raise exception 'Type the amount in dollars, like 12.50.';
  end if;
  if v_txt ~ '\.[0-9]{5,}$' then
    raise exception 'Use at most 4 decimal places.';
  end if;
  exact_cents := v_txt::numeric * 100;
  if exact_cents = 0 then
    raise exception 'Type an amount more than $0.00.';
  end if;
  if p_direction = 'add' then
    cents := ceil(exact_cents)::bigint;
  else
    cents := -floor(exact_cents)::bigint;
    if cents = 0 then
      raise exception 'That rounds down to $0.00 in her favour, so there''s nothing to take.';
    end if;
  end if;
end;
$$;

-- Add to or take from her savings, linked to the line and/or question it fixes.
--   p_direction  'add' or 'take'
--   p_amount     dollars as typed ("12.50"; up to 4 decimals), rounded in her favour
--   p_note       what went wrong, in words she can read (required)
--   p_counts_as  only for a fix with no line: 'money' or 'earned' (the default)
--   p_confirm    the extra check, the same amount again: for every reduction (the
--                screen sends it when Dad confirms), and for an addition over $100
--                (what Dad typed a second time)
--   p_key        from the screen, once per correction, so a double tap posts once
create function public.correct_savings(p_account_id uuid, p_line_key text, p_question_id bigint, p_direction text,
                                       p_amount text, p_note text, p_counts_as text, p_confirm text, p_key uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctx jsonb;
  v_cents bigint;
  v_exact numeric;
  v_note text := btrim(coalesce(p_note, ''));
  v_counts text;
  v_free bigint;
  v_cap bigint;
  v_left bigint;
  v_again numeric;
  v_id bigint;
  v_money text;
  v_signed text;
  v_line jsonb;
  v_question jsonb;
  v_fixes text;
  v_rounded boolean;
begin
  perform public.require_parent();
  perform 1 from public.accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'There''s no such account.';
  end if;
  if p_key is null then
    raise exception 'Missing the correction''s key. Please try again.';
  end if;
  if exists (select 1 from public.transactions t where t.posting_key = 'correction:' || p_key) then
    raise exception 'This correction is already saved.';
  end if;

  v_ctx := public.correction_context(p_account_id, p_line_key, p_question_id);
  select c.cents, c.exact_cents into v_cents, v_exact from public.correction_cents(p_direction, p_amount) c;
  if v_note = '' then
    raise exception 'Write a note she can read: what went wrong and what this fixes.';
  end if;
  if length(v_note) > 300 then
    raise exception 'Keep the note to 300 letters or fewer.';
  end if;
  v_line := v_ctx -> 'line';
  v_question := v_ctx -> 'question';
  v_counts := coalesce(v_ctx ->> 'counts_as', nullif(btrim(coalesce(p_counts_as, '')), ''), 'earned');
  if v_counts not in ('money', 'earned') then
    raise exception 'Choose how the graphs count it: money in or out, or earned.';
  end if;

  -- No single correction larger than the deposit cap.
  v_cap := (v_ctx ->> 'limit_cents')::bigint;
  if abs(v_cents) > v_cap then
    raise exception 'A single correction can''t be more than the deposit limit (%). %', public.fmt_money(v_cap),
      case when v_cents > 0 then 'If this is new money, use a normal deposit instead.'
           else 'If she''s taking money out, use a normal withdrawal instead.' end;
  end if;

  v_free := (v_ctx ->> 'free_cents')::bigint;
  if -v_cents > v_free then
    raise exception 'That''s more than % has free to use (%: % in savings, % on hold for her requests). A correction can''t take money she doesn''t have free.',
      v_ctx ->> 'kid', public.fmt_money(v_free), public.fmt_money((v_ctx ->> 'savings_cents')::bigint),
      public.fmt_money((v_ctx ->> 'held_cents')::bigint);
  end if;

  -- A reduction can't take more than the line it fixes.
  v_left := (v_ctx ->> 'line_left_cents')::bigint;
  if v_cents < 0 and v_left is not null and -v_cents > v_left then
    raise exception 'A fix can''t take more than the line it fixes: "%" on % was %.',
      v_line ->> 'words', v_line ->> 'on', public.fmt_money(abs((v_line ->> 'amount_cents')::bigint)) ||
      case when (v_ctx ->> '_taken_cents')::bigint > 0
           then ', and earlier fixes already took ' || public.fmt_money((v_ctx ->> '_taken_cents')::bigint)
                || ', so at most ' || public.fmt_money(v_left) || ' is left'
           else '' end;
  end if;

  -- The extra check: the same amount again.
  v_money := public.fmt_money(abs(v_cents));
  v_again := public.correction_dollars(p_confirm) * 100;
  if v_cents < 0 and v_again is distinct from v_exact then
    raise exception 'Taking money away needs the extra check: confirm % first.', v_money;
  end if;
  if v_cents > (v_ctx ->> 'check_over_cents')::bigint and v_again is distinct from v_exact then
    if v_again is null then
      raise exception 'Adding more than % needs the amount typed again to confirm (%).',
        public.fmt_money((v_ctx ->> 'check_over_cents')::bigint), v_money;
    end if;
    raise exception 'The amount typed again (%) doesn''t match %. Please type it again.',
      case when v_again = trunc(v_again) then public.fmt_money(v_again) else public.fmt_money4(v_again) end,
      case when v_exact = trunc(v_exact) then public.fmt_money(v_exact) else public.fmt_money4(v_exact) end;
  end if;

  insert into public.transactions (account_id, vehicle, type, amount_cents, note, posting_key,
                                   corrects_id, corrects_request_id, question_id, counts_as)
  values (p_account_id, 'savings', 'correction', v_cents, v_note, 'correction:' || p_key,
          (v_ctx ->> '_tx_id')::bigint, (v_ctx ->> '_request_id')::bigint, (v_ctx ->> '_question_id')::bigint,
          v_counts)
  returning id into v_id;

  v_fixes := case when jsonb_typeof(v_line) = 'object'
                  then (v_line ->> 'words') || ' on ' || (v_line ->> 'on')
                  else 'your question from ' || (v_question ->> 'asked_on') end;
  perform public.notify(p_account_id, 'correction',
    'A correction · ' || case when jsonb_typeof(v_line) = 'object' then 'fixes ' else 'about ' end || v_fixes,
    case when v_cents > 0 then 'Dad added ' || v_money || ' to your savings.'
         else 'Dad took ' || v_money || ' out of your savings.' end
      || ' Dad said: "' || v_note || '"',
    'correction:' || v_id);

  v_signed := case when v_cents > 0 then '+' else '' end || public.fmt_money(v_cents);
  v_rounded := v_exact <> trunc(v_exact);
  perform public.log_parent_action('correct_savings', p_account_id, v_id,
    'Corrected ' || (v_ctx ->> 'kid') || '''s savings: ' || v_signed || ', '
      || case when jsonb_typeof(v_line) = 'object'
              then 'fixing "' || (v_line ->> 'words') || '" on ' || (v_line ->> 'on') || '.'
              else 'about her question from ' || (v_question ->> 'asked_on') || '.' end,
    jsonb_build_object('cents', v_cents, 'typed', case when v_rounded then public.fmt_money4(v_exact) end,
                       'note', v_note, 'line_key', v_line ->> 'key', 'line', v_line ->> 'words',
                       'fixes', v_fixes, 'counts_as', v_counts,
                       'corrects_id', v_ctx -> '_tx_id', 'corrects_request_id', v_ctx -> '_request_id',
                       'question_id', v_ctx -> '_question_id',
                       'savings_before_cents', v_ctx -> 'savings_cents',
                       'savings_after_cents', (v_ctx ->> 'savings_cents')::bigint + v_cents));
  return v_id;
end;
$$;
comment on function public.correct_savings(uuid, text, bigint, text, text, text, text, text, uuid) is
  'Fix a mistake: a new, linked, noted savings line (rounded in her favour), her notice, and one parent_actions row. Parent with MFA only.';

-- 5. The preview -------------------------------------------------------------------------------------

-- What a correction would do: the real action, run with in_preview() on and rolled back.
-- p_args: account_id, line_key, question_id, direction, amount, note, counts_as.
-- warning: not a block, e.g. an addition larger than the line it fixes.
create function public.correction_preview(p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was text := coalesce(current_setting('bigbucks.preview', true), '');
  v_account uuid := nullif(p_args ->> 'account_id', '')::uuid;
  v_line_key text := p_args ->> 'line_key';
  v_question bigint := nullif(p_args ->> 'question_id', '')::bigint;
  v_ctx jsonb;
  v_problem text;
  v_cents bigint;
  v_exact numeric;
  v_line_cents bigint;
  v_last_notice bigint;
  v_last_action bigint;
  v_notices jsonb;
  v_summary text;
  v_counts text;
begin
  perform public.require_parent();

  begin
    v_ctx := public.correction_context(v_account, v_line_key, v_question);
  exception when others then
    v_problem := sqlerrm;
  end;

  if v_problem is null then
    begin
      select c.cents, c.exact_cents into v_cents, v_exact
        from public.correction_cents(p_args ->> 'direction', p_args ->> 'amount') c;
    exception when others then
      v_problem := sqlerrm;
    end;
  end if;

  if v_problem is null then
    select coalesce(max(n.id), 0) into v_last_notice from public.notifications n;
    select coalesce(max(pa.id), 0) into v_last_action from public.parent_actions pa;
    begin
      perform set_config('bigbucks.preview', 'on', true);
      -- The preview isn't the confirmation: it passes the amount as its own check.
      perform public.correct_savings(v_account, v_line_key, v_question, p_args ->> 'direction',
                                     p_args ->> 'amount', p_args ->> 'note', p_args ->> 'counts_as',
                                     p_args ->> 'amount', gen_random_uuid());
      select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body) order by n.id)
        into v_notices from public.notifications n where n.id > v_last_notice;
      select pa.summary, pa.details ->> 'counts_as' into v_summary, v_counts from public.parent_actions pa
       where pa.id > v_last_action order by pa.id desc limit 1;
      raise exception 'preview only' using errcode = 'BB000';
    exception
      when sqlstate 'BB000' then null;
      when others then
        v_problem := sqlerrm;
        v_notices := null;
        v_summary := null;
        v_counts := null;
    end;
    perform set_config('bigbucks.preview', v_was, true);
  end if;

  v_line_cents := abs((v_ctx -> 'line' ->> 'amount_cents')::bigint);
  return jsonb_build_object(
    'problem', v_problem,
    'warning', case when v_cents > 0 and v_line_cents is not null and v_cents > v_line_cents
                    then 'This is more than the line it fixes (' || public.fmt_money(v_line_cents) || '). Is that right?'
               end,
    'kid', v_ctx -> 'kid',
    'line', v_ctx -> 'line',
    'question', v_ctx -> 'question',
    'savings_cents', v_ctx -> 'savings_cents',
    'held_cents', v_ctx -> 'held_cents',
    'free_cents', v_ctx -> 'free_cents',
    'check_over_cents', v_ctx -> 'check_over_cents',
    'limit_cents', v_ctx -> 'limit_cents',
    'line_left_cents', v_ctx -> 'line_left_cents',
    'counts_as', coalesce(v_counts, v_ctx ->> 'counts_as'),
    'cents', v_cents,
    'typed', case when v_exact <> trunc(v_exact) then public.fmt_money4(v_exact) end,
    'rounded', coalesce(v_exact <> trunc(v_exact), false),
    'needs_check', coalesce(v_cents < 0, false),
    'needs_retype', coalesce(v_cents > (v_ctx ->> 'check_over_cents')::bigint, false),
    'savings_after_cents', case when v_problem is null then (v_ctx ->> 'savings_cents')::bigint + v_cents end,
    'free_after_cents', case when v_problem is null then (v_ctx ->> 'free_cents')::bigint + v_cents end,
    'summary', v_summary,
    'notices', coalesce(v_notices, '[]'::jsonb));
end;
$$;
comment on function public.correction_preview(jsonb) is
  'Fix a mistake: what a correction would do (the real action with in_preview() on, rolled back). Parent with MFA only.';

-- 6. Dad's list of her corrections ------------------------------------------------------------------

-- Every correction on her account, newest first: amount, note, what it fixes, how
-- the graphs count it, and who made it and when (from the log).
create function public.parent_corrections(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'cents', t.amount_cents, 'note', t.note, 'fixes', pa.details ->> 'fixes',
             'counts_as', coalesce(t.counts_as, 'earned'),
             'summary', pa.summary, 'who', p.display_name, 'when', public.fmt_moment(pa.done_at))
           order by t.id desc)
      from public.transactions t
      left join public.parent_actions pa on pa.action = 'correct_savings' and pa.target_id = t.id
      left join public.profiles p on p.user_id = pa.done_by
     where t.account_id = p_account_id and t.type = 'correction'), '[]'::jsonb);
end;
$$;

-- 7. The graphs count a correction like the line it fixes ---------------------------------------------
-- A correction with counts_as = 'money' is money in or out, like a deposit or
-- withdrawal; any other correction is earned. Each function below is its committed
-- body with only that change (marked "B3").

-- daily_balances from 20261002120000_reads.sql: net_flow_cents adds money corrections.
create or replace function public.daily_balances(p_account_id uuid, p_from date, p_to date)
returns table (balance_date date, savings_cents bigint, gic_cents bigint, stock_cents bigint,
               total_cents bigint, net_flow_cents bigint, fund_values jsonb)
language plpgsql stable
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.can_read_account(p_account_id) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  return query
  select dd.day,
         s.v,
         g.v,
         coalesce(fv.total, 0)::bigint,
         (s.v + g.v + coalesce(fv.total, 0))::bigint,
         nf.v,
         fv.obj
    from (select d::date as day from generate_series(p_from, p_to, interval '1 day') d) dd
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings'
         and t.effective_at < public.edmonton_start(dd.day + 1)) s
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'gic'
         and t.effective_at < public.edmonton_start(dd.day + 1)) g
    cross join lateral (
      select coalesce(sum(t.amount_cents), 0)::bigint as v from public.transactions t
       where t.account_id = p_account_id
         and (t.type in ('deposit', 'withdraw') or (t.type = 'correction' and t.counts_as = 'money')) -- B3
         and t.effective_at >= public.edmonton_start(dd.day)
         and t.effective_at < public.edmonton_start(dd.day + 1)) nf
    left join lateral (
      select sum(x.val)::bigint as total, jsonb_object_agg(x.fund_id, x.val) as obj
        from (select fu.id as fund_id, public.fund_value_at(p_account_id, fu.id, dd.day) as val
                from public.funds fu
               where exists (select 1 from public.transactions t
                              where t.account_id = p_account_id and t.fund_id = fu.id and t.vehicle = 'stock'
                                and t.effective_at < public.edmonton_start(dd.day + 1))) x) fv on true
   order by dd.day;
end;
$$;

-- growth_by_option from 20261010000000_graphs.sql: an earned correction is growth, not money moved.
create or replace function public.growth_by_option(p_account_id uuid, p_from date, p_to date)
returns table (day date, option text, growth_pct numeric, earned_cents bigint, flow_cents bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  r record;
  v_option text := null;
  v_prev bigint;
  v_factor numeric;
  v_earned bigint;
  v_started boolean;
  v_earn bigint;
  v_base bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3700 then
    raise exception 'Choose a date range of up to about 10 years.';
  end if;

  for r in
    with db as (
      select * from public.daily_balances(p_account_id, p_from, p_to)
    ),
    opts as (
      select 'savings'::text as option, null::text as fund_id, 0 as ord
      union all select 'gic', null, 1
      union all select fu.id, fu.id, 2 + fu.sort_order from public.funds fu
    ),
    -- Money moved in (+) or out (−) of each option, per day. Not growth.
    flows as (
      select public.edmonton_local(t.effective_at)::date as day,
             case when t.vehicle = 'savings' and t.fund_id is not null
                       and t.type in ('transfer_in', 'transfer_out') then t.fund_id
                  else t.vehicle::text end as option,
             sum(case when t.vehicle = 'savings' and t.fund_id is not null
                           and t.type in ('transfer_in', 'transfer_out') then -t.amount_cents
                      else t.amount_cents end) as flow
        from public.transactions t
       where t.account_id = p_account_id
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
         and (t.vehicle in ('savings', 'gic') and t.type not in ('interest', 'penalty')
              and not (t.type = 'correction' and coalesce(t.counts_as, 'earned') = 'earned') -- B3
              or t.vehicle = 'savings' and t.fund_id is not null and t.type in ('transfer_in', 'transfer_out'))
       group by 1, 2
      union all
      -- A fund buy or sale also moves money out of or into savings (the same row,
      -- seen from the savings side). Dividends are money into savings too.
      select public.edmonton_local(t.effective_at)::date, 'savings', sum(t.amount_cents)
        from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings' and t.fund_id is not null
         and t.type in ('transfer_in', 'transfer_out')
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
       group by 1
    ),
    -- Dividends: growth for the fund that paid them.
    dividends as (
      select public.edmonton_local(t.effective_at)::date as day, t.fund_id as option, sum(t.amount_cents) as amount
        from public.transactions t
       where t.account_id = p_account_id and t.vehicle = 'savings' and t.type = 'dividend'
         and t.effective_at >= public.edmonton_start(p_from)
         and t.effective_at < public.edmonton_start(p_to + 1)
       group by 1, 2
    )
    select db.balance_date as day, o.option, o.ord,
           case o.option when 'savings' then db.savings_cents
                         when 'gic' then db.gic_cents
                         else coalesce((db.fund_values ->> o.fund_id)::bigint, 0) end as v,
           coalesce((select sum(f.flow) from flows f where f.day = db.balance_date and f.option = o.option), 0)::bigint as flow,
           coalesce((select d.amount from dividends d where d.day = db.balance_date and d.option = o.option), 0)::bigint as extra
      from db cross join opts o
     order by o.ord, db.balance_date
  loop
    if v_option is distinct from r.option then
      v_option := r.option;
      v_prev := null;
      v_factor := 1;
      v_earned := 0;
      v_started := false;
    end if;

    if v_prev is null then
      -- The range's first day is where the line starts: 0%, nothing earned yet.
      v_earn := 0;
    else
      v_earn := r.v - v_prev - r.flow + r.extra;
      v_base := case when v_prev > 0 then v_prev when r.flow > 0 then r.flow else 0 end;
      if v_base > 0 then
        v_factor := round(v_factor * (1 + v_earn::numeric / v_base), 20);
      end if;
      v_earned := v_earned + v_earn;
    end if;

    -- A line starts the first day there's money in the option (or money moving).
    v_started := v_started or r.v <> 0 or r.flow <> 0 or coalesce(v_prev, 0) <> 0;
    if v_started then
      day := r.day;
      option := r.option;
      growth_pct := round((v_factor - 1) * 100, 2);
      earned_cents := v_earned;
      flow_cents := case when v_prev is null then 0 else r.flow end;
      return next;
    end if;
    v_prev := r.v;
  end loop;
end;
$$;


-- money_in_vs_earned from 20261010000000_graphs.sql: money corrections before the range count as money in.
create or replace function public.money_in_vs_earned(p_account_id uuid)
returns table (day date, net_deposits_cents bigint, total_cents bigint, earned_cents bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_from date;
  v_before bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;

  select min(public.edmonton_local(t.effective_at))::date into v_from
    from public.transactions t where t.account_id = p_account_id;
  if v_from is null or v_from > v_today then
    return;
  end if;
  v_from := greatest(v_from, v_today - 3650);

  -- Deposits minus withdrawals before the first day shown (none, unless she's been here 10 years).
  select coalesce(sum(t.amount_cents), 0)::bigint into v_before
    from public.transactions t
   where t.account_id = p_account_id
     and (t.type in ('deposit', 'withdraw') or (t.type = 'correction' and t.counts_as = 'money')) -- B3
     and t.effective_at < public.edmonton_start(v_from);

  return query
  select b.balance_date,
         (v_before + sum(b.net_flow_cents) over (order by b.balance_date))::bigint,
         b.total_cents,
         (b.total_cents - v_before - sum(b.net_flow_cents) over (order by b.balance_date))::bigint
    from public.daily_balances(p_account_id, v_from, v_today) b
   order by b.balance_date;
end;
$$;


-- Who may call them ---------------------------------------------------------------------------------

revoke all on function public.transactions_check_links() from public, anon, authenticated, service_role;
revoke all on function public.line_words(text, text, text, integer, numeric, text) from public, anon, authenticated, service_role;
revoke all on function public.correction_context(uuid, text, bigint) from public, anon, authenticated, service_role;
revoke all on function public.correction_dollars(text) from public, anon, authenticated, service_role;
revoke all on function public.correction_cents(text, text) from public, anon, authenticated, service_role;
revoke all on function public.correct_savings(uuid, text, bigint, text, text, text, text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.correction_preview(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.parent_corrections(uuid) from public, anon, authenticated, service_role;
revoke all on function public.my_activity(uuid, integer, timestamptz, text) from public, anon, authenticated, service_role;
grant execute on function public.correct_savings(uuid, text, bigint, text, text, text, text, text, uuid) to authenticated;
grant execute on function public.correction_preview(jsonb) to authenticated;
grant execute on function public.parent_corrections(uuid) to authenticated;
grant execute on function public.my_activity(uuid, integer, timestamptz, text) to authenticated, service_role;
