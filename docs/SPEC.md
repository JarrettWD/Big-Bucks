# Big Bucks — Product Spec

The source of truth for what to build. Written by Dad as the app's framework; the final section, Build decisions, settles details for the builder.

## Purpose & learning goals

The app is a pretend bank and brokerage where Dad holds the real cash. It lets the two girls practise the trade-off between safety, patience and risk with money they actually care about.

By using it, each girl should be able to explain:

- **Liquidity:** savings is always available but pays the least.
- **Commitment:** a GIC pays more because you promise not to touch it, and a longer promise pays more still.
- **Risk and reward:** the stock fund can grow the most, but it can also lose money, and short-term swings are normal.
- **Compounding:** interest earns interest, so time matters as much as the amount.
- **Diversification:** splitting money across options smooths out the ride.

Success test: after 6 months, each girl can say why she picked her mix and what she would change.

## App layout & screens

Each girl's app has four tabs. It should look colourful and fun, with icons and badges, and be easy to navigate.

**App name and icon (decided): Big Bucks.** The icon is a gold dollar sign wearing moose antlers, with a pink zig-zag arrow climbing to the top right, on a purple rounded square with small sparkles. The pun: a buck has antlers, and bucks are dollars. Brand colours: purple #5B3FD1, gold #FFD166, pink #FF4F87, white, with Fredoka as the display font. Tagline: "Watch your bucks grow."

**Look and feel**

- Colourful, visually pleasing icons and badges.
- Every financial term has a small **?** that opens a brief, accurate, kid-friendly explanation (rate of return, interest, term, compounding frequency, index, GIC, and so on).
- Same colour for each option everywhere: savings, GICs and each of the three stock funds.
- **Make it hers:** each girl picks her own theme colour (from a set that keeps text readable) and a cute animal avatar, and can change them any time. The option colours (savings, GICs, each fund) stay fixed so graphs always read the same.
- **Animal avatars:** about 16 cute animals to choose from (fox, panda, koala, bunny, cat, puppy, owl, penguin, unicorn, tiger, frog, hedgehog and more), each on a circle in her theme colour. The set comes from Microsoft's free Fluent Emoji illustrations (MIT licence, bundled with the app). It includes a **moose** as a nod to the app's antlers, drawn in the Big Bucks style if the set doesn't have one.
- **Accessories unlocked by badges:** each badge unlocks something her avatar can wear, such as a party hat for her first GIC, sunglasses for holding a fund through a drop, a crown for reaching a goal, or a graduation cap for a GIC held to maturity. The fun is tied directly to good decisions.
- Her avatar appears on Home, on her badges and next to her questions to Dad.

**1. Home**

- Total worth at the top.
- Savings total.
- GIC total, with a breakdown of each GIC held (amount, rate, maturity date).
- Stock market total, with:
  - Investment mix across the Dow, Nasdaq-100 and TSX funds
  - Daily % change for each fund
  - A sparkline of the past 30 days for each fund
- **Action banner** when something needs her: a GIC has matured and she must choose what's next, or a request was approved or declined.
- **Recent activity:** a list of her deposits, trades, interest and approvals, newest first, with a "See all" link to her full history.

**2. Graphs**

- The graphs listed under Graphs & dashboards.

**3. Buy / Sell**

- Dropdowns to choose which option to move money *from* and *to*.
- Buy or sell selection.
- Amount entry, showing how much is available (money held by pending requests is excluded).
- Warnings based on the house rules, for example "Moving money out of this GIC before it matures means you lose all $4.20 of interest earned so far."
- A confirmation screen with a summary before she submits. Moves go through automatically; deposits and withdrawals go to Dad for approval.

**4. Wish List**

- She adds things she'd love to have: a name, rough price, an optional link and photo, and how much she wants it (1 to 5 stars). She can reorder the list any time.
- **Keep your eye on the prize:** each item shows how close her total worth is ("You're 40% of the way there") and, at current rates, roughly when she could afford it.
- **Still want it?** An item can become a savings goal only after it has been on the list for 7 days. The app asks "Still want this?", a gentle lesson in wants versus impulses.
- **Mom and Dad can see it**, and the tab says so plainly ("Mom and Dad can see your wish list"), so it's never a secret. That gives you birthday and Christmas ideas without asking.
- **Parent-only "Got it" marker:** you can quietly mark an item as bought, so the other parent doesn't buy it too. The girl never sees the marker, and she can still save for or remove the item.
- When she deletes an item or marks it "I got this", it moves to a Done list rather than disappearing.

**Parent view** is a separate screen set, only for the parent login (see Graphs & dashboards).

**Admin (parent) account: rate settings**

