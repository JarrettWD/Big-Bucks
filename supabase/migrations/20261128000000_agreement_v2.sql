-- The Big Bucks agreement, version 2 (Dad, 2026-11-27). Wording only: no money function,
-- rate, rule or posting changes. Version 1 stays exactly as it was (agreement_versions is
-- append-only and takes inserts).
--
-- What changed from version 1:
-- 1. "Mom or Dad" wherever it's about reading, talking or asking; "Dad" only where it's
--    something only his parent sign-in can do (saying yes, countersigning, answering in the
--    app, fixing): the intro, rule 🔑 and the sign line.
-- 2. Rule 🐷: money comes out of savings too, so a fund or GIC is cashed out through savings
--    (SPEC "Withdrawal (cash out): from savings only").
-- 3. Rule 🔒: a GIC "matures", not "finishes", with the ? for "Matures" (as on her other
--    screens, 20261101000000_matures_wording.sql).
-- No rule carries a "Changed" mark: at launch the girls sign version 2 as their first
-- agreement, and a mark would only puzzle them.
--
-- Also in the same spirit, outside the agreement itself:
-- - the notice a girl gets when the agreement changes says "with Mom or Dad";
-- - save_onboarding_step's refusal says "with Mom or Dad".
-- The refusals inside require_agreement (it guards deposits and moves) still say "with Dad":
-- that function sits on the money path, so its wording waits for block 2 (Jan 2).
-- Wording: docs/MESSAGES.md §11.

-- 1. The notice when the agreement changes ---------------------------------------------------------

create or replace function public.agreement_changed_notices(p_version integer)
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
      'Dad changed the house rules. Read the new version with Mom or Dad, and sign it when you agree. Your old agreement stays in your history.',
      'agreement_changed:' || r.account_id || ':' || p_version);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- 2. Onboarding's refusal before signing (otherwise as in 20261017000000_onboarding_resume.sql) ----

create or replace function public.save_onboarding_step(p_step text, p_card integer default 0)
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
    raise exception 'Sign your Big Bucks agreement with Mom or Dad first.';
  end if;
  update public.accounts
     set onboarding_step = case when v_signed then 'decision' else p_step end,
         onboarding_card = case when p_step = 'tour' then p_card else 0 end
   where id = v_account;
end;
$$;

-- 3. Version 2 -----------------------------------------------------------------------------------

insert into public.agreement_versions (version, intro, rules, promises, sign_line) values (2,
  'These are the house rules. Read them with Mom or Dad, and ask about anything that doesn''t make sense. When you agree, you sign, and then Dad signs too. A copy stays in your history.',
  $rules$[
    {"icon": "💵", "title": "The money is real.",
     "text": "Dad keeps the cash, and Big Bucks keeps track of every cent he owes you."},
    {"icon": "🐷", "title": "New money goes into savings first.",
     "text": "You can put in up to {cap} altogether. Taking money out gives you room again. Interest and growth don't count, so your money can grow past {cap}. Money comes out of savings too. To cash out a fund or GIC, move it to savings first."},
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
    {"icon": "🔒", "title": "A GIC is a promise.", "glossary": "Matures",
     "text": "You leave the money for the whole term. If you break the promise early, you get your money back but you lose all its interest. When a GIC matures, you have {gic_choice_days} days to choose what's next, or it moves to your savings."},
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
     "text": "Don't share it, not even with your sister. If you think someone knows it, tell Mom or Dad."},
    {"icon": "👀", "title": "Mom and Dad can see your account.",
     "text": "They can look at your Big Bucks screens any time, just like your wish list.",
     "if_off": {"feature": "wishlist", "text": "They can look at your Big Bucks screens any time."}}
  ]$rules$::jsonb,
  'Dad keeps your cash safe, answers your requests, and fixes any mistake openly, with a note, rounding in your favour.',
  'I''ve read these rules with Mom or Dad, and I agree.');

-- Tell each girl who signed version 1 (on production before launch: only the test kid).
select public.agreement_changed_notices(2);
