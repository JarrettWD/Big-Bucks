-- Stage 8 part A: who did what, previews that stay inside the database, and the
-- Approvals screen's reads.
--
-- 1. parent_actions: an append-only log of every parent action, with who and when.
-- 2. The six parent actions are logged WITHOUT changing them. Each committed
--    function is renamed to <name>_unlogged, so its body stays byte for byte what
--    was committed (a test checks the fingerprints), and a new function with the
--    same name, arguments, defaults and result calls it and then writes one log
--    row, in the same transaction. If the action fails, nothing is logged.
-- 3. Previews: in_preview() is true while a preview's dry run is running. Anything
--    that ever reaches outside the database (push notifications, email, HTTP)
--    must do nothing when it is true. move_preview is wrapped the same way, so its
--    body doesn't change either.
-- 4. parent_inbox() and parent_decision_preview() for the Approvals screen.

-- 1. The log ---------------------------------------------------------------------------------------

create table public.parent_actions (
  id         bigint generated always as identity primary key,
  done_at    timestamptz not null default public.app_now(),
  done_by    uuid not null,
  action     text not null check (action in ('approve_request', 'decline_request', 'answer_question',
                                             'acknowledge_alert', 'add_rate', 'set_setting')),
  account_id uuid references public.accounts (id),
  target_id  bigint,
  summary    text not null check (btrim(summary) <> ''),
  details    jsonb not null default '{}'::jsonb
);
comment on table public.parent_actions is
  'Every parent action: who (done_by), when (done_at, app_now) and what, in plain words. Append-only. Parent only.';
comment on column public.parent_actions.target_id is
  'The request, question, alert, rate or setting the action was about (which one depends on action).';
create index parent_actions_recent_idx on public.parent_actions (done_at desc, id desc);

create trigger parent_actions_no_update_delete
  before update or delete on public.parent_actions
  for each row execute function public.reject_append_only_change();
create trigger parent_actions_no_truncate
  before truncate on public.parent_actions
  for each statement execute function public.reject_append_only_change();

alter table public.parent_actions enable row level security;
create policy parent_actions_read on public.parent_actions for select to authenticated
  using ((select public.is_parent()));
revoke all on public.parent_actions from public, anon, authenticated, service_role;
grant select on public.parent_actions to authenticated, service_role;

-- Internal: one log row. Only the logged parent functions call it.
create function public.log_parent_action(p_action text, p_account_id uuid, p_target_id bigint,
                                         p_summary text, p_details jsonb default '{}'::jsonb)
returns void
language sql
set search_path = ''
as $$
  insert into public.parent_actions (done_by, action, account_id, target_id, summary, details)
  values (auth.uid(), p_action, p_account_id, p_target_id, p_summary, coalesce(p_details, '{}'::jsonb));
$$;

-- 2. The six actions, logged ------------------------------------------------------------------------

alter function public.approve_request(bigint, text) rename to approve_request_unlogged;
alter function public.decline_request(bigint, text) rename to decline_request_unlogged;
alter function public.answer_question(bigint, text) rename to answer_question_unlogged;
alter function public.acknowledge_alert(bigint) rename to acknowledge_alert_unlogged;
alter function public.add_rate(public.vehicle, integer, numeric, date, text, date) rename to add_rate_unlogged;
alter function public.set_setting(text, text, date, text) rename to set_setting_unlogged;

