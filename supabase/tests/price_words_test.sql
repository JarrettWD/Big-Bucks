-- The price fix, part 3: what she sees (Dad, 2026-11-09; docs/plans/price-fix-plan.md, 2c).
-- Her waiting line names its close; a fund whose newest close is late says so; "Last market day"
-- names the day all her funds have. Known answers in March and July 2027 (Alberta UTC−6; markets
-- close at 3:00 pm Alberta until Mar 14, 2:00 pm after). Works on a fresh database and on one
-- holding the local demo (its dates are earlier).
begin;
select plan(12);

create schema tests;
create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.close(p_fund text, p_day date) returns void language sql as $$
  insert into public.fund_prices (fund_id, price_date, close) values (p_fund, p_day, 100);
$$;

-- 1. Her waiting line ---------------------------------------------------------------------------

-- Asked Friday Mar 5 at 3:02 pm, just after the close: it waits for Monday's.
create temp table asked as select public.edmonton_at(timestamp '2027-03-05 15:02') as at;
select tests.clock('2027-03-05 16:00');
select is(public.waiting_words('dow', (select at from asked)), 'Waiting for Monday''s 3:00 pm close (Mar 8) · asked Mar 5',
  'the same evening: Monday''s close, named with its day');
select tests.clock('2027-03-08 10:00');
select is(public.waiting_words('dow', (select at from asked)), 'Waiting for today''s 3:00 pm close (Mar 8) · asked Mar 5',
  'Monday morning: today''s close');
select tests.clock('2027-03-08 16:00');
select is(public.waiting_words('dow', (select at from asked)),
  'Waiting for today''s close to be confirmed (Mar 8) · asked Mar 5', 'after 3:00 pm, until the close is confirmed');
select tests.clock('2027-03-09 09:00');
select is(public.waiting_words('dow', (select at from asked)),
  'Waiting for yesterday''s close to be confirmed (Mar 8) · asked Mar 5', 'a close that is late: still waiting for it');
select tests.clock('2027-03-15 10:00');
select is(public.waiting_words('tsx', public.edmonton_at(timestamp '2027-03-15 09:00')),
  'Waiting for today''s 2:00 pm close (Mar 15) · asked Mar 15', 'after Toronto moves its clocks, the close is at 2:00 pm Alberta time');

-- The same words in her history and on Buy / Sell.
select tests.clock('2027-03-08 16:00');
insert into public.accounts (name, is_test) values ('Test price words', true);
insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, status, created_at)
select a.id, 'move', 'savings', 'stock', 'dow', 1000, 'pending', (select at from asked)
  from public.accounts a where a.name = 'Test price words';
select is((select note from public.my_activity((select id from public.accounts where name = 'Test price words'))
            where kind = 'request_pending'),
  'Waiting for today''s close to be confirmed (Mar 8) · asked Mar 5', 'her history shows the waiting line');
select is((public.trade_options((select id from public.accounts where name = 'Test price words')) -> 'waiting' -> 0
            ->> 'waiting_words'),
  'Waiting for today''s close to be confirmed (Mar 8) · asked Mar 5', '...and so does Buy / Sell');

-- 2. The funds switch to a new day together ---------------------------------------------------------

select tests.clock('2027-03-10 21:30');
select tests.close(f.id, date '2027-03-09') from public.funds f;
select tests.close('dow', date '2027-03-10');
select tests.close('nasdaq100', date '2027-03-10');
select is(public.kid_close_days() -> 'later', '{"tsx": "Today''s TSX close comes in later"}'::jsonb,
  'after 9:00 pm, the TSX close still missing: its card says it comes in later');
select is(public.kid_close_days() ->> 'last_market_day', '2027-03-09', '..."Last market day" is the day all her funds have');
select tests.close('tsx', date '2027-03-10');
select is(public.kid_close_days(), '{"later": {}, "last_market_day": "2027-03-10"}'::jsonb,
  'once it arrives, all three switch to the new day together');

-- Canada Day: the TSX is closed and New York is open. Nothing is late.
select tests.clock('2027-07-01 21:30');
select tests.close(f.id, date '2027-06-30') from public.funds f;
select tests.close('dow', date '2027-07-01');
select tests.close('nasdaq100', date '2027-07-01');
select is(public.kid_close_days() -> 'later', '{}'::jsonb, 'a fund whose market was closed that day isn''t late');
select is(public.kid_close_days() ->> 'last_market_day', '2027-07-01', '...and the newest market day is shown');

select * from finish();
rollback;
