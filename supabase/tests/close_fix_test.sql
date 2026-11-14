-- The price fix, part 2: "Fix a close" corrects trades that settled at a wrong close, always in
-- her favour (Dad, 2027-11-05 and 11-09; docs/plans/price-fix-plan.md, section 2):
--   * a buy at a close that was too high: the missing units, at no cost;
--   * a sale by amount at a close that was too low: she gave up too many units, so the extra
--     units come back (at $0, like the buy's: a fund line's cents are cost, and statements count
--     a correction's cents as money she gained);
--   * a sale of everything at a close that was too low: the missing cents, rounded up, plus the
--     savings interest they'd have earned since, rounded up;
--   * a dividend from a quarter's last close that was too low: the missing cents plus their interest;
--   * the dividends the missing units would have earned since the trade day, rounded up, with their
--     interest (Dad, 2027-11-14), and later dividends count those units from the trade day;
--   * already in her favour: no change, said in the preview and logged;
-- then the stored close is corrected. Her notice leads with money. Known answers (dated 2027–28, past
-- anything the local demo or end-to-end runs store) include the
-- three real trades on production (#35, #17, #37), rebuilt here with their own closes.
begin;
select plan(60);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2027-01-01');
$$;
create function tests.as_parent() returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000000f', 'role', 'authenticated', 'aal', 'aal2')::text, true);
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
-- A trade as settle_trades leaves it: the request, its savings line and its fund line.
create function tests.trade(p_acct uuid, p_fund text, p_day date, p_side text, p_cents bigint, p_units numeric,
                            p_close numeric, p_cost bigint default null, p_sell_all boolean default false)
returns bigint language plpgsql as $$
declare
  v_req bigint;
  v_at timestamptz := public.close_time((select market from public.funds where id = p_fund), p_day);
begin
  insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, sell_all, status,
                               created_at, decided_at, settled_at)
  values (p_acct, 'move', case when p_side = 'buy' then 'savings' else 'stock' end::public.vehicle,
          case when p_side = 'buy' then 'stock' else 'savings' end::public.vehicle, p_fund,
          case when p_sell_all then null else p_cents end, p_sell_all, 'settled', v_at - interval '6 hours', v_at, v_at)
  returning id into v_req;
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, request_id, posting_key, effective_at, note)
  values (p_acct, 'savings', p_fund, case when p_side = 'buy' then 'transfer_out' else 'transfer_in' end::public.transaction_type,
          case when p_side = 'buy' then -p_cents else p_cents end, v_req, 'trade:' || v_req || ':savings', v_at, 'test');
  insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id,
                                   posting_key, effective_at, note)
  values (p_acct, 'stock', p_fund, case when p_side = 'buy' then 'transfer_in' else 'transfer_out' end::public.transaction_type,
          case when p_side = 'buy' then p_cents else -coalesce(p_cost, p_cents) end,
          case when p_side = 'buy' then p_units else -p_units end, p_close, v_req, 'trade:' || v_req || ':fund', v_at, 'test');
  return v_req;
end;
$$;
create function tests.close(p_fund text, p_day date, p_close numeric) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close) values (p_fund, p_day, p_close);
$$;
create function tests.units(p_acct uuid, p_fund text) returns numeric language sql as $$
  select coalesce(sum(units), 0) from public.transactions where account_id = p_acct and fund_id = p_fund and vehicle = 'stock';
$$;
create function tests.notice(p_acct uuid) returns public.notifications language sql as $$
  select n.* from public.notifications n where n.account_id = p_acct and n.type = 'correction' order by n.id desc limit 1;
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
select tests.clock('2028-02-28 09:00');
create temp table k (name text primary key, acct uuid);
do $$
declare v_n text; v_id uuid;
begin
  foreach v_n in array array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'] loop
    insert into public.accounts (name, is_test) values ('Test fix ' || v_n, true) returning id into v_id;
    insert into k values (v_n, v_id);
  end loop;
