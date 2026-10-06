-- Stage 8 B4: onboarding, the account agreement and "What's new".
--
-- 1. house_rules(): every number the kid wording uses, read from the settings in
--    force (cap, request expiry, rates) and the engine's own fixed rules (minimums,
--    the 24-hour wait, the 7-day periods). A test proves the fixed ones match what
--    the engine enforces, so the wording can never disagree with a rule.
-- 2. The agreement: append-only versions (the rules, with placeholders) and
--    signatures. Her signature keeps a frozen copy, numbers filled in. Dad
--    countersigns on his own phone (logged). A new or reworded rule is a new
--    version for both to sign; earlier ones stay in her history. A changed number
--    reaches her by that change's own notice.
-- 3. She must sign before her first deposit (Dad, 2026-10-05): request_deposit is
--    wrapped like Part A's functions. The committed body is renamed
--    request_deposit_core, unchanged, and nobody can call it directly.
-- 4. Onboarding state, finishing onboarding, and What's new: a feature switched on
--    after she onboarded reaches her once through What's new; a girl onboarding
--    after it's on meets it in onboarding instead.
-- Wording: docs/MESSAGES.md §11 (reviewed by Dad 2026-10-05).

alter type public.notification_type add value if not exists 'agreement';

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement'));

-- 1. The numbers in the house rules -----------------------------------------------------------------

-- Every {placeholder} the kid wording uses, as shown to her today. The fixed rules
-- (cut notice, the withdrawal wait, minimums, the GIC choice and wish-list waits)
-- are the engine's own values; house_rules_test proves each one matches the engine.
create function public.house_rules()
returns jsonb
language sql stable
set search_path = ''
as $$
  with g as (
    select min(r.rate) as lo, max(r.rate) as hi
      from unnest(array[1, 3, 6, 9, 12, 24]) as t(term)
     cross join lateral public.rate_on('gic', t.term, public.app_today()) r)
  select jsonb_build_object(
    'cap', public.fmt_money(coalesce(public.setting_on('deposit_cap_cents', public.app_today()), '0')::bigint),
    'expiry_days', public.setting_on('request_expiry_days', public.app_today()),
    'savings_rate', public.fmt_rate((public.rate_on('savings', null, public.app_today())).rate),
    'gic_lowest', public.fmt_rate(g.lo),
    'gic_highest', public.fmt_rate(g.hi),
    'cut_notice_days', '7',
    'withdraw_wait_hours', '24',
    'min_savings', public.fmt_money(500),
    'min_invest', public.fmt_money(1000),
    'gic_choice_days', '7',
    'goal_wait_days', '7')
  from g;
$$;
comment on function public.house_rules() is
  'Every number in the kid wording (MESSAGES §11), from the settings in force and the engine''s fixed rules.';

-- {cap} and the rest, filled in from house_rules().
create function public.fill_house_rules(p_text text, p_rules jsonb)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text := p_text;
  r record;
begin
  for r in select key, value from jsonb_each_text(p_rules) loop
    v := replace(v, '{' || r.key || '}', r.value);
  end loop;
  return v;
end;
$$;

-- 2. The agreement --------------------------------------------------------------------------------

-- Each version of the house rules. rules: [{icon, title, text, glossary?, if_off?
-- {feature, text}, mark? ('new' or 'changed')}]. Placeholders are filled in when
-- she reads or signs it. A new version comes in its own migration, with
-- agreement_changed_notices() for the girls who signed an earlier one.
create table public.agreement_versions (
  version    integer primary key check (version >= 1),
  intro      text not null check (btrim(intro) <> ''),
  rules      jsonb not null check (jsonb_typeof(rules) = 'array' and jsonb_array_length(rules) > 0),
  promises   text not null check (btrim(promises) <> ''),
  sign_line  text not null check (btrim(sign_line) <> ''),
  created_at timestamptz not null default public.app_now()
);
comment on table public.agreement_versions is
  'The house rules, one row per version (append-only). Wording: docs/MESSAGES.md §11.';

