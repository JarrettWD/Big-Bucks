-- Stage 8 B4, after Dad's review (2026-10-07): onboarding must be finished before
-- she uses the rest of the app, and if she leaves partway she resumes where she was.
--
-- 1. Her place in onboarding is saved (the step, and the tour card), so she comes
--    back to it on any device. After she signs, her place is always her first
--    decision.
-- 2. onboarding_state (from 20261016000000_onboarding.sql) adds where to resume
--    and any deposit she has already asked for: her first deposit is now asked for
--    inside her first decision, because the rest of the app (Buy / Sell included)
--    stays locked until onboarding is done. The deposit still goes through
--    request_deposit and every rule it checks.
-- 3. Round 3 (Dad, 2026-10-07): the app unlocks as soon as both signatures are done
--    and her first deposit is approved (unlocked), so her first decision's GIC and
--    fund choices open a working Buy / Sell. If Dad declines her first deposit (or
--    it runs out of time), her first decision shows why and she asks again there.
-- 4. Dad's list of agreements is ordered by when she signed, oldest first, real
--    kids before test accounts, like the rest of Approvals.
-- The lock itself is the app's screens; the database already refuses a deposit
-- before she signs, and nothing she could reach changes money before then.

alter table public.accounts
  add column onboarding_step text
    check (onboarding_step in ('welcome', 'tour', 'personalise', 'wish', 'agreement', 'decision')),
  add column onboarding_card integer not null default 0 check (onboarding_card >= 0);
comment on column public.accounts.onboarding_step is
  'Where she was in onboarding when she left (null = the start). Her first decision once she has signed.';
comment on column public.accounts.onboarding_card is 'Which tour card she was on (0 = the first).';

-- She moves on (or back) in onboarding; the screens save her place.
create function public.save_onboarding_step(p_step text, p_card integer default 0)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
  v_steps jsonb;
  v_signed boolean;
begin
  if (select a.onboarding_done_at from public.accounts a where a.id = v_account) is not null then
    return; -- Onboarding is finished; nothing to remember.
  end if;
  v_steps := public.onboarding_state(v_account) -> 'steps';
  if p_step is null or not (v_steps ? p_step) then
    raise exception 'There''s no "%" step in your setup.', p_step;
  end if;
  if p_card is null or p_card < 0 or p_card > 20 then
    raise exception 'There''s no card % in the tour.', p_card;
  end if;
  v_signed := exists (select 1 from public.agreement_signatures s where s.account_id = v_account and s.signer = 'kid');
  if p_step = 'decision' and not v_signed then
    raise exception 'Sign your Big Bucks agreement with Dad first.';
  end if;
  update public.accounts
     set onboarding_step = case when v_signed then 'decision' else p_step end,
         onboarding_card = case when p_step = 'tour' then p_card else 0 end
   where id = v_account;
end;
$$;

-- onboarding_state from 20261016000000_onboarding.sql, plus resume_step,
-- resume_card, pending_deposit_cents, unlocked and last_answer. Everything else is
-- unchanged.
create or replace function public.onboarding_state(p_account_id uuid)
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
  v_counter boolean;
  v_last public.requests;
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
  v_counter := exists (select 1 from public.agreement_signatures s
                        where s.account_id = p_account_id and s.signer = 'parent' and s.version = v_signed);
  -- Her latest deposit request, if Dad declined it or it ran out of time (and
  -- nothing newer is waiting): her first decision says why, and she asks again.
  select * into v_last from public.requests r
   where r.account_id = p_account_id and r.type = 'deposit'
   order by r.created_at desc, r.id desc limit 1;

  return jsonb_build_object(
    'name', v_acct.name,
    'done', v_acct.onboarding_done_at is not null,
    'current_version', v_current,
    'signed_version', v_signed,
    'countersigned', v_counter,
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
    'rules', public.house_rules(),
    -- B4 review: where to pick up, and a deposit already asked for.
    'resume_step', case when v_acct.onboarding_done_at is not null then null
                        when v_signed is not null then 'decision'
                        else coalesce(v_acct.onboarding_step, 'welcome') end,
    'resume_card', case when v_acct.onboarding_done_at is null and v_signed is null
                             and v_acct.onboarding_step = 'tour' then v_acct.onboarding_card else 0 end,
    'pending_deposit_cents', nullif(public.pending_deposits_cents(p_account_id), 0),
    -- Round 3: the rest of the app opens once both have signed and her first
    -- deposit is in (or once onboarding is done).
    'unlocked', v_acct.onboarding_done_at is not null
                or (v_signed is not null and v_counter and v_first is not null),
    'last_answer', case when v_first is null and v_last.status in ('declined', 'expired')
                        then jsonb_build_object('status', v_last.status, 'amount_cents', v_last.amount_cents,
                                                'reason', v_last.parent_note) end);
end;
$$;

revoke all on function public.save_onboarding_step(text, integer) from public, anon, authenticated, service_role;
grant execute on function public.save_onboarding_step(text, integer) to authenticated;

-- parent_agreements from 20261016000000_onboarding.sql, ordered by when she signed
-- (oldest first, real kids before test accounts; not signed yet last). Otherwise unchanged.
create or replace function public.parent_agreements()
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
           order by a.is_test, k.signed_at nulls last, a.name)
      from public.accounts a
      left join lateral (select s.version, s.signed_at from public.agreement_signatures s
                          where s.account_id = a.id and s.signer = 'kid'
                          order by s.version desc limit 1) k on true), '[]'::jsonb);
end;
$$;