end;
$$;
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at, note)
select acct, 'savings', 'deposit', 50000, public.edmonton_at('2028-02-28 10:00'), 'test' from k;

-- The dividend rates these known answers use (a local demo may hold later changes).
insert into public.settings (key, value, effective_date)
values ('dividend_yield:tsx', '2.8', date '2027-06-01'), ('dividend_yield:dow', '1.8', date '2027-06-01');
insert into public.transactions (account_id, vehicle, type, amount_cents, effective_at, note)
select acct, 'savings', 'deposit', 20000, public.edmonton_at('2027-11-01 10:00'), 'test' from k where name = 'h';

-- The closes as stored (all fetched after 9:00 pm, so final), and the trades that used them.
select tests.clock('2028-03-13 21:30');
select tests.close('nasdaq100', '2028-03-06', 648.58);   -- like Nov 5, 2026 (#35)
select tests.close('dow', '2028-03-07', 519.02);         -- like Oct 19, 2026 (#17)
select tests.close('dow', '2028-03-08', 523.36);         -- like Nov 9, 2026 (#37)
select tests.close('tsx', '2028-02-28', 50.00);
select tests.close('tsx', '2028-03-09', 56.70);
select tests.close('tsx', '2028-03-10', 56.70);
select tests.close('nasdaq100', '2028-03-13', 600.00);
select tests.close('dow', '2028-03-02', 500.00);
select tests.close('dow', '2027-12-31', 400.00);
select tests.close('tsx', '2027-12-01', 60.00);
select tests.close('tsx', '2027-12-31', 50.00);
create temp table t (name text primary key, req bigint);
insert into t values
  ('a', tests.trade((select acct from k where name = 'a'), 'nasdaq100', '2028-03-06', 'buy', 1000, 0.01541830, 648.58)),
  ('b', tests.trade((select acct from k where name = 'b'), 'dow', '2028-03-07', 'buy', 1000, 0.01926709, 519.02)),
  ('c', tests.trade((select acct from k where name = 'c'), 'dow', '2028-03-08', 'buy', 1000, 0.01910731, 523.36));
-- d: $20.00 of the TSX fund at $50.00 (0.4 units), then a $10.00 sale at $56.70: 0.17636684 units
-- (rounded down), their cost 2000 × 0.17636684 ÷ 0.4 = 881.83 → 882¢.
select tests.trade((select acct from k where name = 'd'), 'tsx', '2028-02-28', 'buy', 2000, 0.40000000, 50.00);
insert into t values ('d', tests.trade((select acct from k where name = 'd'), 'tsx', '2028-03-09', 'sell', 1000,
                                       0.17636684, 56.70, 882));
-- e: $50.00 at $50.00 (1 unit), then all of it sold at $56.70: $56.70.
select tests.trade((select acct from k where name = 'e'), 'tsx', '2028-02-28', 'buy', 5000, 1.00000000, 50.00);
insert into t values ('e', tests.trade((select acct from k where name = 'e'), 'tsx', '2028-03-10', 'sell', 5670,
                                       1.00000000, 56.70, 5000, true));
-- g: one Dow unit from Sep 1, 2027 (for the dividend case, 7b).
select tests.trade((select acct from k where name = 'g'), 'dow', '2027-09-01', 'buy', 50000, 1.00000000, 500.00);
-- h: $600.00 of the TSX fund on Dec 1, 2027 at $60.00 (10 units; the right close was $50.00: 12 units),
-- and Q4's dividend paid Tue Jan 4, 2028 (the TSX's first trading day of 2028) on the 10 units held 31 of the quarter's 92 days:
-- 10 × 31 × $50.00 × 2.8% ÷ 4 ÷ 92 = $1.1793 → $1.18.
insert into t values ('h', tests.trade((select acct from k where name = 'h'), 'tsx', '2027-12-01', 'buy', 60000,
                                       10.00000000, 60.00));
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
values ((select acct from k where name = 'h'), 'savings', 'tsx', 'dividend', 118,
        'dividend:2028Q1:tsx:' || (select acct from k where name = 'h'), public.edmonton_start(date '2028-01-04'), 'test');
-- f: a buy at $600.00 when the right close was $605.00: she already got more units.
insert into t values ('f', tests.trade((select acct from k where name = 'f'), 'nasdaq100', '2028-03-13', 'buy', 1000,
                                       0.01666667, 600.00));

select tests.clock('2028-03-16 12:00');
select tests.as_parent();

-- 1. The preview: every trade that used the close, and what it gets -----------------------------

select is(public.close_fix_preview('nasdaq100', date '2028-03-06', null) - 'fetched_at' - 'fetched_words',
  '{"date": "2028-03-06", "final": true, "fund_id": "nasdaq100", "day_words": "Mar 6", "fund_name": "Nasdaq-100",
    "new_close": null, "old_close": 648.58000000, "adjustments": [], "new_close_words": null,
    "old_close_words": "$648.5800"}'::jsonb,
  'before Dad types a close, the screen shows the stored one');
create temp table fixes_before as
  select count(*)::int as n from public.transactions where posting_key like 'fix:close:%';
create temp table pv as select public.close_fix_preview('nasdaq100', date '2028-03-06', 647.05) as p;
select is((select p -> 'adjustments' -> 0 ->> 'request_id' from pv)::bigint, (select req from t where name = 'a'),
  'the preview finds the trade that settled at that close');
select is((select p -> 'adjustments' -> 0 ->> 'should_units' from pv), '0.01545476',
  '#35: $10.00 ÷ $647.05 = 0.015454756, rounded up to 0.01545476 units');
select is((select p -> 'adjustments' -> 0 ->> 'extra_units' from pv), '0.00003646', '...she got 0.01541830: 0.00003646 more');
select is((select p -> 'adjustments' -> 0 ->> 'worth' from pv), 'worth about 2¢', '...worth about 2¢ at the right close');
select is((select count(*)::int from public.transactions where posting_key like 'fix:close:%'),
  (select n from fixes_before), 'the preview changes nothing');

-- 2. #35: a buy at a close that was too high gets its missing units, at no cost --------------------

select public.correct_fund_price('nasdaq100', date '2028-03-06', 647.05, 'Official close, Invesco / Yahoo Finance');
select is(tests.units((select acct from k where name = 'a'), 'nasdaq100'), 0.01545476::numeric,
  '#35: she now has the units $10.00 buys at the right close');
select is((select amount_cents from public.transactions where posting_key = 'fix:close:nasdaq100:2028-03-06:'
             || (select req from t where name = 'a')), 0::bigint, '...added at no cost: what she paid stays $10.00');
select is((select close from public.fund_prices where fund_id = 'nasdaq100' and price_date = '2028-03-06'), 647.05::numeric,
  '...and the stored close is corrected');
select is((tests.notice((select acct from k where name = 'a'))).title, 'A price was fixed', 'her notice');
select is((tests.notice((select acct from k where name = 'a'))).body,
  'The Nasdaq-100 fund''s Mar 6 close was really $647.05, not $648.58, so your buy should have got a little more. We added the missing bit — worth about 2¢. A fix like this can only add, never take away.',
  '...leads with money, in her words');
select ok((select note from public.transactions where posting_key = 'fix:close:nasdaq100:2028-03-06:'
             || (select req from t where name = 'a')) like '%$10.00 ÷ $647.05 = 0.01545476 units, rounded up; you got 0.01541830, so 0.00003646 more units were added.%',
  'the units and the working are under "How was this calculated?"');
select is((select count(*)::int from public.parent_actions where action = 'correct_fund_price'
             and details ->> 'fund_id' = 'nasdaq100' and details ->> 'price_date' = '2028-03-06'), 1, 'logged once');
select ok((select summary from public.parent_actions where action = 'correct_fund_price' order by id desc limit 1)
            like 'Fixed the Nasdaq-100 close for Mar 6: $648.5800 → $647.0500%1 trade corrected%', '...in Dad''s words');
select is(tests.err($$select public.correct_fund_price('nasdaq100', date '2028-03-06', 647.05, 'again')$$),
  'That''s the close already stored, and it''s already final.', 'fixing it again is refused: nothing twice');

-- 3. #17 and #37: worth less than 1¢ --------------------------------------------------------------

select public.correct_fund_price('dow', date '2028-03-07', 518.92, 'Official close');
select is(tests.units((select acct from k where name = 'b'), 'dow'), 0.01927080::numeric,
  '#17: $10.00 ÷ $518.92 = 0.019270793, rounded up to 0.01927080 (+0.00000371)');
select is((tests.notice((select acct from k where name = 'b'))).body,
  'The Dow Jones fund''s Mar 7 close was really $518.92, not $519.02, so your buy should have got a little more. We added the missing bit — worth less than 1¢. A fix like this can only add, never take away.',
  '...worth less than 1¢');
select public.correct_fund_price('dow', date '2028-03-08', 523.33, 'Official close');
select is(tests.units((select acct from k where name = 'c'), 'dow'), 0.01910841::numeric,
  '#37: $10.00 ÷ $523.33 = 0.019108402, rounded up to 0.01910841 (+0.00000110)');
select ok((tests.notice((select acct from k where name = 'c'))).body like '%worth less than 1¢%', '...worth less than 1¢');

-- 4. A sale by amount at a close that was too low: the extra units come back ------------------------

create temp table pd as select public.close_fix_preview('tsx', date '2028-03-09', 56.75) as p;
select is((select p -> 'adjustments' -> 0 ->> 'kind' from pd), 'sale', 'a sale by amount');
select is((select p -> 'adjustments' -> 0 ->> 'should_units' from pd), '0.17621145',
  'at $56.75 her $10.00 needed 0.17621145 units (10 ÷ 56.75 = 0.176211453, rounded down)');
select is((select p -> 'adjustments' -> 0 ->> 'extra_units' from pd), '0.00015539', '...she gave up 0.17636684: 0.00015539 too many');
select public.correct_fund_price('tsx', date '2028-03-09', 56.75, 'Official close');
select is(tests.units((select acct from k where name = 'd'), 'tsx'), 0.22378855::numeric,
  'the 0.00015539 units come back (0.4 − 0.17621145 = 0.22378855)');
select is((select amount_cents from public.transactions where posting_key = 'fix:close:tsx:2028-03-09:'
             || (select req from t where name = 'd')), 0::bigint, '...at $0, like a buy''s missing units');
select is((select coalesce(sum(amount_cents), 0) from public.transactions
            where account_id = (select acct from k where name = 'd') and vehicle = 'savings' and posting_key like 'fix:%')::bigint, 0::bigint,
  '...and no money moves: she got the $10.00 she asked for');
select is((tests.notice((select acct from k where name = 'd'))).body,
  'The TSX fund''s Mar 9 close was really $56.75, not $56.70, so your sale should have used a little less of your fund. We put the extra back — worth less than 1¢. A fix like this can only add, never take away.',
  'her notice');

-- 5. A sale of everything at a close that was too low: the missing money plus its interest -----------

create temp table pe as select public.close_fix_preview('tsx', date '2028-03-10', 56.75) as p;
select is((select p -> 'adjustments' -> 0 ->> 'kind' from pe), 'sale_all', 'a sale of everything');
select is((select p -> 'adjustments' -> 0 ->> 'cents' from pe), '5', '1 unit × $56.75 = $56.75: 5¢ missing');
select is((select p -> 'adjustments' -> 0 ->> 'interest_cents' from pe), '1',
  '...plus the savings interest 5¢ would have earned Mar 10 to Mar 16, rounded up: 1¢');
select public.correct_fund_price('tsx', date '2028-03-10', 56.75, 'Official close');
select is((select amount_cents from public.transactions where posting_key = 'fix:close:tsx:2028-03-10:'
             || (select req from t where name = 'e')), 6::bigint, 'one savings correction of 6¢');
select is((select vehicle::text || ' ' || type::text || ' ' || coalesce(counts_as, '') from public.transactions
            where posting_key = 'fix:close:tsx:2028-03-10:' || (select req from t where name = 'e')),
  'savings correction earned', '...in savings, counted as earned');
select is((tests.notice((select acct from k where name = 'e'))).body,
  'The TSX fund''s Mar 10 close was really $56.75, not $56.70, so your sale should have paid a little more. We added the missing money and the interest it would have earned — 6¢. A fix like this can only add, never take away.',
  'her notice leads with money');

-- 6. Already in her favour: no change, said and logged ------------------------------------------------

create temp table pf as select public.close_fix_preview('nasdaq100', date '2028-03-13', 605.00) as p;
select is((select p -> 'adjustments' -> 0 ->> 'kind' from pf), 'no_change', 'a buy at a close that was too low');
select is((select p -> 'adjustments' -> 0 ->> 'words' from pf), 'No change: this one was in her favour.', '...said in the preview');
select public.correct_fund_price('nasdaq100', date '2028-03-13', 605.00, 'Official close');
select is(tests.units((select acct from k where name = 'f'), 'nasdaq100'), 0.01666667::numeric, 'nothing taken back');
select is((select count(*)::int from public.notifications where account_id = (select acct from k where name = 'f')
            and type = 'correction'), 0, '...and no notice');
select ok((select summary from public.parent_actions where action = 'correct_fund_price' order by id desc limit 1)
            like '%no change (in her favour)%', '...logged');

-- 7. A close no trade used: corrected, nothing else ----------------------------------------------------

select public.correct_fund_price('dow', date '2028-03-02', 499.50, 'Official close');
select is((select close from public.fund_prices where fund_id = 'dow' and price_date = '2028-03-02'), 499.50::numeric,
  'a close with no trade is corrected');
select is((select count(*)::int from public.transactions where posting_key like 'fix:close:dow:2028-03-02%'), 0,
  '...with no adjustment');

-- 7b. A dividend paid from a quarter's last close that was too low ---------------------------------

-- g: 1 Dow unit all of Q4 2027; its dividend was paid Mon Jan 3, 2028 at the Dec 31 close of $400.00:
-- 1 × $400.00 × 1.8% ÷ 4 = $1.80. The real close was $401.00: $1.8045 → $1.81, so 1¢ is missing,
-- plus its interest Jan 3 to Mar 15 (1¢ × 2% × 73 ÷ 366 = $0.00004), rounded up to 1¢: 2¢.
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, posting_key, effective_at, note)
values ((select acct from k where name = 'g'), 'savings', 'dow', 'dividend', 180,
        'dividend:2028Q1:dow:' || (select acct from k where name = 'g'), public.edmonton_start(date '2028-01-03'), 'test');