- **One simple screen** lists the current savings rate and every GIC term's rate (1M to 2Y). Tap a rate, type the new one, and save. No other screens or steps.
- **Effective date:** defaults to 7 days from today so the girls have time to react, but Dad can pick any date, including today.
- **Optional note** explaining why ("The Bank of Canada cut rates"), shown to the girls with the change.
- **Specials:** a toggle to make a rate limited-time, with a start and end date; it reverts to the regular rate automatically.
- **Preview before saving:** shows the old and new rate, the effective date, and a reminder that existing GICs keep their locked-in rate.
- **History:** every past change is listed with its date and note.
- **Deposit cap:** the same settings screen shows the cap (starting at $1,000 in net deposits per girl). Dad can raise or lower it for both girls at once, which keeps the rules fair. Lowering it below what a girl has already deposited never takes money away; it only blocks new deposits until she is back under the cap. The girls get an in-app notice when the cap changes.
- **Inflation rate:** a setting (starting at 2.0%, the Bank of Canada's target) used by the inflation view. Dad can update it now and then to match the news.

**How the girls are notified (in the app)**

- As soon as Dad saves, each girl gets an in-app notice: a banner on her Home tab plus a badge on a notifications bell. It shows the old and new rate, when it takes effect and Dad's note. For example: "Savings rate drops from 2.0% to 1.5% on Nov 1. Tip: GICs bought before then keep today's rates."
- On the effective date, a second notice says the new rate is now live.
- Notices stay in her notifications list until she opens them, so none are missed.
- The parent dashboard shows whether each girl has seen the notice.
- Phone push notifications are a version 3 idea; in version 1, notices appear inside the app.

**Onboarding (first use, about 30 minutes together)**

1. A short, skippable tour of the four tabs and the three options, using the **?** explanations.
2. She picks her theme colour and avatar.
3. She adds a first wish-list item or goal.
4. **Account agreement:** the house rules shown in kid-friendly words; she and Dad both tap to sign, and the signed copy stays in her history.
5. **First real decision:** her first deposit lands in savings, and she chooses what to do with it, with Dad beside her.

New features added later get a one-screen "What's new" tour the first time she opens the app.

## Users, accounts & privacy

There are three roles, and each girl sees only her own money. The database enforces this with Supabase row-level security, not just the screens.

| Role | Who | Can see | Can do |
|---|---|---|---|
| Parent (admin) | Dad (Mom joins in version 2) | Every account, all history, all settings | Approve or reject requests, record cash in/out, change rates, correct mistakes |
| Investor | Older daughter | Her own balances, history and graphs | Request deposits, withdrawals, GIC purchases and moves between options |
| Investor | Younger daughter | Her own balances, history and graphs | Same as her sister |

- **Login (decided): username + PIN** for each girl. Supabase Auth doesn't offer this directly, so each username maps to a hidden email (for example kid1@kids.local; real usernames are set at runtime, never in the repo) and the PIN is the password. Supabase needs at least 6 characters, so use 6-digit PINs.
- **Isolation:** every table row carries an `account_id`. RLS policies allow an investor to read only rows where `account_id` matches her own; the parent role reads everything.
- **No sibling comparison by default:** there is no leaderboard or shared view. If you ever want one (for example, a family "market day" review), it would be a parent-only screen.
- **Test accounts and feature switches:** Dad keeps a test-kid account that is marked as a test. It's invisible to the girls, left out of the liability total and never triggers alerts. Each new feature has an on/off switch that can be turned on for test accounts only, so Dad can try it on his phone before the girls see it.
- **Adding people later:** the model should allow more investor accounts (a cousin, for instance) without code changes.

## The three vehicles

Each option trades access for reward: savings is always available, GICs pay more for a promise not to touch the money, and the stock funds can grow the most but can also fall. The starting rates below are set so each option wins in some situations and loses in others: savings < GICs < the stock funds' long-run average. They are boosted above real bank rates so growth is visible on small balances. Dad can change them any time (see Rates & rate changes).

### 1. Savings account

- All new money lands here first, like a real bank.
- Withdraw or move out any time (after parent approval).
- Interest is calculated daily on the balance and paid monthly, shown as an "Interest paid" line.
- Starting rate: 2.0% per year (variable: Dad raises or cuts it occasionally).

### 2. GICs (the girls pick the term)

Each GIC is its own holding with a fixed rate locked in on the day it is bought. A girl can hold several at once, which naturally teaches laddering.

| Term | Starting rate (%/yr) | Early withdrawal |
|---|---|---|
| 1 month | 2.5 | Principal back, interest forfeited |
| 3 months | 3.0 | Principal back, interest forfeited |
| 6 months | 4.0 | Principal back, interest forfeited |
| 9 months | 4.5 | Principal back, interest forfeited |
| 1 year | 5.0 | Principal back, interest forfeited |
| 2 years | 6.0 | Principal back, interest forfeited |

- **Minimum purchase:** $10, so they can't scatter coins across 20 GICs.
- **Interest:** simple interest, paid at maturity.
- **At maturity**, the girl picks one of three: renew at the *current* rate for the same term, move to savings, or choose a new term. If she doesn't choose within 7 days, it moves to savings automatically.
- **Early withdrawal** is allowed for the whole GIC only (no partial breaks) and costs all interest earned. This is the lesson: breaking a promise has a price.

### 3. Stock market funds

Three funds to choose from: **Dow Jones** (steady: 30 big US companies), **Nasdaq-100** (the thrill ride: mostly big tech, with bigger ups and downs) and **TSX** (Canada's market). A girl can hold any mix of them.

**Expected return:** about 8–10% a year on average over the long run, but a fund can drop 20% or more in a bad stretch. The longest GIC (6%) is deliberately kept well below this, so choosing stocks is a real trade of safety for a higher expected reward. The Nasdaq-100 is the most tempting and the most volatile of the three: it has beaten the other two over long stretches, but it can fall much further (about a third in 2022, and about 80% in the 2000–02 dot-com crash).

- **Unit pricing:** each fund has a unit price that follows its index. Buying $100 when the fund's price is 420 buys 100 ÷ 420 = 0.238 units; value = units × today's close. Partial sells are allowed.
- **Settlement:** buys and sells price at the next market close, which teaches that markets aren't open 24/7. A request made Friday evening settles at Monday's close.
- **Sale proceeds** go to savings.
- **Price source:** use the ETFs that mirror each index, since free data plans often don't include the index values themselves: DIA (Dow), QQQ (Nasdaq-100) and XIC (TSX). Their returns are almost identical to the index.
- **Currency:** balances are always in Canadian dollars. For the Dow and Nasdaq-100 funds, the app uses only the % change, so there is no exchange-rate effect. The TSX is already in Canadian dollars.
- **Holidays:** the TSX closes on Canadian holidays and the US markets on US holidays, so each fund handles its own closed days.
- **Dividends:** all three indexes track price only and ignore dividends, so they understate real returns by roughly 1.5–3% a year. Decided: each fund pays a dividend every quarter as a "Dividend" line into savings, at a yearly yield Dad sets per fund (starting roughly Nasdaq-100 0.6%, Dow 1.8%, TSX 2.8%). This makes returns realistic and shows that the TSX pays more income.
- The value can and will fall below what was put in. That is the point.

## Rates & rate changes

Rates are stored as dated records, never overwritten, so history is always correct and the girls can see rates move like a real bank's.

- **Savings:** a new rate applies from its effective date onward. Interest before that date uses the old rate.
- **GICs:** a rate change affects only *new* purchases and renewals. Existing GICs keep the rate they were bought at. That is a key lesson: locking in a good rate protects you when rates drop.
- **Notice:** by default, give 7 days' notice of a change as an in-app message (Dad can pick a sooner date; see Admin account under App layout & screens) ("Savings rate drops to 1.5% on Nov 1"), so the girls can react, for example by buying a GIC before rates fall.
- **Who changes rates:** parent only, from a settings screen, with an effective date and an optional note explaining why ("The Bank of Canada cut rates").
- **Optional realism:** peg rates loosely to real Canadian bank rates each quarter, so rate changes line up with the news they may hear about.
- **Specials:** now and then, offer a limited-time rate (for example, a 1-year GIC at 6% for one week) so the girls learn to spot and weigh an offer.
- **Inverted-curve month:** rarely, make short terms pay more than long ones, as real markets sometimes do. It rewards reading the rate table instead of always picking the longest term.

**What the boosted rates cost Dad:** because the rates beat real banks, Dad pays the difference out of pocket. At $1,000 each with average returns of 3–5%, that's roughly $60–100 a year for both girls, more in a strong stock year (and less, or even a gain, in a bad one). The parent dashboard's liability total shows the running figure.

## Money flow: deposits, withdrawals, approvals

The girls request and Dad approves, because real cash is behind every number. The ledger only changes once money has actually changed hands.

**Request and approval flow:** the girl submits a request → the amount is held so it can't be used twice → Dad reviews it on the parent dashboard → Dad approves (and hands over or receives the cash) or declines with a reason → the ledger is updated.

A declined request keeps its reason ("Wait until after Christmas") so the girl learns why.

**Request types**

- **Deposit** (cash in): always into savings.
- **Withdrawal** (cash out): from savings only. To cash out of a GIC or stock fund, she first moves it to savings.
- **Move** between options, with no cash involved: savings → GIC, savings → stock fund, fund → savings, GIC → savings, and so on. Moves are approved automatically (stock moves still settle at the next close), and Dad is notified on the parent dashboard. Only deposits and withdrawals, where real cash changes hands, wait for Dad.

**Rules (decided)**

- Minimum amounts: $5 for savings, $10 for GICs and stock funds.
- **Deposit cap:** starts at $1,000 per girl in net deposits (deposits minus withdrawals), and Dad can change it from the admin account. Interest and gains can take her balance above it. The Buy / Sell screen shows how much room is left.
- New money lands in savings first.
- **Pending requests hold the money.** Money in a pending request can't be used for another one, so she can't request the same $50 twice.
- **Stock trading limit:** one trade per fund per day, buy or sell. She can act on each of the Dow, Nasdaq-100 and TSX funds once a day.
- **Cooling-off delay:** withdrawals wait 24 hours before Dad can approve them, to teach "sleep on it" before spending. Stock sells aren't delayed; they already wait for the next market close.
- **Warnings** on the Buy / Sell screen before she confirms: interest lost when breaking a GIC early, a stock fund worth less than she paid, or a trade that exceeds her available balance.

## Graphs & dashboards

The Graphs tab shows how each option has grown and teaches risk against reward. The Home tab's totals and sparklines are covered under App layout & screens.

| Graph | Type | What it teaches | Time ranges |
|---|---|---|---|
| Total worth over time | Stacked area, one colour per option | How the pieces add up | 1M, 3M, 1Y, All |
| Growth by option | One line per option (savings, GICs, each stock fund), % gain since first deposit | Risk vs reward side by side: smooth savings, stepped GICs, bumpy stocks | 1M, 3M, 1Y, All |
| Money in vs money earned | Two lines: total deposited vs current value | The gap between them is what investing earned | All |
| My mix today | Donut: % in savings, GICs, Dow, Nasdaq-100, TSX | Diversification | Now |
| GIC ladder | Timeline bars, one per GIC, to its maturity date | When money unlocks | Next 24 months |
| Stock fund detail | Line of each fund's unit value, with her buy and sell points marked | Buying low and selling high is hard to time | 1M, 3M, 6M, since first purchase |

**Rate of return on stock funds** (1M, 3M, 6M, since first purchase) counts only gains and losses, not money deposited. Decided: her gain divided by what she paid for the units she holds, shown as both $ and %. The fund's own performance still shows on the fund charts.

**Design notes**

- Use the same colour for each option everywhere.
- Show deposits and withdrawals as dots on the lines, so a jump from new money isn't mistaken for growth.
- Keep percentage and dollar views switchable: the younger girl may relate more to dollars, the older one to percentages.
- **Parent dashboard:** both girls' totals, pending requests to approve, upcoming GIC maturities, rate settings, and the total real cash you owe them (your "liability").

## Learning features

These turn a ledger into a teacher. The **?** explanations (App layout & screens) are in version 1, along with every feature below except the Rule of 72 calculator and market news cards, which wait for version 2.

- **What-if comparison:** "If you had put everything in savings / a 1-year GIC / the Nasdaq-100, you'd have $X today."
- **Market moves explained:** when any fund moves more than 2% in a day, show a one-line note that Dad can edit ("Big drop today. This happens a few times a year. Long-term, markets have recovered.").
- **Goals:** each girl names a goal ("Switch game, $450") and sees a progress bar plus a projected date at current rates.
- **Rule of 72 calculator:** "At 4%, your money doubles in about 18 years."
- **Monthly statement:** starting balance, deposits, withdrawals, interest and gains, and ending balance.
- **Age-appropriate views:** a simpler "basic" mode for the younger girl (big numbers, fewer graphs) and a detailed mode for the older one. Either can switch.
- **Reflection prompt:** after selling a stock fund, ask "Why did you sell?" and keep the answer in her history to revisit later.
- **Compare the markets:** with three funds, show how the Dow, Nasdaq-100 and TSX did over the same period, a natural lesson that markets differ.
- **Inflation view:** a toggle on Home and on each option that shows what her money will actually buy. For example: "Your $100 in savings grows to $102, but things cost 2% more, so it buys about the same as $100 does today." Savings suddenly looks less safe, and the stock funds' extra growth makes sense.
- **Market news cards:** (version 2, fully automatic) when a fund moves more than 2% in a day, the nightly job pulls that day's market headlines from the price service and an AI model writes a short, kid-level reason, labelled "Written by AI, may not be the whole story". Dad can edit or hide any card but never has to write one ("Tech companies fell after a big chipmaker's results disappointed"), so market moves connect to real news. Cards are saved so she can scroll back through what happened.

## Data model (Supabase)

One append-only ledger is the source of truth. Balances and graphs are calculated from it, never stored, so nothing can drift out of sync.

| Table | Purpose | Key fields |
|---|---|---|
| `profiles` | Links a login to a role | user_id, role (parent / investor), account_id, username, display_name |
| `accounts` | One per girl | id, name, created_at, is_test, view_mode (basic / detailed), theme_colour, avatar_animal, avatar_accessory, agreement_signed_at, onboarding_done_at |
| `funds` | The three stock funds | id (dow / nasdaq100 / tsx), name, proxy_symbol (DIA / QQQ / XIC), colour, dividend_yield |
| `requests` | What the girls ask for | id, account_id, type (deposit / withdraw / move), from_vehicle, to_vehicle, fund_id, gic_term, amount, status (pending / approved / declined / settled), held_amount, parent_note, reflection (her answer to "Why did you sell?"), created_at, decided_at |
| `transactions` | The ledger | id, account_id, vehicle (savings / gic / stock), fund_id, gic_id, type (deposit / withdraw / interest / transfer_in / transfer_out / penalty / dividend), amount_cents, units, unit_price, request_id, posted_at |
| `gic_holdings` | Each GIC bought | id, account_id, principal_cents, rate, term_months (1 / 3 / 6 / 9 / 12 / 24), start_date, maturity_date, status (active / matured / broken), maturity_choice |
| `rates` | Dated rate history | id, vehicle, gic_term, rate, effective_date, note |
| `fund_prices` | Daily close per fund | fund_id, date, close |
| `goals` | Savings goals | id, account_id, name, target_cents |
| `notes` | Market explainers and rate notices | id, date, fund_id, body, audience |
| `glossary` | The **?** explanations | term, kid_text |
| `settings` | Admin-editable app settings, dated like rates | id, key (deposit_cap_cents starting at 100000; inflation_rate starting at 2.0%; feature switches, each off, test accounts only, or everyone), value, effective_date, note, changed_by |
| `job_runs` | What each scheduled job completed, for catch-up and alerts | id, job (prices / settle / interest / monthly / gic_maturity / dividends / reconcile / backup), run_for_date, status (ok / failed / retrying), details, started_at, finished_at |
| `questions` | "Something looks wrong?" threads | id, account_id, transaction_id, message, parent_reply, status (open / answered), created_at, answered_at |
| `wishlist_items` | Each girl's wish list | id, account_id, name, price_cents, link, photo_url, stars (1–5), sort_order, status (wanted / goal / got_it / removed), parent_got_it (parent-only), created_at |
| `badges` | Badges each girl has earned | id, account_id, badge, unlocks_accessory, earned_at, related_transaction_id |
| `notifications` | In-app notices to each girl (rate changes, approvals, maturities) | id, account_id, type (rate_change / rate_live / request / gic_maturity), title, body, related_rate_id, created_at, read_at |

- **Money as integers:** store cents (bigint), not decimals, to avoid rounding errors. Units can be decimals.
- **Corrections:** never edit or delete a ledger row. Post a reversing entry, just like real accounting. The database enforces this: no role, not even the parent, can update or delete rows in `transactions`, `rates` or `settings`.
- **Available balance** = balance minus money held by pending requests.
- **Views:** a database view such as `daily_balances` calculates each account's value per vehicle and fund per day for the graphs.
- **RLS:** investors can select rows where account_id is their own and insert only into `requests`. The parent can do everything. Only the server writes to `transactions`.

## Tech stack & automation

Use the same stack as Dad's existing food inventory app (React PWA on GitHub Pages, Supabase backend), so there is nothing new to learn or host.

| Piece | Choice | Notes |
|---|---|---|
| Front end | React PWA | Installable on Android phones and tablets from Chrome; works on the girls' devices |
| Charts | Recharts or Chart.js | Both handle line, stacked area, donut and sparkline charts |
| Hosting | GitHub Pages | Same as the food app |
| Database and auth | Supabase (new project) | Keep it separate from the food app's project |
| Fund prices | Free market-data API, such as Alpha Vantage or Finnhub, using DIA, QQQ and XIC | 3 lookups a day is well within free limits; API key lives only in the Edge Function, never in the app |
| Scheduled jobs | Supabase Edge Function + pg_cron | See below |
| Avatars | Microsoft Fluent Emoji animals, plus accessory overlays | Free under the MIT licence; bundled with the app, so no outside service is needed |

**Nightly job (after the markets close at 4:00 pm Toronto time, which is 2:00 or 3:00 pm in Alberta; runs at 4:30 pm Alberta time all year)**

1. Fetch each fund's close and save it to `fund_prices`. If that fund's market was closed (weekend or its own holiday), reuse its last close.
2. Settle pending stock buys and sells at that fund's close.
3. Accrue savings interest for the day.

**Monthly and maturity jobs**

- On the 1st: post the month's savings interest as a transaction and create statements.
- Daily: mature any GICs due today, post their interest, and show the girl the action banner to choose what's next. After 7 days with no choice, move the money to savings.
- Quarterly (first business day of Jan, Apr, Jul, Oct): pay each stock fund's dividend, a quarter of its yearly yield on her holding's value, into savings.

**Backfill:** load a year or two of historical closes for all three funds on setup, so graphs and what-ifs work from day one.

**Backups & data protection (decided)**

The ledger is a record of real money owed, so history must never be lost. The plan follows the 3-2-1 rule: three copies, on two different services, with one away from Supabase. Supabase's free tier has no automatic backups, so every copy below is our own.

1. **Protect history inside the database.** The ledger, rate history and settings are append-only, and the database itself enforces it: no role, not even the parent, can update or delete rows in `transactions`, `rates` or `settings`. Mistakes are fixed with reversing entries. This guards against app bugs and slips, which are more likely than Supabase losing data.
2. **Daily automatic backup to a private GitHub repo.** A scheduled GitHub Action runs `supabase db dump` (the full schema and data as SQL) and exports each table as CSV, then commits them. Git keeps every version, so any past day can be recovered. The same run also makes a normal app request through the API. Supabase counts outside requests like these as activity (its docs don't say whether internal scheduled jobs count), so the project gets two outside hits every day and won't pause, even if the girls don't open the app for weeks. The database connection string lives only in GitHub secrets; use the session pooler string, since the direct connection may not work from GitHub's runners.
3. **A second copy on your own computer.** A scheduled job on your computer pulls the GitHub repo into a folder synced to iCloud or OneDrive. That puts a copy with a different provider, which also survives losing GitHub access.
4. **Download backup button** on the parent dashboard: one tap exports every table as a zip of CSV and JSON. Use it before big changes such as a rate change or a correction.
5. **Know when a backup fails.** GitHub emails you if the daily run fails, and the run also fails on purpose if the export is empty or has fewer ledger rows than the day before.
6. **Test a restore every few months.** Restore the latest dump into the local copy of Supabase on Dad's computer and check that each girl's balances match the live app. A backup that has never been restored isn't proven.

Retention: keep everything. Nothing is ever pruned, and the files stay small for years. If you ever want managed backups, Supabase's Pro plan (about US$25/month) adds daily backups, but the plan above does not depend on it.

## Reliability & fairness safeguards

The girls will only trust Big Bucks, and stay interested, if the numbers are always right. These rules make sure a bug, an outage or a missed day never short-changes them.

**Every money calculation is exact and in her favour**

- **One place does the maths.** Interest, dividends, penalties and trades are calculated only by server-side database functions, never in the app on a phone. Each one runs as a single database transaction, so it either fully happens or doesn't happen at all.
- **Rounding favours the girl.** Interest accrues daily in fractions of a cent and is rounded only when it's posted. Any rounding goes up to the next cent, never down.
- **Clear day-count rule:** interest uses actual days out of 365 (366 in a leap year), and every date is in Alberta time (UTC−6 all year from Nov 1, 2026), so "today" means the same thing everywhere.
- **Weekends and holidays:** a GIC that matures on a weekend or holiday still matures that day, with interest to that day. A trade waits for the fund's next real market close.

**Nothing is ever missed or counted twice**

- **Catch-up jobs.** Each nightly, monthly and quarterly job records the last day it completed. When it runs, it processes every day since then in order, so a paused project, an outage or a failed run is filled in automatically the next time.
- **Never twice.** Each posting has a unique key (account, type, date), and the database rejects a duplicate, so a job that runs twice or retries can't double-pay or double-charge.
- **No stale prices.** If the price service is down, the job retries. A trade never settles on an old or guessed price; it waits for the real close for its day, which is backfilled once available.
- **Fund events:** if a fund's ETF splits, the job adjusts units so her holding's value doesn't change.
- **Stale requests:** a deposit or withdrawal Dad hasn't answered within 7 days expires, and the held money is released, with a notice explaining why.

**Daily checks, with alerts to Dad**

- **Reconciliation every night:** for each girl, recalculate every balance from the ledger and compare with what the app shows; check that total cash in, minus cash out, plus earnings equals her total worth; and confirm every active GIC and fund holding adds up.
- **Health alert:** any failed job, missing price, mismatch or backup problem sends Dad an alert on the parent dashboard and by email the same day. The girls never see a wrong number while it's investigated; the affected figure shows "Updating…" instead.

**Transparency the girls can check**

- **"How was this calculated?"** on every interest, dividend and penalty line shows the working, for example "$250.00 × 2.0% × 30/365 = $0.42".
- **"Something looks wrong?" button** on any line sends Dad a flagged question with that line attached. He answers in the app, and the thread stays in her history.
- **Errors are corrected in her favour, openly.** If a mistake is ever found, a correcting entry is posted with a plain note explaining it, never a silent change.

**Tested before the girls use it**

- **A test suite of known answers:** for example, $100 at 5% for a 1-year GIC = exactly $105.00, a broken GIC pays $0 interest, and a trade at a known close buys an exact number of units. Every change to the app must pass these before it goes live.
- **Time machine in a test copy:** a local copy of Supabase on Dad's computer (the free Supabase CLI) can fast-forward a simulated year in minutes (rate changes, maturities, dividends, a market crash, a missed week) to prove the numbers hold up.
- **Security tests:** automated checks that one girl can never see or change the other's data, and that nobody can edit history.
- **Login protection:** after 5 wrong PINs, a girl's login locks for 15 minutes and Dad is notified. The parent login uses a strong password plus a second factor.

**Keeping them excited**

- **Badges reward good decisions, never activity** (version 1). Examples: first GIC, a GIC held to maturity, holding a fund through a 10% drop, a GIC ladder with three or more rungs, first dollar of interest, reaching a goal. There are no daily streaks, trade counts or rewards for checking the app, which would teach the opposite of patience.
- **Weekly recap** (version 2): a short Sunday summary of what her money earned that week and what's coming up, such as a GIC maturing.

## House rules & edge cases

Agree on these with the girls before the first deposit. A written "account agreement" they sign makes it feel real.

- **Losses are real.** If the stock fund is down when she sells, she gets less. Without this, the risk lesson disappears.
- **Gifts and allowance.** Decide whether birthday money or allowance can go straight in (within the deposit cap). There is no matching bonus; the boosted rates already make growth visible.
- **Fairness.** Same rates and rules for both girls, even though they have separate accounts.
- **Market crashes.** Talk through in advance what a 20% drop would look like in dollars, so it isn't a shock.
- **Data safety.** Keep backups (see Tech stack); this is effectively a record of money you owe.

## Decisions & phasing

Build a small version 1 that the girls use for a month, then add features based on what they actually do.

**Launch plan (decided): Dad's solo beta, then a staged rollout.**

1. **Solo beta.** Before the girls see anything, Dad builds and tests all of version 1 (both phases) himself with pretend test-kid accounts, working through `docs/ACCEPTANCE.md`.
2. **Both sides on one Android phone.** Install the app from Chrome ("Install app" or "Add to Home screen") and sign in as a test kid. Because the installed app shares Chrome's sign-in, open the admin side in a second browser such as Firefox or Samsung Internet. Flip between them to request as a kid and approve as admin.
3. **Where the beta lives.** Supabase's free plan allows two active projects, and the food inventory app already uses one. So the known-answer tests, time machine and restore tests run in a local copy of Supabase on Dad's computer (the free Supabase CLI), and the solo beta uses the real Big Bucks project with test accounts. Just before the girls' launch, the database is reset to a clean start so no test history remains.
4. **A try-it session with each girl** just before launch, watching what confuses her. Fix those first.
5. **The girls' launch:** a polished, complete version 1 at the $1,000 cap, followed by the first monthly money meeting.
6. **Version 2 features arrive over time as surprises**, each with a "What's new" tour. Each one is switched on for Dad's test account first and tried there before the girls get it.

**Decided**

- GIC terms: 1, 3, 6, 9, 12 and 24 months
- Starting rates: savings 2.0%; GICs 2.5% (1M), 3.0% (3M), 4.0% (6M), 4.5% (9M), 5.0% (12M), 6.0% (24M); stock funds follow their index (about 8–10% long-run)
- Minimums: $5 savings, $10 GICs and stock funds
- Login: username + 6-digit PIN
- New money lands in savings first
- Three stock funds: Dow, Nasdaq-100, TSX
- Stock trading limit: one trade (buy or sell) per fund per day
- Stock rate of return: her gain vs what she paid for the units she holds, in $ and %
- Moves between options auto-approve, with Dad notified; only deposits and withdrawals need Dad's approval
- Cooling-off: cash withdrawals wait 24 hours before Dad can approve
- Dividends: paid quarterly into savings at each fund's yield
- Deposit cap: starts at $1,000 net deposits per girl, changeable from the admin account; no matching bonus
- Version 1 learning features: market moves explained, goals, reflection prompt, what-if comparison, compare the markets, monthly statements, basic / detailed modes
- Hosting: Supabase free tier. Backups: database-enforced append-only history, daily export to a private GitHub repo, a synced copy on your computer, a Download backup button, failure alerts and a restore test every few months
- Four tabs: Home, Graphs, Buy / Sell, Wish List (visible to Mom and Dad, with a parent-only "Got it" marker)
- Inflation view (starting at 2.0%); automatic AI market news cards moved to version 2
- Badges reward good decisions, never activity or streaks
- Each girl picks her theme colour and a cute animal avatar (Fluent Emoji set plus a moose), with accessories unlocked by badges
- Onboarding tour with an in-app account agreement
- Dad's solo beta on an Android phone first; the girls get a complete version 1, then version 2 features arrive as surprises
- Build in two phases, the core first and then the fun layer, both tested in the solo beta
- Mom gets her own admin login in version 2, after phase 1's bugs are worked out

**Version 1, phase 1: the core, built and tested first**

1. Logins and separate accounts with RLS, plus login protection
2. Savings, GICs with every term, and the three stock funds, including quarterly dividends
3. Buy / Sell screen with warnings, request and approval flow, pending holds and the cooling-off delay
4. Scheduled jobs with catch-up and duplicate protection: prices, settlement, interest, GIC maturity and dividends
5. Home tab: totals, GIC breakdown, fund mix, daily % change, 30-day sparklines, action banner, recent activity and notifications
6. Graphs tab: all six graphs under Graphs & dashboards (total worth over time, growth by option, money in vs money earned, my mix today, GIC ladder, stock fund detail), with the standard market-move note (decided 2026-10-03: all six in version 1)
7. **?** explanations, "How was this calculated?" and "Something looks wrong?"
8. Parent dashboard: approvals, plus admin settings for rates, specials, the deposit cap and inflation
9. Safeguards: nightly reconciliation with alerts, backups (daily export, synced local copy, Download backup button), append-only history, and the test suite with its time machine
10. Onboarding tour and in-app account agreement

**Version 1, phase 2: the fun layer, built and tested in the solo beta and included at the girls' launch**

1. Wish List tab
2. Theme colours, animal avatars, badges and badge-unlocked accessories
3. Inflation view
4. Learning features: goals, reflection prompt, what-if comparison, compare the markets
5. Monthly statements and basic / detailed modes

**Version 2**

- Rule of 72 calculator
- Weekly recap
- Automatic market news cards (market headlines plus a short AI summary on big-move days; a small API cost, likely pennies a month)
- **Mom's admin login**, once phase 1's bugs are worked out, including the parent-only "Got it" marker on the wish lists
- **Give jar:** a fourth option for money set aside for a charity or cause she chooses, with a small match from Dad
- **Borrowing from the Bank of Dad:** borrow toward a wish-list item and pay it back with interest, so she feels interest working against her
- **Cancel a waiting request:** a kid can cancel her own deposit, withdrawal or trade while it's still waiting, which releases any hold. (In version 1, Buy / Sell lists her waiting requests read-only.)

**Version 3 (ideas)**

- A "family market day" review screen
- Push notifications for GIC maturities and approvals (on Android, these work once the app is installed from Chrome)

## Testing and launch gates

The acceptance checklist is `docs/ACCEPTANCE.md`. Dad's beta test plan (setup, week-by-week script, bug log) lives outside the repo.

## Build decisions

These settle details the sections above leave open. Where they differ from an earlier section, this section wins.

### Time and dates

- All dates are in Alberta time. "Today" comes from `app_today()` and "now" from `app_now()`.
- **Alberta's time rule is pinned in the database.** Alberta's Official Time Act (2026) keeps the province on UTC−6 all year from November 1, 2026. The database works this out with its own rule (`edmonton_local()` and `edmonton_at()`) rather than each server's time-zone data, which may be out of date; the browser uses the same rule. `check_time_rules()` confirms a server agrees.
- **If Alberta's time rule ever changes again:** write a new migration that replaces the pinned rule (`edmonton_local()` and `edmonton_at()`), update the time machine's reference model and the browser's `albertaDate()` to match, then run the tests and `npm run timemachine` before deploying.
- **Market closes are set in Toronto time** (4:00 pm, or 1:00 pm on an early close) and converted to Alberta time, never hard-coded in Alberta time. In Alberta a close is 2:00 pm (early: 11:00 am) from the second Sunday in March to the first Sunday in November, and 3:00 pm (early: 12:00 pm) the rest of the year.
- **The nightly run is at 4:30 pm Alberta time, all year**, at least 90 minutes after the latest close.
- In local development, a `clock_override` setting moves the clock for the time machine. Production ignores it.

### Interest

- **Savings:** every day accrues the end-of-day savings balance (including money held by pending requests) × that day's savings rate ÷ the number of days in that calendar year (365 or 366). Accruals are stored as fractional cents (`interest_accruals`, one row per account per day). On the 1st, the previous month's total is posted as one "Interest paid" transaction, rounded up to the cent.
- **GICs:** simple interest by term: principal × locked rate × term months ÷ 12, rounded up to the cent, posted at maturity. This makes $100 at 5% for 1 year exactly $105.00 and $100 at 2.5% for 1 month $0.21 (0.2083, rounded up). A broken GIC pays $0.
- **Maturity date** = start date plus the term in calendar months, same day of the month, moved back to the month's last day when needed (Jan 31 + 1 month = Feb 28, or Feb 29 in a leap year). Weekends and holidays don't move it.
- **At maturity**, the whole matured amount (principal + interest) follows her choice. Renewing buys a new GIC with all of it at the current rate, which is how compounding shows up.
- **"How was this calculated?"** shows the matching working: for savings, the month's daily accruals summed ("Your balance earned $0.0137 a day for 30 days = $0.41, rounded up to $0.42"); for a GIC, "$100.00 × 5.0% × 12/12 = $5.00".

### Moves, requests and holds

- **Every move goes through savings:** savings → GIC, savings → fund, GIC → savings, fund → savings. Fund → GIC takes two steps. This keeps the rules simple and matches "money lands in savings".
- **Deposits** hold nothing (the money isn't in yet) but count toward the cap while pending: net deposits (approved deposits − approved withdrawals) + pending deposits + the new amount must not exceed the cap.
- **Withdrawals** hold the amount in savings; Dad can approve only 24 hours after the request.
- **Deposits and withdrawals** expire 7 days after the request if Dad hasn't answered, releasing any hold, with a notice.
- **GIC purchases and early breaks** happen immediately (they're auto-approved moves). Dad is notified on the dashboard.
- **Stock buys** hold the dollar amount in savings until settlement. **Stock sells** are by dollar amount or "sell all" and hold the units until settlement.
- **One trade per fund per calendar day**, buy or sell, counting pending and settled trades.

### Stock funds

- **Unit price** = the proxy ETF's daily close (DIA, QQQ, XIC), used as a number in Canadian dollars. Only the percentage change matters, so there's no exchange-rate effect.
- **Settlement:** a trade settles at the first close of that fund's market that comes after the request. US and Canadian markets both close at 4:00 pm Toronto time: 2:00 pm in Alberta from March to early November, and 3:00 pm the rest of the year.
- **Buys:** units = amount ÷ close, rounded up at 8 decimal places. **Sells:** proceeds = units × close, rounded up to the cent, into savings. "Sell all" sells every unit.
- **Cost basis** uses average cost. "Since first purchase" return = (current value − cost of the units she holds) ÷ that cost. The 1M, 3M and 6M returns = change in her holding's value over the window, excluding money moved in or out (a simple Modified Dietz calculation is fine).
- **Market holidays:** a `market_holidays` table, seeded from the official NYSE and TSX calendars for 2026–2028. The parent dashboard warns 60 days before the table runs out. A missing close on a trading day is retried, never filled in.
- **Splits:** when the price provider reports a split, post a zero-dollar `split_adjust` entry that scales her units, so her holding's value doesn't change.
- **Dividends:** on the first business day of January, April, July and October, for each fund she holds: units held at the previous quarter's last close × that close × the fund's yearly yield ÷ 4, rounded up to the cent, into savings.
- **Standard market-move note:** when a fund's close moves more than 2% from the previous close, show the standard note. Dad can edit the text of any note.

### Rates and settings

- `rates` rows: vehicle, GIC term, rate, effective date, optional end date, `is_special`, note. The rate on a given date is the latest regular rate effective on or before it, unless a special covers that date.
- A GIC locks the rate in force on the day it's bought, a special included.
- **Settings** keys include `deposit_cap_cents` (100000), `inflation_rate` (2.0), `clock_override` (local only), `launched_at`, and feature switches named `feature:<name>`, each `off`, `test` (test accounts only) or `everyone`.
- Rates and settings are append-only like the ledger: a change is a new dated row.

### Writes, security and logins

- **All writes go through Postgres functions** that check the caller and the rules. Kids can SELECT only their own rows; they have no direct INSERT, UPDATE or DELETE on any table.
- **Parent-only data** lives in its own tables, for example `wishlist_parent_marks` for the "Got it" marker, because RLS can hide rows but not columns.
- **Kid login:** an Edge Function `kid-login` takes a username and 6-digit PIN, checks `login_attempts` (5 failures in a row lock the account for 15 minutes and alert Dad), then signs in to Supabase Auth using the hidden email for that username. Public sign-up is turned off; accounts are created by a setup script.
- **Parent login:** email, a strong password and an authenticator-app code (Supabase Auth MFA). Parent functions require `aal2`.
- **Pre-launch reset:** a function `prelaunch_reset()`, callable only by the database owner from the SQL editor, wipes the beta's test history after taking a backup, keeps configuration (rates, settings, glossary, holidays, fund prices), and refuses to run once `launched_at` is set.

### Reliability and alerts

- **Posting keys:** every automatic posting carries a unique `posting_key`, so retries and catch-up runs can't double-post.
- **Catch-up:** each job records the last date it completed in `job_runs` and processes every missed date in order.
- **Reconciliation invariants,** checked nightly for every account: approved deposits − approved withdrawals + interest + dividends + realised and unrealised gains − penalties = total worth; no balance or unit count is negative; held money never exceeds what's held against; every active GIC has a matching purchase entry; no duplicate posting keys. A failure marks that account's figures "Updating…" in the kid app and raises an alert.
- **Alerts** go to an `alerts` table shown on the parent dashboard. Email comes free from GitHub: a daily GitHub Actions health check calls `health_check()` and fails when there's any open problem, and GitHub emails Dad about the failed run. No separate email service.
- **Test accounts** are reconciled like any other, but their problems are logged quietly, never alerted, and they're left out of the liability total.

### Data model additions

These tables and fields add to the Data model section:

| Table or field | Purpose |
|---|---|
| `transactions.posting_key`, `.note`, `.reverses_id` | Duplicate protection, plain-language notes, and links from corrections to what they fix |
| `transactions.type` adds `split_adjust` and `correction` | Splits and openly posted fixes |
| `rates.end_date`, `rates.is_special` | Limited-time specials |
| `interest_accruals` | Daily savings accrual per account, in fractional cents |
| `market_holidays` | Closed days per market (NYSE, TSX) |
| `login_attempts` | Failed PINs and lockouts |
| `alerts` | Problems for Dad: failed jobs, missing prices, mismatches, backup failures, lockouts |
| `wishlist_parent_marks` | Parent-only "Got it" marker |
| `notifications.type` adds `cap_change`, `request_expired`, `badge`, `whats_new` | More notice types |