-- Her signature (with the frozen copy she saw) and Dad's countersignature.
create table public.agreement_signatures (
  id         bigint generated always as identity primary key,
  account_id uuid not null references public.accounts (id),
  version    integer not null references public.agreement_versions (version),
  signer     text not null check (signer in ('kid', 'parent')),
  signed_by  uuid not null,
  signed_at  timestamptz not null default public.app_now(),
  copy       jsonb,
  constraint sig_kid_keeps_copy check ((signer = 'kid') = (copy is not null)),
  unique (account_id, version, signer)
);
comment on table public.agreement_signatures is
  'Who signed which agreement version, and when (append-only). A kid''s row keeps the rules exactly as she saw them.';
create index agreement_signatures_account_idx on public.agreement_signatures (account_id, version);

create trigger agreement_versions_no_update_delete before update or delete on public.agreement_versions
  for each row execute function public.reject_append_only_change();
create trigger agreement_versions_no_truncate before truncate on public.agreement_versions
  for each statement execute function public.reject_append_only_change();
create trigger agreement_signatures_no_update_delete before update or delete on public.agreement_signatures
  for each row execute function public.reject_append_only_change();
create trigger agreement_signatures_no_truncate before truncate on public.agreement_signatures
  for each statement execute function public.reject_append_only_change();

alter table public.agreement_versions enable row level security;
alter table public.agreement_signatures enable row level security;
create policy agreement_versions_read on public.agreement_versions for select to authenticated using (true);
create policy agreement_signatures_read on public.agreement_signatures for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
revoke all on public.agreement_versions, public.agreement_signatures from public, anon, authenticated, service_role;
grant select on public.agreement_versions, public.agreement_signatures to authenticated, service_role;

-- Version 1: Dad's reviewed wording (MESSAGES §11, 2026-10-05).
insert into public.agreement_versions (version, intro, rules, promises, sign_line, created_at) values (1,
  'These are the house rules. Read them with Dad, and ask about anything that doesn''t make sense. When you both agree, you each sign. A copy stays in your history.',
  $rules$[
    {"icon": "💵", "title": "The money is real.",
     "text": "Dad keeps the cash, and Big Bucks keeps track of every cent he owes you."},
    {"icon": "🐷", "title": "New money goes into savings first.",
     "text": "You can put in up to {cap} altogether. Taking money out gives you room again. Interest and growth don't count, so your money can grow past {cap}."},
    {"icon": "🎁", "title": "Birthday money and allowance can go in too.",
     "text": "Ask for a deposit the usual way, and it has to fit under your deposit cap."},
    {"icon": "🙋", "title": "Dad says yes first",
     "text": "when money goes in or out, because real cash changes hands. Dad has up to {expiry_days} days to answer. If he hasn't answered by then, the request is cancelled and you can ask again."},
    {"icon": "😴", "title": "Sleep on it.",
     "text": "When you ask to take money out, Dad waits at least {withdraw_wait_hours} hours before he can say yes, so you have time to think it over."},
    {"icon": "✋", "title": "Money on hold.", "glossary": "On hold",
     "text": "While a request is waiting, its money is on hold, so you can't use the same money twice."},
    {"icon": "🔢", "title": "The smallest amounts",
     "text": "are {min_savings} for savings, and {min_invest} for a GIC or a stock fund."},
    {"icon": "🔒", "title": "A GIC is a promise.",
     "text": "You leave the money for the whole term. If you break the promise early, you get your money back but you lose all its interest. When a GIC finishes, you have {gic_choice_days} days to choose what's next, or it moves to your savings."},
    {"icon": "📉", "title": "Stock funds go up and down, and losses are real.",
     "text": "If a fund is worth less when you sell, you get less. A big drop can turn $100 into $80, and sometimes less, for a while. Markets have usually come back, but it can take a long time."},
    {"icon": "📈", "title": "One trade per fund each day.",
     "text": "You can buy or sell each fund once a day. Buys and sells happen at the next market close."},
    {"icon": "📣", "title": "Rates can change",
     "text": ", like at a real bank. If a rate or your deposit cap is going down, Big Bucks tells you at least {cut_notice_days} days before. Good news, like a higher rate, can start right away. A GIC you already have keeps its rate."},
    {"icon": "⚖️", "title": "Fair for both of you.",
     "text": "You and your sister get the same rates and the same rules."},
    {"icon": "🔍", "title": "Ask any time.",
     "text": "If something ever looks wrong, tap \"Something looks wrong?\" and Dad will answer. If there's a mistake, Dad fixes it openly, with a note you can read, and rounding always goes your way."},
    {"icon": "🔑", "title": "Your PIN is yours.",
     "text": "Don't share it, not even with your sister. If you think someone knows it, tell Dad."},
    {"icon": "👀", "title": "Mom and Dad can see your account.",
     "text": "They can look at your Big Bucks screens any time, just like your wish list.",
     "if_off": {"feature": "wishlist", "text": "They can look at your Big Bucks screens any time."}}
  ]$rules$::jsonb,
  'Dad keeps your cash safe, answers your requests, and fixes any mistake openly, with a note, rounding in your favour.',
  'I''ve read these rules with Dad, and I agree.',
  timestamptz '2026-01-01 00:00:00-07');