create temp table pg as select public.close_fix_preview('dow', date '2027-12-31', 401.00) as p;
select is((select p -> 'adjustments' -> 0 ->> 'kind' from pg), 'dividend', 'the preview finds the dividend paid from that close');
select public.correct_fund_price('dow', date '2027-12-31', 401.00, 'Official close');
select is((select amount_cents from public.transactions where posting_key = 'fix:close:dow:2027-12-31:dividend:'
             || (select acct from k where name = 'g')), 2::bigint, 'the missing 1¢ and its interest: 2¢');
select is((tests.notice((select acct from k where name = 'g'))).body,
  'The Dow Jones fund''s Dec 31 close was really $401.00, not $400.00, so your dividend should have been a little more. We added the missing money and the interest it would have earned — 2¢. A fix like this can only add, never take away.',
  'her notice');

create function tests.recon(p_name text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(p), '[]'::jsonb)
    from jsonb_array_elements(public.reconcile_account((select acct from k where name = p_name), date '2028-03-16',
                                                       date '2028-02-28', date '2028-02-28')) p
   where p ->> 'code' in ('posting', 'worth', 'app_figures', 'fund_cost', 'negative')
     -- This test's starting deposits go straight in, without a request.
     and p ->> 'message' <> 'A deposit line doesn''t match an approved request.';
