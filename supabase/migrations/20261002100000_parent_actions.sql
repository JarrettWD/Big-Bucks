-- Stage 2: what the parent can do. Every function requires a parent signed in
-- with MFA (aal2), checks the rules, then writes, in one transaction.

-- Approve a deposit or withdrawal. Withdrawals only after 24 hours; nothing
-- after the 7-day expiry. The ledger changes now, when the cash changes hands.
create function public.approve_request(p_request_id bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_now timestamptz := public.app_now();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.require_parent();

  select * into v_req from public.requests r where r.id = p_request_id for update;
  if not found then
    raise exception 'There''s no request %.', p_request_id;
  end if;
  perform 1 from public.accounts a where a.id = v_req.account_id for update;

  if v_req.status <> 'pending' then
    raise exception 'This request isn''t waiting for an answer (it''s %).', v_req.status;
  end if;
  if v_req.type = 'move' then
    raise exception 'Moves go through on their own: only deposits and withdrawals need your approval.';
  end if;
  if v_now >= v_req.created_at + interval '168 hours' then
    raise exception 'This request is more than 7 days old, so it has expired. She can make a new one.';
  end if;
  if v_req.type = 'withdraw' and v_now < v_req.created_at + interval '24 hours' then
    raise exception 'Withdrawals wait 24 hours before they can be approved. This one can be approved from %.',
      public.fmt_moment(v_req.created_at + interval '24 hours');
  end if;

  if v_req.type = 'deposit' then
    insert into public.transactions (account_id, vehicle, type, amount_cents, request_id, posting_key, note)
    values (v_req.account_id, 'savings', 'deposit', v_req.amount_cents, v_req.id, 'request:' || v_req.id, v_note);
    perform public.notify(v_req.account_id, 'request',
      'Your ' || public.fmt_money(v_req.amount_cents) || ' deposit is in!',
      concat_ws(' ', 'Dad approved it, so it''s in your savings now.', public.as_sentence(v_note)),
      'approved:' || v_req.id, p_request_id => v_req.id);
  else
    if public.vehicle_cents(v_req.account_id, 'savings') < v_req.amount_cents then
      raise exception 'Savings has less than the % this withdrawal needs. Please check the account.',
        public.fmt_money(v_req.amount_cents);
    end if;
    insert into public.transactions (account_id, vehicle, type, amount_cents, request_id, posting_key, note)
    values (v_req.account_id, 'savings', 'withdraw', -v_req.amount_cents, v_req.id, 'request:' || v_req.id, v_note);
    perform public.notify(v_req.account_id, 'request',
      'Your ' || public.fmt_money(v_req.amount_cents) || ' withdrawal is approved',
      concat_ws(' ', 'Dad approved taking it out of your savings.', public.as_sentence(v_note)),
      'approved:' || v_req.id, p_request_id => v_req.id);
  end if;

  update public.requests
     set status = 'approved', decided_at = v_now, parent_note = v_note
   where id = v_req.id;
end;
$$;

-- Decline a deposit or withdrawal, with a reason she will see. Releases any hold.
create function public.decline_request(p_request_id bigint, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.require_parent();
  if v_reason is null then
    raise exception 'Please give a reason, so she knows why.';
  end if;

  select * into v_req from public.requests r where r.id = p_request_id for update;
  if not found then
    raise exception 'There''s no request %.', p_request_id;
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request isn''t waiting for an answer (it''s %).', v_req.status;
  end if;
  if v_req.type = 'move' then
    raise exception 'Moves go through on their own: only deposits and withdrawals need your approval.';
  end if;

  update public.requests
     set status = 'declined', decided_at = public.app_now(), parent_note = v_reason
   where id = v_req.id;

  perform public.notify(v_req.account_id, 'request', 'Dad said not this time',
    'Your request to ' || case v_req.type when 'deposit' then 'put in ' else 'take out ' end
      || public.fmt_money(v_req.amount_cents) || ' wasn''t approved. Dad said: "' || v_reason || '"',
    'declined:' || v_req.id, p_request_id => v_req.id);
end;
$$;

-- Answer a "Something looks wrong?" question. The thread stays in her history.
create function public.answer_question(p_question_id bigint, p_reply text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.questions;
  v_reply text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  perform public.require_parent();
  if v_reply is null then
    raise exception 'Please write an answer.';
  end if;

  select * into v_q from public.questions q where q.id = p_question_id for update;
  if not found then
    raise exception 'There''s no question %.', p_question_id;
  end if;
  if v_q.status <> 'open' then
    raise exception 'This question is already answered.';
  end if;

  update public.questions
     set status = 'answered', parent_reply = v_reply, answered_at = public.app_now()
   where id = p_question_id;

  perform public.notify(v_q.account_id, 'question', 'Dad answered your question', v_reply,
    'question:' || p_question_id);
end;
$$;

-- Add a rate: savings or one GIC term, regular or a special (with an end date).
-- The effective date defaults to 7 days from today and can't be in the past.
-- Every kid is told right away; send_rate_notices tells them again on the day.
create function public.add_rate(
  p_vehicle public.vehicle, p_gic_term integer, p_rate numeric,
  p_effective_date date default null, p_note text default null, p_end_date date default null)
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

  if v_special then
    v_after := (public.rate_on(p_vehicle, p_gic_term, p_end_date + 1)).rate;
    v_title := 'Special: '
      || case when p_vehicle = 'savings' then 'savings' else public.term_label(p_gic_term) || ' GICs' end
      || ' at ' || public.fmt_rate(p_rate) || ' from ' || public.fmt_date(v_effective) || ' to ' || public.fmt_date(p_end_date);
    v_body := concat_ws(' ', v_note,
      'After ' || public.fmt_date(p_end_date) || ' the rate goes back to ' || public.fmt_rate(v_after) || '.',
      case when p_vehicle = 'gic' then 'A GIC bought during the special keeps ' || public.fmt_rate(p_rate) || ' until it matures.' end);
  else
    v_label := case when p_vehicle = 'savings' then 'Savings rate' else public.term_label(p_gic_term) || ' GIC rate' end;
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

-- Change a setting. Allowed keys: deposit_cap_cents, inflation_rate,
-- dividend_yield:<fund>, feature:<name>, market_move_note_up/down, launched_at.
-- The environment keys is_local_dev and clock_override are always refused, so the
-- time machine can never be switched on from the app.
create function public.set_setting(p_key text, p_value text, p_effective_date date default null, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_effective date := coalesce(p_effective_date, public.app_today());
  v_value text := btrim(coalesce(p_value, ''));
  v_key text := btrim(coalesce(p_key, ''));
  v_old_cap bigint;
  v_new_cap bigint;
  v_id bigint;
  v_account uuid;
begin
  perform public.require_parent();

  if v_key in ('is_local_dev', 'clock_override') then
    raise exception '"%" describes the computer the app runs on, so the app can never change it.', v_key
      using errcode = '42501';
  end if;
  if v_effective < v_today then
    raise exception 'A setting can''t start in the past.';
  end if;

  if v_key = 'deposit_cap_cents' then
    if v_value !~ '^\d{1,10}$' then
      raise exception 'The deposit cap must be a whole number of cents, like 100000 for $1,000.00.';
    end if;
    v_value := v_value::bigint::text;
  elsif v_key = 'inflation_rate' or v_key like 'dividend_yield:%' then
    if v_key like 'dividend_yield:%'
       and not exists (select 1 from public.funds f where f.id = substr(v_key, length('dividend_yield:') + 1)) then
      raise exception 'There''s no fund called "%".', substr(v_key, length('dividend_yield:') + 1);
    end if;
    if v_value !~ '^\d{1,2}(\.\d{1,3})?$' then
      raise exception 'Use a percent between 0 and 99.999, like 2.0.';
    end if;
  elsif v_key like 'feature:%' then
    if substr(v_key, length('feature:') + 1) !~ '^[a-z0-9_]+$' then
      raise exception 'Feature names use lowercase letters, numbers and _.';
    end if;
    if v_value not in ('off', 'test', 'everyone') then
      raise exception 'A feature switch is off, test or everyone.';
    end if;
  elsif v_key in ('market_move_note_up', 'market_move_note_down') then
    if v_value = '' or length(v_value) > 300 then
      raise exception 'The note needs some words, and at most 300 letters.';
    end if;
  elsif v_key = 'launched_at' then
    if exists (select 1 from public.settings s where s.key = 'launched_at') then
      raise exception 'Big Bucks has already launched; the launch time can''t change.';
    end if;
    begin
      perform v_value::timestamptz;
    exception when others then
      raise exception 'Use a date and time, like 2027-01-01 09:00.';
    end;
  else
    raise exception '"%" isn''t a setting Big Bucks knows about.', v_key;
  end if;

  if v_key = 'deposit_cap_cents' then
    v_old_cap := public.setting_on('deposit_cap_cents', v_effective - 1)::bigint;
    v_new_cap := v_value::bigint;
  end if;

  insert into public.settings (key, value, effective_date, note, changed_by)
  values (v_key, v_value, v_effective, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  if v_key = 'deposit_cap_cents' and v_new_cap is distinct from v_old_cap then
    for v_account in select a.id from public.accounts a loop
      perform public.notify(v_account, 'cap_change',
        'The deposit limit '
          || case when v_new_cap > coalesce(v_old_cap, 0) then 'goes up' else 'goes down' end
          || coalesce(' from ' || public.fmt_money(v_old_cap), '') || ' to ' || public.fmt_money(v_new_cap)
          || case when v_effective = v_today then ' today' else ' on ' || public.fmt_date(v_effective) end,
        concat_ws(' ', public.as_sentence(p_note),
          'This is the most you can put in, minus what you take out. Interest and gains don''t count.',
          case when v_new_cap < coalesce(v_old_cap, 0) then
            'If you''ve already put in more than that, nothing is taken away. You just can''t add more for now.' end),
        'cap_change:' || v_id || ':' || v_account);
    end loop;
  end if;
  return v_id;
end;
$$;