create function public.approve_request(p_request_id bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  perform public.approve_request_unlogged(p_request_id, p_note);

  select * into v_req from public.requests r where r.id = p_request_id;
  perform public.log_parent_action('approve_request', v_req.account_id, v_req.id,
    'Approved ' || (select a.name from public.accounts a where a.id = v_req.account_id) || '''s '
      || public.fmt_money(v_req.amount_cents) || ' '
      || case v_req.type when 'deposit' then 'deposit' else 'withdrawal' end || '.',
    jsonb_build_object('type', v_req.type, 'amount_cents', v_req.amount_cents, 'note', v_req.parent_note));
end;
$$;

create function public.decline_request(p_request_id bigint, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  perform public.decline_request_unlogged(p_request_id, p_reason);

  select * into v_req from public.requests r where r.id = p_request_id;
  perform public.log_parent_action('decline_request', v_req.account_id, v_req.id,
    'Declined ' || (select a.name from public.accounts a where a.id = v_req.account_id) || '''s '
      || public.fmt_money(v_req.amount_cents) || ' '
      || case v_req.type when 'deposit' then 'deposit' else 'withdrawal' end || '.',
    jsonb_build_object('type', v_req.type, 'amount_cents', v_req.amount_cents, 'reason', v_req.parent_note));
end;
$$;

create function public.answer_question(p_question_id bigint, p_reply text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.questions;
begin
  perform public.answer_question_unlogged(p_question_id, p_reply);

  select * into v_q from public.questions q where q.id = p_question_id;
  perform public.log_parent_action('answer_question', v_q.account_id, v_q.id,
    'Answered ' || (select a.name from public.accounts a where a.id = v_q.account_id) || '''s question.',
    jsonb_build_object('question', v_q.message, 'reply', v_q.parent_reply,
                       'transaction_id', v_q.transaction_id));
end;
$$;

create function public.acknowledge_alert(p_alert_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alert public.alerts;
begin
  perform public.acknowledge_alert_unlogged(p_alert_id);

  select * into v_alert from public.alerts al where al.id = p_alert_id;
  perform public.log_parent_action('acknowledge_alert', v_alert.account_id, v_alert.id,
    'Acknowledged an alert: ' || v_alert.message,
    jsonb_build_object('kind', v_alert.kind, 'is_quiet', v_alert.is_quiet));
end;
$$;

create function public.add_rate(
  p_vehicle public.vehicle, p_gic_term integer, p_rate numeric,
  p_effective_date date default null, p_note text default null, p_end_date date default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_rate public.rates;
  v_what text;
begin
  v_id := public.add_rate_unlogged(p_vehicle, p_gic_term, p_rate, p_effective_date, p_note, p_end_date);

  select * into v_rate from public.rates r where r.id = v_id;
  v_what := case when v_rate.vehicle = 'savings' then 'savings' else public.term_label(v_rate.gic_term) || ' GIC' end;
  perform public.log_parent_action('add_rate', null, v_id,
    case when v_rate.is_special then
           'Special: ' || v_what || ' at ' || public.fmt_rate(v_rate.rate) || ' from '
           || public.fmt_date(v_rate.effective_date) || ' to ' || public.fmt_date(v_rate.end_date) || '.'
         else
           initcap(left(v_what, 1)) || substr(v_what, 2) || ' rate set to ' || public.fmt_rate(v_rate.rate)
           || ' from ' || public.fmt_date(v_rate.effective_date) || '.'
    end,
    jsonb_build_object('vehicle', v_rate.vehicle, 'gic_term', v_rate.gic_term, 'rate', v_rate.rate,
                       'effective_date', v_rate.effective_date, 'end_date', v_rate.end_date,
                       'is_special', v_rate.is_special, 'note', v_rate.note));
  return v_id;
end;
$$;

create function public.set_setting(p_key text, p_value text, p_effective_date date default null, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_s public.settings;
  v_from text;
begin
  v_id := public.set_setting_unlogged(p_key, p_value, p_effective_date, p_note);

  select * into v_s from public.settings s where s.id = v_id;
  v_from := ' from ' || public.fmt_date(v_s.effective_date) || '.';
  perform public.log_parent_action('set_setting', null, v_id,
    case
      when v_s.key = 'deposit_cap_cents' then 'Deposit cap set to ' || public.fmt_money(v_s.value::bigint) || v_from
      when v_s.key = 'inflation_rate' then 'Inflation rate set to ' || public.fmt_rate(v_s.value::numeric) || v_from
      when v_s.key like 'dividend_yield:%' then
        coalesce((select f.name from public.funds f where f.id = substr(v_s.key, length('dividend_yield:') + 1)), v_s.key)
        || ' dividend yield set to ' || public.fmt_rate(v_s.value::numeric) || v_from
      when v_s.key like 'feature:%' then
        'Feature "' || substr(v_s.key, length('feature:') + 1) || '" switched to '
        || case v_s.value when 'off' then 'off' when 'test' then 'test accounts only' else 'everyone' end || v_from
      when v_s.key = 'market_move_note_up' then 'Standard note for big up days changed' || v_from
      when v_s.key = 'market_move_note_down' then 'Standard note for big down days changed' || v_from
      when v_s.key = 'launched_at' then 'Launch time set to ' || v_s.value || '.'
      else 'Setting "' || v_s.key || '" changed' || v_from
    end,
    jsonb_build_object('key', v_s.key, 'value', v_s.value, 'effective_date', v_s.effective_date, 'note', v_s.note));
  return v_id;
end;
$$;

comment on function public.approve_request(bigint, text) is
  'Logged: approve_request_unlogged (unchanged from stage 2), then one parent_actions row.';
comment on function public.decline_request(bigint, text) is
  'Logged: decline_request_unlogged (unchanged from stage 2), then one parent_actions row.';
comment on function public.answer_question(bigint, text) is
  'Logged: answer_question_unlogged (unchanged from stage 2), then one parent_actions row.';
comment on function public.acknowledge_alert(bigint) is
  'Logged: acknowledge_alert_unlogged (unchanged from stage 3), then one parent_actions row.';
comment on function public.add_rate(public.vehicle, integer, numeric, date, text, date) is
  'Logged: add_rate_unlogged (unchanged from stage 2), then one parent_actions row.';
comment on function public.set_setting(text, text, date, text) is
  'Logged: set_setting_unlogged (unchanged from stage 2), then one parent_actions row.';

-- 3. Previews ---------------------------------------------------------------------------------------

-- True while a preview's dry run is running. The dry run is always rolled back, so
-- nothing it writes in the database survives; but anything that reaches OUTSIDE the
-- database (a push notification, an email, an HTTP call through pg_net or an Edge
-- Function) can't be rolled back. Such code must check this first and do nothing
-- when it's true. A test enforces it for every function that makes an HTTP call.
create function public.in_preview()
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce(current_setting('bigbucks.preview', true), '') = 'on';
$$;

-- Internal: run a preview with the flag on, then put it back.
alter function public.move_preview(text, bigint, text, bigint, integer, boolean) rename to move_preview_unflagged;

create function public.move_preview(p_kind text, p_amount_cents bigint default null, p_fund_id text default null,
                                    p_gic_id bigint default null, p_term integer default null,
                                    p_sell_all boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was text := coalesce(current_setting('bigbucks.preview', true), '');
  v_result jsonb;
begin
  perform set_config('bigbucks.preview', 'on', true);
  v_result := public.move_preview_unflagged(p_kind, p_amount_cents, p_fund_id, p_gic_id, p_term, p_sell_all);
  perform set_config('bigbucks.preview', v_was, true);
  return v_result;
end;
$$;
comment on function public.move_preview(text, bigint, text, bigint, integer, boolean) is
  'Buy / Sell preview: move_preview_unflagged (unchanged from stage 7), run with in_preview() true.';

-- 4. The Approvals screen ---------------------------------------------------------------------------

-- Everything the Approvals screen shows, for a parent with the authenticator code.
-- Every date and time is worked out here; the phone only counts the seconds down.
--   requests   deposits and withdrawals waiting for Dad
--   questions  open "Something looks wrong?" questions, with the history line
--   recent     the latest parent actions from the log: who, what and when
create function public.parent_inbox()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.app_now();
  v_requests jsonb;
  v_questions jsonb;
  v_recent jsonb;
begin
  perform public.require_parent();

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'account_id', r.account_id, 'kid', a.name, 'is_test', a.is_test,
           'type', r.type, 'amount_cents', r.amount_cents,
           'asked', public.fmt_moment(r.created_at),
           'approve_from', case when r.type = 'withdraw' then public.fmt_moment(r.created_at + interval '24 hours') end,
           'wait_seconds', greatest(0, ceil(extract(epoch from
                             (r.created_at + case when r.type = 'withdraw' then interval '24 hours' else interval '0' end)
                             - v_now)))::bigint,
           'expires', public.fmt_moment(r.created_at + interval '168 hours'),
           'expires_seconds', greatest(0, ceil(extract(epoch from r.created_at + interval '168 hours' - v_now)))::bigint,
           'savings_cents', b.savings_cents, 'held_cents', b.held_cents, 'available_cents', b.available_cents,
           'savings_after_cents', b.savings_cents + case when r.type = 'deposit' then r.amount_cents else -r.amount_cents end,
           'cap_cents', b.cap_cents, 'net_deposits_cents', b.net_deposits_cents,
           'pending_deposits_cents', b.pending_deposits_cents, 'cap_room_cents', b.cap_room_cents)
         order by a.is_test, r.created_at, r.id), '[]'::jsonb)
    into v_requests
    from public.requests r
    join public.accounts a on a.id = r.account_id
    join public.account_balances b on b.account_id = r.account_id
   where r.status = 'pending' and r.type in ('deposit', 'withdraw');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'account_id', q.account_id, 'kid', a.name, 'is_test', a.is_test,
           'message', q.message, 'asked', public.fmt_moment(q.created_at),
           'transaction_id', q.transaction_id,
           'line', (select to_jsonb(l) from public.my_activity(q.account_id, 100000) l
                     where q.transaction_id = any (l.transaction_ids) limit 1))
         order by a.is_test, q.created_at, q.id), '[]'::jsonb)
    into v_questions
    from public.questions q
    join public.accounts a on a.id = q.account_id
   where q.status = 'open';

  select coalesce(jsonb_agg(x.item order by x.done_at desc, x.id desc), '[]'::jsonb)
    into v_recent
    from (select pa.id, pa.done_at, jsonb_build_object(
                   'id', pa.id, 'action', pa.action, 'summary', pa.summary,
                   'who', coalesce(p.display_name, 'Someone'), 'when', public.fmt_moment(pa.done_at),
                   'kid', a.name, 'is_test', coalesce(a.is_test, false), 'details', pa.details) as item
            from public.parent_actions pa
            left join public.profiles p on p.user_id = pa.done_by
            left join public.accounts a on a.id = pa.account_id
           where pa.action in ('approve_request', 'decline_request', 'answer_question')
           order by pa.done_at desc, pa.id desc
           limit 20) x;

  return jsonb_build_object('now', public.fmt_moment(v_now), 'requests', v_requests,
                            'questions', v_questions, 'recent', v_recent);
end;
$$;
comment on function public.parent_inbox() is
  'Approvals screen: waiting deposits and withdrawals, open questions and recent decisions. Parent with MFA only.';

-- What a decision would do, without doing it: runs the real (logged) action in a
-- sub-transaction with in_preview() on, captures the notices she would get and the
-- log line, then always rolls it back. p_kind: approve · decline · answer.
-- Returns {problem, notices: [{title, body}], summary}. Leaves skipped id numbers,
-- like move_preview, and nothing else.
create function public.parent_decision_preview(p_kind text, p_id bigint, p_text text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was text := coalesce(current_setting('bigbucks.preview', true), '');
  v_last_notice bigint;
  v_last_action bigint;
  v_problem text;
  v_notices jsonb;
  v_summary text;
begin
  perform public.require_parent();
  if p_kind is null or p_kind not in ('approve', 'decline', 'answer') then
    raise exception 'Choose approve, decline or answer.';
  end if;

  select coalesce(max(n.id), 0) into v_last_notice from public.notifications n;
  select coalesce(max(pa.id), 0) into v_last_action from public.parent_actions pa;

  begin
    perform set_config('bigbucks.preview', 'on', true);
    case p_kind
      when 'approve' then perform public.approve_request(p_id, p_text);
      when 'decline' then perform public.decline_request(p_id, p_text);
      when 'answer' then perform public.answer_question(p_id, p_text);
    end case;
    select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body) order by n.id)
      into v_notices from public.notifications n where n.id > v_last_notice;
    select pa.summary into v_summary from public.parent_actions pa
     where pa.id > v_last_action order by pa.id desc limit 1;
    raise exception 'preview only' using errcode = 'BB000';
  exception
    when sqlstate 'BB000' then v_problem := null;
    when others then
      v_problem := sqlerrm;
      v_notices := null;
      v_summary := null;
  end;
  perform set_config('bigbucks.preview', v_was, true);

  return jsonb_build_object('problem', v_problem, 'notices', coalesce(v_notices, '[]'::jsonb), 'summary', v_summary);
end;
$$;
comment on function public.parent_decision_preview(text, bigint, text) is
  'Approvals screen: what approving, declining or answering would do (the real action, rolled back). Parent with MFA only.';

-- Who may call them -------------------------------------------------------------------------------

revoke all on function public.log_parent_action(text, uuid, bigint, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.approve_request_unlogged(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.decline_request_unlogged(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.answer_question_unlogged(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.acknowledge_alert_unlogged(bigint) from public, anon, authenticated, service_role;
revoke all on function public.add_rate_unlogged(public.vehicle, integer, numeric, date, text, date)
  from public, anon, authenticated, service_role;
revoke all on function public.set_setting_unlogged(text, text, date, text) from public, anon, authenticated, service_role;
revoke all on function public.move_preview_unflagged(text, bigint, text, bigint, integer, boolean)
  from public, anon, authenticated, service_role;

revoke all on function public.approve_request(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.decline_request(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.answer_question(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.acknowledge_alert(bigint) from public, anon, authenticated, service_role;
revoke all on function public.add_rate(public.vehicle, integer, numeric, date, text, date)
  from public, anon, authenticated, service_role;
revoke all on function public.set_setting(text, text, date, text) from public, anon, authenticated, service_role;
revoke all on function public.move_preview(text, bigint, text, bigint, integer, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.in_preview() from public, anon, authenticated, service_role;
revoke all on function public.parent_inbox() from public, anon, authenticated, service_role;
revoke all on function public.parent_decision_preview(text, bigint, text) from public, anon, authenticated, service_role;

-- The same grants the committed functions had: each checks who is calling inside.
grant execute on function public.approve_request(bigint, text) to authenticated;
grant execute on function public.decline_request(bigint, text) to authenticated;
grant execute on function public.answer_question(bigint, text) to authenticated;
grant execute on function public.acknowledge_alert(bigint) to authenticated;
grant execute on function public.add_rate(public.vehicle, integer, numeric, date, text, date) to authenticated;
grant execute on function public.set_setting(text, text, date, text) to authenticated;
grant execute on function public.move_preview(text, bigint, text, bigint, integer, boolean) to authenticated;
grant execute on function public.in_preview() to authenticated, service_role;
grant execute on function public.parent_inbox() to authenticated;
grant execute on function public.parent_decision_preview(text, bigint, text) to authenticated;