$$;

-- 7c. The dividends the missing units would have earned (Dad, 2027-11-14) ------------------------------

-- With 12 units, Q4's dividend was 12 × 31 × $50.00 × 2.8% ÷ 4 ÷ 92 = $1.4152 → $1.42: 24¢ missing,
-- plus its interest Jan 4 to Mar 15 (24¢ × 2% × 72 ÷ 366 = $0.00094), rounded up to 1¢.
create temp table ph as select public.close_fix_preview('tsx', date '2027-12-01', 50.00) as p;
select is((select p -> 'adjustments' -> 0 ->> 'extra_units' from ph), '2.00000000', 'h: 12 units at $50.00, she got 10');
select is((select p -> 'adjustments' -> 0 ->> 'dividend_cents' from ph), '24',
  'the dividend those 2 units would have earned in Q4: 24¢');
select is((select p -> 'adjustments' -> 0 ->> 'dividend_interest_cents' from ph), '1', '...plus its interest: 1¢');
select public.correct_fund_price('tsx', date '2027-12-01', 50.00, 'Official close');
select is(tests.units((select acct from k where name = 'h'), 'tsx'), 12.00000000::numeric, 'the 2 units are added');
select is((select amount_cents from public.transactions where posting_key = 'fix:close:tsx:2027-12-01:'
             || (select req from t where name = 'h') || ':dividends'), 25::bigint, 'one savings correction of 25¢');
