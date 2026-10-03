-- Stage 1: starting reference data. It lives in a migration, not seed.sql,
-- because production never runs the seed and needs these rows too.
-- No personal data.

-- The three stock funds. Yields are percent per year. Colours are the fixed
-- option colours used on every chart (Dad can change them later).
insert into public.funds (id, name, proxy_symbol, market, colour, dividend_yield, sort_order) values
  ('dow',       'Dow Jones',  'DIA', 'nyse', '#2F80ED', 1.800, 1),
  ('nasdaq100', 'Nasdaq-100', 'QQQ', 'nyse', '#F76B15', 0.600, 2),
  ('tsx',       'TSX',        'XIC', 'tsx',  '#0B6E69', 2.800, 3);

-- Starting rates, percent per year. Effective 2026-01-01 so every date the app,
-- the time machine or a what-if touches has a rate.
insert into public.rates (vehicle, gic_term, rate, effective_date, note) values
  ('savings', null, 2.000, date '2026-01-01', 'Starting rate.'),
  ('gic',     1,    2.500, date '2026-01-01', 'Starting rate.'),
  ('gic',     3,    3.000, date '2026-01-01', 'Starting rate.'),
  ('gic',     6,    4.000, date '2026-01-01', 'Starting rate.'),
  ('gic',     9,    4.500, date '2026-01-01', 'Starting rate.'),
  ('gic',     12,   5.000, date '2026-01-01', 'Starting rate.'),
  ('gic',     24,   6.000, date '2026-01-01', 'Starting rate.');

-- Settings defaults. inflation_rate is percent per year.
insert into public.settings (key, value, effective_date, note) values
  ('deposit_cap_cents', '100000', date '2026-01-01', 'Starting cap: $1,000 in net deposits per kid.'),
  ('inflation_rate',    '2.0',    date '2026-01-01', 'Starting rate: the Bank of Canada''s 2% target.');