-- One version, as she reads it today: numbers filled in, and the wish-list
-- sentence only if her Wish List is on.
create function public.agreement_render(p_version integer, p_account_id uuid)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v public.agreement_versions;
  h jsonb := public.house_rules();
  r jsonb;
  t text;
  v_rules jsonb := '[]'::jsonb;
begin
  select * into v from public.agreement_versions a where a.version = p_version;
  if not found then
    raise exception 'There''s no agreement version %.', p_version;
  end if;
  for r in select x from jsonb_array_elements(v.rules) x loop
    t := r ->> 'text';
    if r ? 'if_off' and not coalesce(public.feature_enabled(r -> 'if_off' ->> 'feature', p_account_id), false) then
      t := r -> 'if_off' ->> 'text';
    end if;
    v_rules := v_rules || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'icon', r ->> 'icon',
      'title', public.fill_house_rules(r ->> 'title', h),
      'text', public.fill_house_rules(t, h),
      'glossary', r ->> 'glossary',
      'mark', r ->> 'mark')));
  end loop;
  return jsonb_build_object(
    'version', v.version,
    'title', case when v.version = 1 then 'Your Big Bucks agreement'
                  else 'Your Big Bucks agreement (version ' || v.version || ')' end,
    'intro', public.fill_house_rules(v.intro, h),
    'rules', v_rules,
    'promises', v.promises,
    'sign_line', v.sign_line,
    'name', (select a.name from public.accounts a where a.id = p_account_id));
end;
$$;

-- Internal, for the migration that adds a new version: tells each girl who signed
-- an earlier version (and not this one) that the rules changed.
create function public.agreement_changed_notices(p_version integer)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer := 0;
  r record;
begin
  for r in
    select distinct s.account_id from public.agreement_signatures s
     where s.signer = 'kid' and s.version < p_version
       and not exists (select 1 from public.agreement_signatures n
                        where n.account_id = s.account_id and n.version = p_version and n.signer = 'kid')
  loop
    perform public.notify(r.account_id, 'agreement', 'Your Big Bucks agreement has changed',
      'Dad changed the house rules. Read the new version with Dad, and sign it when you both agree. Your old agreement stays in your history.',
      'agreement_changed:' || r.account_id || ':' || p_version);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- 3. She signs before her first deposit ----------------------------------------------------------

alter function public.request_deposit(bigint) rename to request_deposit_core;

