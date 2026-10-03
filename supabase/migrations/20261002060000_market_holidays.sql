-- Stage 1: market holidays and early closes, 2026–2028.
--
-- Sources (checked 2026-10-02):
--   NYSE: https://www.nyse.com/markets/hours-calendars
--         Published for 2026, 2027 and 2028. Nasdaq (QQQ) follows the same calendar.
--         New Year's Day 2028 falls on a Saturday and NYSE observes no holiday for it.
--   TSX:  https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar
--         Published for 2025 and 2026 only. The TSX stays open on US-only holidays.
--
-- TSX 2027 and 2028 are NOT published yet. Those rows are calculated from the
-- TSX's usual rules and marked confirmed = false:
--   New Year's Day (Jan 1; if on a weekend, the next Monday), Family Day (3rd
--   Monday of Feb), Good Friday, Victoria Day (the Monday before May 25), Canada
--   Day (Jul 1; if on a weekend, the next Monday), Civic Holiday (1st Monday of
--   Aug), Labour Day (1st Monday of Sep), Thanksgiving (2nd Monday of Oct),
--   Christmas and Boxing Day (moved to the next weekdays when on a weekend), and
--   a 1:00 pm early close on Christmas Eve when it is a weekday.
-- Stage 4's warning treats unconfirmed years as missing, so Dad is reminded to
-- check them against the TSX page once it is published.
--
-- closes_at is US/Canada Eastern time. 1:00 pm Eastern is 11:00 am in Edmonton.

insert into public.market_holidays (market, holiday_date, name, kind, closes_at, confirmed, source_url) values
  -- NYSE 2026
  ('nyse', date '2026-01-01', 'New Year''s Day',                     'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-01-19', 'Martin Luther King, Jr. Day',         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-02-16', 'Washington''s Birthday',              'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-04-03', 'Good Friday',                         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-05-25', 'Memorial Day',                        'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-06-19', 'Juneteenth',                          'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-07-03', 'Independence Day (observed)',         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-09-07', 'Labor Day',                           'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-11-26', 'Thanksgiving Day',                    'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-11-27', 'Day after Thanksgiving (early close)', 'early_close', '13:00', true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-12-24', 'Christmas Eve (early close)',         'early_close', '13:00', true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2026-12-25', 'Christmas Day',                       'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  -- NYSE 2027
  ('nyse', date '2027-01-01', 'New Year''s Day',                     'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-01-18', 'Martin Luther King, Jr. Day',         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-02-15', 'Washington''s Birthday',              'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-03-26', 'Good Friday',                         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-05-31', 'Memorial Day',                        'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-06-18', 'Juneteenth (observed)',               'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-07-05', 'Independence Day (observed)',         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-09-06', 'Labor Day',                           'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-11-25', 'Thanksgiving Day',                    'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-11-26', 'Day after Thanksgiving (early close)', 'early_close', '13:00', true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2027-12-24', 'Christmas Day (observed)',            'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  -- NYSE 2028 (no New Year's Day holiday: Jan 1 is a Saturday)
  ('nyse', date '2028-01-17', 'Martin Luther King, Jr. Day',         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-02-21', 'Washington''s Birthday',              'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-04-14', 'Good Friday',                         'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-05-29', 'Memorial Day',                        'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-06-19', 'Juneteenth',                          'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-07-03', 'Day before Independence Day (early close)', 'early_close', '13:00', true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-07-04', 'Independence Day',                    'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-09-04', 'Labor Day',                           'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-11-23', 'Thanksgiving Day',                    'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-11-24', 'Day after Thanksgiving (early close)', 'early_close', '13:00', true, 'https://www.nyse.com/markets/hours-calendars'),
  ('nyse', date '2028-12-25', 'Christmas Day',                       'closed',      null,   true, 'https://www.nyse.com/markets/hours-calendars'),

  -- TSX 2026 (published)
  ('tsx', date '2026-01-01', 'New Year''s Day',             'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-02-16', 'Family Day',                  'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-04-03', 'Good Friday',                 'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-05-18', 'Victoria Day',                'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-07-01', 'Canada Day',                  'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-08-03', 'Civic Holiday',               'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-09-07', 'Labour Day',                  'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-10-12', 'Thanksgiving Day',            'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-12-24', 'Christmas Eve (early close)', 'early_close', '13:00', true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-12-25', 'Christmas Day',               'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2026-12-28', 'Boxing Day (in lieu)',        'closed',      null,    true, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  -- TSX 2027 (calculated, unconfirmed)
  ('tsx', date '2027-01-01', 'New Year''s Day',             'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-02-15', 'Family Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-03-26', 'Good Friday',                 'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-05-24', 'Victoria Day',                'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-07-01', 'Canada Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-08-02', 'Civic Holiday',               'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-09-06', 'Labour Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-10-11', 'Thanksgiving Day',            'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-12-24', 'Christmas Eve (early close)', 'early_close', '13:00', false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-12-27', 'Christmas Day (in lieu)',     'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2027-12-28', 'Boxing Day (in lieu)',        'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  -- TSX 2028 (calculated, unconfirmed). Dec 24 is a Sunday, so no early close.
  ('tsx', date '2028-01-03', 'New Year''s Day (in lieu)',   'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-02-21', 'Family Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-04-14', 'Good Friday',                 'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-05-22', 'Victoria Day',                'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-07-03', 'Canada Day (in lieu)',        'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-08-07', 'Civic Holiday',               'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-09-04', 'Labour Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-10-09', 'Thanksgiving Day',            'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-12-25', 'Christmas Day',               'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar'),
  ('tsx', date '2028-12-26', 'Boxing Day',                  'closed',      null,    false, 'https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar');
