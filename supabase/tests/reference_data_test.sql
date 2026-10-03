-- Known answers for the starting data: funds, rates, settings, glossary and holidays.
begin;
select plan(18);

select results_eq(
  $$select id, name, proxy_symbol, market::text, colour from public.funds order by sort_order$$,
  $$values ('dow', 'Dow Jones', 'DIA', 'nyse', '#2F80ED'),
           ('nasdaq100', 'Nasdaq-100', 'QQQ', 'nyse', '#F76B15'),
           ('tsx', 'TSX', 'XIC', 'tsx', '#0B6E69')$$,
  'the three funds, their ETFs, markets and colours (blue, orange, teal)');

select results_eq(
  $$select key, value, effective_date from public.settings where key like 'dividend_yield:%' order by key$$,
  $$values ('dividend_yield:dow', '1.8', date '2026-01-01'),
           ('dividend_yield:nasdaq100', '0.6', date '2026-01-01'),
           ('dividend_yield:tsx', '2.8', date '2026-01-01')$$,
  'starting yields, as dated settings since stage 2 (Nasdaq-100 0.6%, Dow 1.8%, TSX 2.8%)');

select results_eq(
  $$select vehicle::text, gic_term, rate, effective_date, is_special from public.rates order by id$$,
  $$values ('savings', null::smallint, 2.000::numeric(6,3), date '2026-01-01', false),
           ('gic', 1::smallint,  2.500::numeric(6,3), date '2026-01-01', false),
           ('gic', 3::smallint,  3.000::numeric(6,3), date '2026-01-01', false),
           ('gic', 6::smallint,  4.000::numeric(6,3), date '2026-01-01', false),
           ('gic', 9::smallint,  4.500::numeric(6,3), date '2026-01-01', false),
           ('gic', 12::smallint, 5.000::numeric(6,3), date '2026-01-01', false),
           ('gic', 24::smallint, 6.000::numeric(6,3), date '2026-01-01', false)$$,
  'the starting rates: savings 2.0%; GICs 2.5/3.0/4.0/4.5/5.0/6.0% for 1/3/6/9/12/24 months');

select is((select value from public.settings where key = 'deposit_cap_cents' order by id desc limit 1), '100000',
  'the deposit cap starts at 100000 cents ($1,000)');
select is((select value from public.settings where key = 'inflation_rate' order by id desc limit 1), '2.0',
  'inflation starts at 2.0%');
select is((select count(*) from public.settings where key like 'feature:%'), 0::bigint,
  'no feature switches yet, so every feature is off');

-- Glossary: every term the app uses so far has a ? explanation
select ok((select count(*) from public.glossary) >= 45, 'the glossary has at least 45 terms');
select is(
  array(select t from unnest(array[
    'Interest', 'Interest rate', 'Rate of return', 'Compounding', 'Compounding frequency', 'GIC', 'Term',
    'Maturity', 'Breaking a GIC early', 'Stock fund', 'Index', 'Dow Jones', 'Nasdaq-100', 'TSX', 'ETF',
    'Unit', 'Unit price', 'Settlement', 'Dividend', 'Diversification', 'Liquidity', 'Risk', 'Inflation',
    'Deposit cap', 'Available', 'On hold', 'Special rate', 'Effective date', 'Stock split', 'Market holiday'
  ]) t where not exists (select 1 from public.glossary g where g.term = t)),
  '{}'::text[],
  'the glossary covers the key terms');

-- Market holidays: counts per market and year
select results_eq(
  $$select market::text, extract(year from holiday_date)::int, kind::text, confirmed, count(*)::int
      from public.market_holidays group by 1, 2, 3, 4 order by 1, 2, 3$$,
  $$values ('nyse', 2026, 'closed', true, 10), ('nyse', 2026, 'early_close', true, 2),
           ('nyse', 2027, 'closed', true, 10), ('nyse', 2027, 'early_close', true, 1),
           ('nyse', 2028, 'closed', true, 9),  ('nyse', 2028, 'early_close', true, 2),
           ('tsx', 2026, 'closed', true, 10),  ('tsx', 2026, 'early_close', true, 1),
           ('tsx', 2027, 'closed', false, 10), ('tsx', 2027, 'early_close', false, 1),
           ('tsx', 2028, 'closed', false, 10)$$,
  'holiday counts per market and year; only TSX 2027-2028 are unconfirmed');
select is((select count(*) from public.market_holidays where extract(isodow from holiday_date) > 5), 0::bigint,
  'no holiday falls on a weekend');
select ok(not exists (select 1 from public.market_holidays where market = 'nyse' and holiday_date = '2027-12-31'),
  'NYSE: no New Year''s holiday for Saturday, Jan 1, 2028 (Dec 31, 2027 is a trading day)');
select ok(exists (select 1 from public.market_holidays where market = 'nyse' and holiday_date = '2026-07-03'),
  'NYSE: Independence Day 2026 (a Saturday) is observed on Friday, Jul 3');
select ok(not exists (select 1 from public.market_holidays where market = 'tsx' and holiday_date = '2026-07-03'),
  'TSX: open on a US-only holiday');
select ok(exists (select 1 from public.market_holidays where market = 'tsx' and holiday_date = '2026-12-28'),
  'TSX: Boxing Day 2026 (a Saturday) is in lieu on Monday, Dec 28');
select ok(exists (select 1 from public.market_holidays where market = 'tsx' and holiday_date = '2028-01-03'),
  'TSX 2028 (calculated): New Year''s Day in lieu on Monday, Jan 3');
select ok(exists (select 1 from public.market_holidays where market = 'tsx' and holiday_date = '2027-05-24'),
  'TSX 2027 (calculated): Victoria Day is the Monday before May 25');
select is((select closes_at from public.market_holidays where market = 'nyse' and holiday_date = '2026-11-27'),
  '13:00'::time, 'NYSE: the day after Thanksgiving closes early at 1:00 pm Eastern');
select is(
  (select count(*) from public.market_holidays where confirmed = false and market <> 'tsx'), 0::bigint,
  'every NYSE row is confirmed from the published calendar');

select * from finish();
rollback;