create function public.request_deposit(p_amount_cents bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
begin
  if not exists (select 1 from public.agreement_signatures s where s.account_id = v_account and s.signer = 'kid') then
    raise exception 'Before you can put money in, sign your Big Bucks agreement with Dad.';
  end if;
  return public.request_deposit_core(p_amount_cents);
end;
$$;
comment on function public.request_deposit(bigint) is
  'A deposit request: only once she has signed the agreement, then request_deposit_core (unchanged from stage 2).';

-- 4. Onboarding and What's new -------------------------------------------------------------------

-- Each feature's one-screen What's new (MESSAGES §11). lines may use placeholders.
create table public.whats_new_features (
  feature text primary key,
  title   text not null check (btrim(title) <> ''),
  lines   jsonb not null check (jsonb_typeof(lines) = 'array'),
  link    text
);
insert into public.whats_new_features (feature, title, lines, link) values
  ('wishlist', 'New: your Wish List ⭐', $l$[
     "Add things you'd love to have, give each one stars, and see how close you are to affording it.",
     "If you still want something after {goal_wait_days} days, you can make it a savings goal.",
     "Mom and Dad can see your wish list."]$l$::jsonb, '/kid/wishlist'),
  ('personalisation', 'New: make Big Bucks yours 🎨', $l$[
     "Pick your own colour and a cute animal.",
     "You can change them any time."]$l$::jsonb, null),
  ('badges', 'New: badges 🏅', $l$[
     "You earn a badge for smart money choices, like keeping a GIC until it finishes or staying calm when a fund drops.",
     "Each badge unlocks something fun for your animal to wear."]$l$::jsonb, null);

-- Which What's new screens she has seen (or met in onboarding instead).
create table public.whats_new_seen (
  account_id uuid not null references public.accounts (id),
  feature    text not null references public.whats_new_features (feature),
  seen_at    timestamptz not null default public.app_now(),
  primary key (account_id, feature)
);
create trigger whats_new_seen_no_update_delete before update or delete on public.whats_new_seen
  for each row execute function public.reject_append_only_change();
create trigger whats_new_features_no_update_delete before update or delete on public.whats_new_features
  for each row execute function public.reject_append_only_change();

alter table public.whats_new_features enable row level security;
alter table public.whats_new_seen enable row level security;
create policy whats_new_features_read on public.whats_new_features for select to authenticated using (true);
create policy whats_new_seen_read on public.whats_new_seen for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));
revoke all on public.whats_new_features, public.whats_new_seen from public, anon, authenticated, service_role;
grant select on public.whats_new_features, public.whats_new_seen to authenticated, service_role;

