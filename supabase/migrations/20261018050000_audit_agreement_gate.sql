-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). The account
-- agreement is enforced by the database, not only by the screens.
--
-- Before: only request_deposit checked that she had signed (any version). Now
-- (Dad's decisions, 2026-10-08):
--   * Her first agreement: she can ask for her first deposit as soon as she has
--     signed; everything else (withdrawals, fund trades, buying or breaking a GIC,
--     finishing onboarding) waits until Dad has signed too; and Dad can approve a
--     request only once he has signed.
--   * A new version (a new or reworded rule): only NEW DEPOSITS wait, until she has
--     signed the new version and Dad has countersigned it. Everything else keeps
--     working under the version they both signed before, and her Home shows a
--     banner asking her to sign.
--   * Dad approving: he must have countersigned the latest version she has signed
--     (Approvals always offers exactly that one, so there's never a dead end).
--   * No agreement version at all: nothing money-related works.
-- choose_maturity is left open on purpose: blocking it could make her lose her
-- 7 days to choose for a matured GIC.

-- Internal: raises unless the agreement allows this kind of action.
--   p_kind 'deposit': she has signed the current version, and, unless this is her
--                     first agreement, Dad has countersigned it too.
--   p_kind 'other':   she and Dad have both signed some version.
create function public.require_agreement(p_account uuid, p_kind text)
returns void
language plpgsql stable
set search_path = ''
as $$
declare
  v_latest integer := (select max(v.version) from public.agreement_versions v);
  v_signed integer := (select max(s.version) from public.agreement_signatures s
                        where s.account_id = p_account and s.signer = 'kid');
  v_first boolean;
begin
  if v_latest is null then
    raise exception 'The Big Bucks agreement isn''t set up yet, so nothing can move.';
  end if;
  if v_signed is null then
    raise exception '%', case when p_kind = 'deposit'
                              then 'Before you can put money in, sign your Big Bucks agreement with Dad.'
                              else 'Sign your Big Bucks agreement with Dad first.' end;
  end if;
  -- Her first agreement: the only version she has signed, and no earlier one.
  v_first := not exists (select 1 from public.agreement_signatures s
                          where s.account_id = p_account and s.signer = 'kid' and s.version < v_signed);

  if p_kind = 'deposit' then
    if v_signed < v_latest then
      raise exception 'Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed.';
    end if;
    if not v_first and not exists (select 1 from public.agreement_signatures s
                                    where s.account_id = p_account and s.version = v_latest and s.signer = 'parent') then
      raise exception 'You signed the new agreement! New deposits wait until Dad signs it too.';
    end if;
    return;
  end if;

  if not exists (select 1 from public.agreement_signatures k
                  join public.agreement_signatures p
                    on p.account_id = k.account_id and p.version = k.version and p.signer = 'parent'
                 where k.account_id = p_account and k.signer = 'kid') then
    raise exception 'Dad hasn''t signed your agreement yet. As soon as he does, this will work.';
  end if;
end;
$$;

-- Deposits.
create or replace function public.request_deposit(p_amount_cents bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_agreement(public.kid_account(), 'deposit');
  return public.request_deposit_core(p_amount_cents);
end;
$$;
comment on function public.request_deposit(bigint) is
  'A deposit request: only once the agreement allows new deposits (require_agreement), then request_deposit_core (unchanged from stage 2).';

-- The other money moves: a version they have both signed.
alter function public.request_withdrawal(bigint) rename to request_withdrawal_core;
alter function public.request_trade(text, text, bigint, boolean) rename to request_trade_core;
alter function public.buy_gic(bigint, integer) rename to buy_gic_core;
alter function public.break_gic(bigint) rename to break_gic_core;

create function public.request_withdrawal(p_amount_cents bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_agreement(public.kid_account(), 'other');
  return public.request_withdrawal_core(p_amount_cents);
end;
$$;

create function public.request_trade(p_fund_id text, p_side text, p_amount_cents bigint default null,
                                     p_sell_all boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_agreement(public.kid_account(), 'other');
  return public.request_trade_core(p_fund_id, p_side, p_amount_cents, p_sell_all);
end;
$$;

create function public.buy_gic(p_amount_cents bigint, p_term_months integer)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_agreement(public.kid_account(), 'other');
  return public.buy_gic_core(p_amount_cents, p_term_months);
end;
$$;

create function public.break_gic(p_gic_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_agreement(public.kid_account(), 'other');
  return public.break_gic_core(p_gic_id);
end;
$$;

create or replace function public.finish_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid := public.kid_account();
begin
  perform public.require_agreement(v_account, 'other');
  update public.accounts set onboarding_done_at = coalesce(onboarding_done_at, public.app_now()) where id = v_account;
  insert into public.whats_new_seen (account_id, feature)
  select v_account, f.feature from public.whats_new_features f
   where public.feature_enabled(f.feature, v_account)
  on conflict do nothing;
end;
$$;

-- Approving: Dad has countersigned the latest version she has signed.
create or replace function public.approve_request(p_request_id bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_name text;
  v_signed integer;
begin
  perform public.require_parent();
  select * into v_req from public.requests r where r.id = p_request_id;
  if found then
    select max(s.version) into v_signed from public.agreement_signatures s
     where s.account_id = v_req.account_id and s.signer = 'kid';
    if v_signed is not null and not exists (
         select 1 from public.agreement_signatures p
          where p.account_id = v_req.account_id and p.version = v_signed and p.signer = 'parent') then
      select a.name into v_name from public.accounts a where a.id = v_req.account_id;
      raise exception '% signed her agreement and is waiting for you to sign it too. Sign it first (it''s at the top of Approvals), then approve this.',
        v_name;
    end if;
  end if;

  perform public.approve_request_unlogged(p_request_id, p_note);

  select * into v_req from public.requests r where r.id = p_request_id;
  perform public.log_parent_action('approve_request', v_req.account_id, v_req.id,
    'Approved ' || (select a.name from public.accounts a where a.id = v_req.account_id) || '''s '
      || public.fmt_money(v_req.amount_cents) || ' '
      || case v_req.type when 'deposit' then 'deposit' else 'withdrawal' end || '.',
    jsonb_build_object('type', v_req.type, 'amount_cents', v_req.amount_cents, 'note', v_req.parent_note));
end;
$$;

revoke all on function public.require_agreement(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.request_withdrawal_core(bigint) from public, anon, authenticated, service_role;
revoke all on function public.request_trade_core(text, text, bigint, boolean) from public, anon, authenticated, service_role;
revoke all on function public.buy_gic_core(bigint, integer) from public, anon, authenticated, service_role;
revoke all on function public.break_gic_core(bigint) from public, anon, authenticated, service_role;
revoke all on function public.request_withdrawal(bigint) from public, anon, authenticated, service_role;
revoke all on function public.request_trade(text, text, bigint, boolean) from public, anon, authenticated, service_role;
revoke all on function public.buy_gic(bigint, integer) from public, anon, authenticated, service_role;
revoke all on function public.break_gic(bigint) from public, anon, authenticated, service_role;
grant execute on function public.request_withdrawal(bigint) to authenticated;
grant execute on function public.request_trade(text, text, bigint, boolean) to authenticated;
grant execute on function public.buy_gic(bigint, integer) to authenticated;
grant execute on function public.break_gic(bigint) to authenticated;