select is((tests.notice((select acct from k where name = 'h'))).body,
  'The TSX fund''s Dec 1 close was really $50.00, not $60.00, so your buy should have got a little more. We added the missing bit and the dividends it would have earned — worth about $100.25. A fix like this can only add, never take away.',
  'her notice counts the dividends too');
-- The next dividend counts the 2 units from Dec 1: all 91 days of Q1 2028 (a leap year) at 12 units.
select is((select unit_days_x_den from public.dividend_unit_days((select acct from k where name = 'h'), 'tsx',
             date '2028-01-01', date '2028-03-31', date '2028-03-31')), 1092::numeric,
  'Q1''s dividend counts 12 units every day, the added ones from the trade day');
select is(tests.recon('h'), '[]'::jsonb, 'reconcile: the dividend paid before the fix still checks out');

-- 8. Nothing twice, and the books still add up --------------------------------------------------------

select is((select count(*)::int from (select posting_key from public.transactions where posting_key is not null
            group by posting_key having count(*) > 1) x), 0, 'no posting key twice');
select is((select count(*)::int from public.fund_price_corrections where price_date between '2027-12-01' and '2028-03-13'), 9,
  'every fix is recorded with its old and new close');

select is(tests.recon('a'), '[]'::jsonb, 'reconcile: a buy fixed with missing units checks out');
select is(tests.recon('d'), '[]'::jsonb, '...a sale by amount fixed with units put back');
select is(tests.recon('e'), '[]'::jsonb, '...a sale of everything fixed with missing money');
select is(tests.recon('f'), '[]'::jsonb, '...a trade left as it was');

-- 9. Dad turns the price check on in Settings -------------------------------------------------------

select is(public.parent_price_check() ->> 'value', 'off', 'the price check starts off');
select is(tests.err($$select public.set_setting('price_mismatch_check', 'maybe')$$), 'The price check is on or off.',
  'it''s on or off');
select public.set_setting('price_mismatch_check', 'on', null, 'Known wrong closes fixed');
select is(public.setting_on('price_mismatch_check', public.app_today()), 'on', 'Dad turns it on, from today');
select is((select summary from public.parent_actions where action = 'set_setting' order by id desc limit 1),
  'Price check turned on from ' || public.fmt_date(public.app_today()) || '.', '...logged in his words');

select * from finish();
rollback;