-- Everything the welcome screens need, for her (or Dad viewing her).
create function public.onboarding_state(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_acct public.accounts;
  v_current integer;
  v_signed integer;
  v_first bigint;
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  select * into v_acct from public.accounts a where a.id = p_account_id;
  select max(av.version) into v_current from public.agreement_versions av;
  select max(s.version) into v_signed from public.agreement_signatures s
   where s.account_id = p_account_id and s.signer = 'kid';
  select t.amount_cents into v_first from public.transactions t
   where t.account_id = p_account_id and t.type = 'deposit' order by t.effective_at, t.id limit 1;

  return jsonb_build_object(
    'name', v_acct.name,
    'done', v_acct.onboarding_done_at is not null,
    'current_version', v_current,
    'signed_version', v_signed,
    'countersigned', exists (select 1 from public.agreement_signatures s
                              where s.account_id = p_account_id and s.signer = 'parent' and s.version = v_signed),
    'needs_signature', v_signed is distinct from v_current,
    'steps', to_jsonb(array_remove(array[
               'welcome', 'tour',
               case when public.feature_enabled('personalisation', p_account_id) then 'personalise' end,
               case when public.feature_enabled('wishlist', p_account_id) then 'wish' end,
               'agreement', 'decision'], null)),
    'agreement', public.agreement_render(v_current, p_account_id),
    'first_deposit_cents', v_first,
    'free_cents', public.vehicle_cents(p_account_id, 'savings') - public.held_cents(p_account_id),
    'min_invest_cents', 1000,
    'rules', public.house_rules());
end;
$$;

-- She signs the latest version. Her copy is frozen, numbers included.
create function public.sign_agreement(p_version integer)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_id bigint;
begin
  perform 1 from public.accounts a where a.id = v_account for update;
  if p_version is distinct from (select max(av.version) from public.agreement_versions av) then
    raise exception 'That isn''t the latest agreement. Please go back and read the latest one.';
  end if;
  if exists (select 1 from public.agreement_signatures s
              where s.account_id = v_account and s.version = p_version and s.signer = 'kid') then
    raise exception 'You''ve already signed this agreement.';
  end if;
  insert into public.agreement_signatures (account_id, version, signer, signed_by, copy)
  values (v_account, p_version, 'kid', auth.uid(), public.agreement_render(p_version, v_account))
  returning id into v_id;
  update public.accounts set agreement_signed_at = public.app_now() where id = v_account;
  return v_id;
end;
$$;

-- Onboarding is done (after her first decision, or choosing to keep it in savings).
-- Every feature already on for her was met in onboarding, so What's new skips it.
create function public.finish_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
begin
  if not exists (select 1 from public.agreement_signatures s where s.account_id = v_account and s.signer = 'kid') then
    raise exception 'Sign your Big Bucks agreement with Dad first.';
  end if;
  update public.accounts set onboarding_done_at = coalesce(onboarding_done_at, public.app_now()) where id = v_account;
  insert into public.whats_new_seen (account_id, feature)
  select v_account, f.feature from public.whats_new_features f
   where public.feature_enabled(f.feature, v_account)
  on conflict do nothing;
end;
$$;

-- Her signed agreements, newest first, exactly as signed.
create function public.my_agreements(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'version', k.version, 'copy', k.copy,
             'signed_on', public.fmt_date(public.edmonton_local(k.signed_at)::date),
             'dad_signed_on', (select public.fmt_date(public.edmonton_local(p.signed_at)::date)
                                 from public.agreement_signatures p
                                where p.account_id = k.account_id and p.version = k.version and p.signer = 'parent'))
           order by k.version desc)
      from public.agreement_signatures k
     where k.account_id = p_account_id and k.signer = 'kid'), '[]'::jsonb);
end;
$$;

-- What's new she hasn't seen, for features switched on for her after she onboarded.
-- Each also lands in her bell once (the same title).
create function public.whats_new()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  h jsonb := public.house_rules();
  r record;
  v_out jsonb := '[]'::jsonb;
  v_lines jsonb;
begin
  if (select a.onboarding_done_at from public.accounts a where a.id = v_account) is null then
    return v_out;
  end if;
  for r in
    select f.* from public.whats_new_features f
     where public.feature_enabled(f.feature, v_account)
       and not exists (select 1 from public.whats_new_seen s where s.account_id = v_account and s.feature = f.feature)
     order by f.feature
  loop
    select jsonb_agg(public.fill_house_rules(l, h) order by n) into v_lines
      from jsonb_array_elements_text(r.lines) with ordinality x(l, n);
    perform public.notify(v_account, 'whats_new', r.title,
      (select string_agg(l, ' ' order by n) from jsonb_array_elements_text(v_lines) with ordinality y(l, n)),
      'whats_new:' || r.feature || ':' || v_account);
    v_out := v_out || jsonb_build_array(jsonb_build_object('feature', r.feature, 'title', r.title,
                                                           'lines', v_lines, 'link', r.link));
  end loop;
  return v_out;
end;
$$;