-- The starter glossary behind every ? in the app. Draft wording for Dad to review.
insert into public.glossary (term, kid_text) values
  ('Savings account', $$A safe place for your money that you can use any time. It pays a little interest, less than a GIC or a stock fund might earn.$$),
  ('Interest', $$Money the bank pays you for keeping your money there. The more you have saved, and the longer you leave it, the more interest you get.$$),
  ('Interest rate', $$How much interest you earn in a year, shown as a percent. At 2% a year, $100 earns $2 in a year.$$),
  ('Percent (%)', $$"Out of 100." 5% of $100 is $5, and 5% of $200 is $10.$$),
  ('Per year', $$Rates are for a whole year. If you keep your money in for half a year, you earn about half as much.$$),
  ('Rate of return', $$How much your money grew (or shrank), as a percent of what you put in. If $100 grows to $110, your rate of return is 10%.$$),
  ('Compounding', $$When your interest starts earning interest too. Your money grows a little faster every time, so time matters as much as the amount.$$),
  ('Compounding frequency', $$How often interest is added to your money so it can start earning interest too. Big Bucks adds savings interest once a month.$$),
  ('Simple interest', $$Interest worked out only on the money you started with, not on earlier interest. GICs in Big Bucks pay simple interest.$$),
  ('GIC', $$Short for Guaranteed Investment Certificate. You promise to leave your money alone for a set time, and in return you get a higher rate that can't change.$$),
  ('Term', $$How long you promise to leave your money in a GIC: 1, 3, 6 or 9 months, or 1 or 2 years. A longer promise usually pays more.$$),
  ('Maturity', $$The day your GIC's promise is finished. You get your money back plus the interest, and you choose what to do next.$$),
  ('Locked-in rate', $$The rate you get on the day you buy a GIC. It stays the same until the GIC matures, even if rates change later.$$),
  ('Renew', $$Buying a new GIC with your matured money, for the same term, at today's rate.$$),
  ('Breaking a GIC early', $$Taking your money out of a GIC before it matures. You get back what you put in, but you lose all the interest. Breaking a promise has a price.$$),
  ('GIC ladder', $$Having several GICs that finish at different times, like the steps of a ladder. Some of your money is always close to being free.$$),
  ('Stock', $$A tiny piece of a company. When the company does well its stock price usually goes up, and when it does badly the price can go down.$$),
  ('Stock market', $$Where people buy and sell stocks. Prices change every day, depending on how many people want to buy or sell.$$),
  ('Stock fund', $$A basket holding pieces of lots of companies at once. Its value goes up and down with all of them together.$$),
  ('Index', $$A list of companies used to measure how part of the stock market is doing, like a scoreboard. The Dow, the Nasdaq-100 and the TSX are all indexes.$$),
  ('Dow Jones', $$An index of 30 big, well-known US companies. It's the steady one of your three funds.$$),
  ('Nasdaq-100', $$An index of 100 of the biggest companies on the Nasdaq stock market, mostly technology companies. It's the thrill ride: bigger ups and bigger downs.$$),
  ('TSX', $$Canada's main stock market. Your TSX fund follows hundreds of big Canadian companies, like banks, energy companies and stores.$$),
  ('ETF', $$Short for exchange-traded fund: a fund that people buy and sell on the stock market. Big Bucks uses the prices of three real ETFs (DIA, QQQ and XIC) to follow each index.$$),
  ('Unit', $$A share of a fund. When you buy, your money turns into units. When you sell, your units turn back into money at that day's price.$$),
  ('Unit price', $$What one unit of a fund costs today. If the unit price goes up, every unit you own is worth more.$$),
  ('Market close', $$The end of the stock market's day, at 2:00 pm in Alberta. The price at that moment is called the close.$$),
  ('Settlement', $$When a buy or sell actually happens. In Big Bucks, trades settle at the next market close, so a Friday evening request happens on Monday.$$),
  ('Market holiday', $$A day the stock market is closed, like Christmas. Trades wait for the next day the market is open.$$),
  ('Daily change', $$How much a fund went up or down since the day before, as a percent. Small ups and downs every day are normal.$$),
  ('Dividend', $$Money a company shares with the people who own its stock. Your funds pay you a dividend every three months, and it goes into your savings.$$),
  ('Dividend yield', $$How much a fund pays in dividends in a year, as a percent of its value. The TSX fund pays the most.$$),
  ('Stock split', $$When a fund cuts each unit into smaller pieces. You get more units, but they're worth exactly the same in total, like cutting a pizza into more slices.$$),
  ('Risk', $$The chance that an investment loses money. Things that can grow more usually come with more risk.$$),
  ('Volatility', $$How much a price jumps up and down. The Nasdaq-100 fund is the most volatile of the three.$$),
  ('Gain', $$When something is worth more than you paid for it. You only lock in a gain when you sell.$$),
  ('Loss', $$When something is worth less than you paid for it. If you sell while it's down, you get less money back. Losses are real.$$),
  ('Average cost', $$What you paid for each unit, on average, counting all your buys. It helps you see whether your fund is up or down.$$),
  ('Diversification', $$Spreading your money across different choices, so one bad day doesn't hurt as much. Don't put all your eggs in one basket!$$),
  ('Liquidity', $$How quickly you can get your money out. Savings is very liquid. A GIC isn't, because you promised to wait.$$),
  ('Inflation', $$Prices slowly going up over time. If things cost 2% more next year, your money needs to grow at least 2% just to buy the same stuff.$$),
  ('Deposit', $$Putting money into your account. New money always lands in savings first.$$),
  ('Withdrawal', $$Taking money out of your account as real cash from Dad. It only comes from savings, and it waits 24 hours so you can sleep on it.$$),
  ('Deposit cap', $$The most you can put in, counting deposits minus withdrawals. Interest and gains can take your total above it, and that's great!$$),
  ('Net deposits', $$All the money you've put in, minus all the money you've taken out.$$),
  ('Balance', $$How much money is in an account right now.$$),
  ('Available', $$Money you can use right now. Money waiting in a request is on hold, so it isn't available until the request is done.$$),
  ('On hold', $$Money set aside for a request that's waiting, so you can't use the same dollars twice.$$),
  ('Total worth', $$Everything you have in Big Bucks added up: savings, GICs and stock funds.$$),
  ('Effective date', $$The day a new rate starts. Dad usually gives a week's notice so you have time to decide what to do.$$),
  ('Special rate', $$A better rate for a short time only. Spot a good deal before it ends!$$),
  ('Statement', $$A monthly summary of your account: what you started with, what came in and went out, what you earned, and what you ended with.$$);