create function public.mark_whats_new_seen(p_feature text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
begin
  if not exists (select 1 from public.whats_new_features f where f.feature = p_feature) then
    raise exception 'There''s no "%" to mark as seen.', p_feature;
  end if;
  insert into public.whats_new_seen (account_id, feature) values (v_account, p_feature) on conflict do nothing;
end;
$$;

-- 5. Dad's side ------------------------------------------------------------------------------------

-- Dad countersigns the version she signed, on his own phone. Logged; she's told.
create function public.countersign_agreement(p_account_id uuid, p_version integer)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_id bigint;
begin
  perform public.require_parent();
  select a.name into v_name from public.accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'There''s no such account.';
  end if;
  if not exists (select 1 from public.agreement_signatures s
                  where s.account_id = p_account_id and s.version = p_version and s.signer = 'kid') then
    raise exception '% hasn''t signed this agreement yet.', v_name;
  end if;
  if exists (select 1 from public.agreement_signatures s
              where s.account_id = p_account_id and s.version = p_version and s.signer = 'parent') then
    raise exception 'You''ve already signed %''s agreement.', v_name;
  end if;
  insert into public.agreement_signatures (account_id, version, signer, signed_by)
  values (p_account_id, p_version, 'parent', auth.uid())
  returning id into v_id;
  perform public.notify(p_account_id, 'agreement', 'Your agreement is signed!',
    'Dad signed it too. You can read it any time in your history.',
    'agreement_signed:' || p_account_id || ':' || p_version);
  perform public.log_parent_action('countersign_agreement', p_account_id, v_id,
    'Signed ' || v_name || '''s Big Bucks agreement'
      || case when p_version > 1 then ' (version ' || p_version || ')' else '' end || '.',
    jsonb_build_object('version', p_version));
  return v_id;
end;
$$;

-- What countersigning would do, with her signed copy for Dad to read. The real
-- action, run with in_preview() on and rolled back.
create function public.agreement_preview(p_account_id uuid, p_version integer)
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
  select coalesce(max(n.id), 0) into v_last_notice from public.notifications n;
  select coalesce(max(pa.id), 0) into v_last_action from public.parent_actions pa;
  begin
    perform set_config('bigbucks.preview', 'on', true);
    perform public.countersign_agreement(p_account_id, p_version);
    select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body) order by n.id)
      into v_notices from public.notifications n where n.id > v_last_notice;
    select pa.summary into v_summary from public.parent_actions pa
     where pa.id > v_last_action order by pa.id desc limit 1;
    raise exception 'preview only' using errcode = 'BB000';
  exception
    when sqlstate 'BB000' then null;
    when others then
      v_problem := sqlerrm;
      v_notices := null;
      v_summary := null;
  end;
  perform set_config('bigbucks.preview', v_was, true);
  return jsonb_build_object(
    'problem', v_problem,
    'summary', v_summary,
    'notices', coalesce(v_notices, '[]'::jsonb),
    'copy', (select s.copy from public.agreement_signatures s
              where s.account_id = p_account_id and s.version = p_version and s.signer = 'kid'));
end;
$$;

-- Each girl's onboarding and agreement, for the dashboard and Approvals: real kids first.
create function public.parent_agreements()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'account_id', a.id, 'kid', a.name, 'is_test', a.is_test,
             'onboarding_done', a.onboarding_done_at is not null,
             'current_version', (select max(av.version) from public.agreement_versions av),
             'signed_version', k.version,
             'signed_at', public.fmt_moment(k.signed_at),
             'dad_signed_at', (select public.fmt_moment(p.signed_at) from public.agreement_signatures p
                                where p.account_id = a.id and p.version = k.version and p.signer = 'parent'))
           order by a.is_test, a.name)
      from public.accounts a
      left join lateral (select s.version, s.signed_at from public.agreement_signatures s
                          where s.account_id = a.id and s.signer = 'kid'
                          order by s.version desc limit 1) k on true), '[]'::jsonb);
end;
$$;

-- "View as" can show her onboarding and her signed agreements (reads only).
create or replace function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  r jsonb;
begin
  perform public.require_parent();
  if p_account is null or not exists (select 1 from public.accounts x where x.id = p_account) then
    raise exception 'There''s no account to view.';
  end if;

  case p_read
    when 'account' then
      select jsonb_build_object('account_id', x.id, 'name', x.name, 'is_test', x.is_test)
        into r from public.accounts x where x.id = p_account;
    when 'app_today' then
      r := to_jsonb(public.app_today());
    -- Her Home: the same rows her app reads from these views and her notices.
    when 'balances' then
      select to_jsonb(b) into r from public.account_balances b where b.account_id = p_account;
    when 'home_gics' then
      select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]'::jsonb) into r
        from public.gic_positions g
       where g.account_id = p_account
         and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null));
    when 'unread_notices' then
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                                                   'related_gic_id', n.related_gic_id)
                                order by n.created_at desc, n.id desc), '[]'::jsonb) into r
        from public.notifications n where n.account_id = p_account and n.read_at is null;
    when 'unread_count' then
      r := to_jsonb((select count(*) from public.notifications n where n.account_id = p_account and n.read_at is null));
    when 'figures_updating' then
      r := to_jsonb(public.figures_updating(p_account));
    when 'feature_enabled' then
      r := to_jsonb(public.feature_enabled(a ->> 'p_feature', p_account));
    when 'current_rates' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.current_rates() with ordinality t;
    when 'fund_overview' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.fund_overview(p_account) with ordinality t;
    when 'my_activity' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_activity(p_account, coalesce((a ->> 'p_limit')::integer, 20),
                                (a ->> 'p_before_at')::timestamptz, a ->> 'p_before_key') with ordinality t;
    when 'my_notices' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_notices(p_account, coalesce((a ->> 'p_limit')::integer, 50),
                               (a ->> 'p_before_id')::bigint) with ordinality t;
    when 'my_questions' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_questions(p_account) with ordinality t;
    -- B4: her onboarding and her signed agreements.
    when 'onboarding_state' then
      r := public.onboarding_state(p_account);
    when 'my_agreements' then
      r := public.my_agreements(p_account);
    -- Her Graphs.
    when 'graph_ranges' then
      r := public.graph_ranges(p_account);
    when 'daily_balances' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.daily_balances(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'growth_by_option' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.growth_by_option(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'money_in_vs_earned' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.money_in_vs_earned(p_account) with ordinality t;
    when 'my_mix' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_mix(p_account) with ordinality t;
    when 'gic_ladder' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.gic_ladder(p_account) with ordinality t;
    when 'fund_chart' then
      r := public.fund_chart(p_account, a ->> 'p_fund_id', (a ->> 'p_from')::date);
    else
      raise exception 'There''s no "%" to view.', p_read;
  end case;
  return r;
end;
$$;

-- Who may call them ---------------------------------------------------------------------------------

revoke all on function public.house_rules() from public, anon, authenticated, service_role;
revoke all on function public.fill_house_rules(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.agreement_render(integer, uuid) from public, anon, authenticated, service_role;
revoke all on function public.agreement_changed_notices(integer) from public, anon, authenticated, service_role;
revoke all on function public.request_deposit_core(bigint) from public, anon, authenticated, service_role;
revoke all on function public.request_deposit(bigint) from public, anon, authenticated, service_role;
revoke all on function public.onboarding_state(uuid) from public, anon, authenticated, service_role;
revoke all on function public.sign_agreement(integer) from public, anon, authenticated, service_role;
revoke all on function public.finish_onboarding() from public, anon, authenticated, service_role;
revoke all on function public.my_agreements(uuid) from public, anon, authenticated, service_role;
revoke all on function public.whats_new() from public, anon, authenticated, service_role;
revoke all on function public.mark_whats_new_seen(text) from public, anon, authenticated, service_role;
revoke all on function public.countersign_agreement(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.agreement_preview(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.parent_agreements() from public, anon, authenticated, service_role;

-- request_deposit keeps the committed grant (kids; it checks who is calling inside).
grant execute on function public.request_deposit(bigint) to authenticated;
grant execute on function public.onboarding_state(uuid) to authenticated;
grant execute on function public.sign_agreement(integer) to authenticated;
grant execute on function public.finish_onboarding() to authenticated;
grant execute on function public.my_agreements(uuid) to authenticated;
grant execute on function public.whats_new() to authenticated;
grant execute on function public.mark_whats_new_seen(text) to authenticated;
grant execute on function public.countersign_agreement(uuid, integer) to authenticated;
grant execute on function public.agreement_preview(uuid, integer) to authenticated;
grant execute on function public.parent_agreements() to authenticated;
