# Big Bucks — Progress log

Claude Code updates this file at the end of every stage. Newest stage at the top.

## Status

- Current stage: stage 7 part 1 (Home) done, and the Alberta time-zone fix done, both local only. **Next: stage 7 part 2.**
- Build order (changed 2026-10-03, screens first): stages 6 → 7 → 8 against the local database only, then 4 → 5 (live setup), then the solo beta. Deploy, phone install and real accounts move to after stage 4. Phase 1 is complete when stage 5 is done. See "Build order" in `docs/BUILD-PLAN.md`.
- **The girls' devices:** a Samsung Galaxy A17 phone and Samsung Galaxy tablets, all Android with Chrome. Every layout must work on both the phone and the tablets (portrait and landscape), and every stage checks both.
- Phase 1 complete: no
- Solo beta started: no
- Launched: no

## Stage log

<!-- For each stage, add:
### Stage N — <name> (<date>)
- Built:
- Tests: <counts, pass/fail>
- ACCEPTANCE.md boxes now testable:
- Known issues:
- Dad to do by hand:
-->

### Alberta time-zone fix, local only (2026-10-03)

- **Why:** Alberta stays on UTC−6 all year from November 1, 2026 (Official Time Act). The local Postgres still has the old rule and would turn Alberta to UTC−7 on Nov 1. Production's may do the same. Details are under stage 7 part 1 below.
- **Decisions Dad made:**
  1. The glossary and spec wording for the market close (below).
  2. The nightly run moves to **4:30 pm Alberta time, all year**. That's 90 minutes after the latest close (3:00 pm in winter).
  3. SPEC "Build decisions" now says: if Alberta's rule ever changes again, write a new migration to the pinned rule, then do a time machine run.
- **Built:**
  - **`20261006000000_alberta_time.sql`** (new; no committed migration was edited):
    - **The pinned rule:** `edmonton_local(moment)` and `edmonton_at(clock time)`. From 2026‑03‑08 09:00 UTC on, Alberta is UTC−6, worked out with plain arithmetic. Earlier moments use the server's history.
    - **Recreated functions:** `app_now`, `app_today`, `edmonton_start`, `fmt_moment`, `request_trade`, `send_rate_notices`, `run_daily`, `fund_return`, `reconcile_account` and `my_activity`, copied from their latest versions. Only the time-zone conversion changed.
    - **Closes stay in Toronto time:** 4:00 pm, or the early-close time. In Alberta a close is now **2:00 pm** (early: 11:00 am) from the second Sunday in March to the first Sunday in November, and **3:00 pm** (early: 12:00 pm) the rest of the year. Messages such as "settles Nov 2 at 3:00 pm" follow automatically.
    - **Glossary "Market close":** "The end of the stock market's day, at 4:00 pm in Toronto. In Alberta that's 2:00 pm from March to early November, and 3:00 pm the rest of the year. …"
    - **`check_time_rules()`:** the production check (see "Dad to do by hand"). It gives 20 known answers plus one information-only row about the server's own time-zone data. Only the database owner can run it.
  - **Browser:** the notices list no longer uses the phone's time-zone data. `albertaDate()` in `src/lib/format.ts` applies the same pinned rule.
  - **Time machine:**
    - **The reference model** now has its own Toronto clock-change rule and Alberta's UTC−6. Closes are the Toronto close converted, written separately from the database code.
    - **4:30 pm run:** the run happens at `NIGHTLY_RUN` = 4:30 pm. `jobs:local` and the demo now use 4:30 pm too.
    - **New scenario trades:** at 2:30 pm on the weekdays either side of Nov 7, 2027 and Mar 12, 2028.
    - **Early closes:** these settle at 12:00 pm in winter.
    - **Moved to 5:00 pm:** steps that must come after the nightly run.
  - **Docs:**
    - SPEC: nightly job, settlement, day-count and Build decisions (time and dates).
    - GLOSSARY.md.
    - BUILD-PLAN: stage 4's cron window, the new check step and the stage 7 wording.
    - ACCEPTANCE: two new boxes.
- **Tests:**
  - `supabase test db`: **634 of 634 passed**.
    - **New `alberta_time_test.sql`** (45):
      - the pinned rule either side of Nov 1, 2026 and the 2026 history;
      - the clock override across Nov 1;
      - closes on both sides of each Toronto clock change;
      - 2:30 pm settlement in summer and winter;
      - one trade per fund per Alberta day at midnight in winter;
      - activity dates at New Year;
      - `check_time_rules()`;
      - a guard that fails if any other function or view names `America/Edmonton`.
    - **Changed known answers:**
      - Winter noon is 18:00 UTC.
      - Winter closes are an hour later than before (3:00 pm, and 12:00 pm for early closes).
      - The early-close "after" request moved from 11:30 am to 12:30 pm.
      - Tests that run the nightly jobs now set the clock to 4:30 pm.
  - `npm test` (Vitest): **138 of 138 passed**. New tests cover the model's clock rules, its closes either side of each clock change, and `albertaDate()`.
  - `npm run test:e2e` (Playwright): **25 of 25 passed**.
  - `npm run timemachine`: **PASS, 14 of 14**. 75 of 75 actions agreed with the model, including the 4 new trades either side of the clock changes. 367 nightly reconciles found no problems. The report is regenerated in `docs/TIMEMACHINE-REPORT.md`.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:** none can be ticked yet (live). Two new boxes were added: settlement times in summer and winter, and `check_time_rules()` on production.
- **Known issues:**
  - The notices list still reads a timestamp from a table. Stage 7 part 2 should take its dates from the database, like Home does.
  - Toronto times still use the server's `America/Toronto` data. Its rules haven't changed since 2007, and `check_time_rules()` confirms them.
- **Dad to do by hand:**
  - Nothing now.
  - **At stage 4**, right after pushing migrations to production:
    1. In the Supabase Dashboard, open **SQL Editor**.
    2. Run `select * from public.check_time_rules();`.
    3. Every row should show ok = **true**, except the last, information-only row (ok is empty), which only says whether production's own time-zone data is up to date. Any **false** row means stop and tell Claude.

### Stage 7, part 1 — Kid Home and the GIC choice, local only (2026-10-03)

- **The plan Dad approved:** Stage 7 runs in two parts. Part 1 is Home, including the GIC choice flow and the full history page because Home links to both, and then a stop for Dad's review. Part 2 covers everything else.
- **New standing rule in CLAUDE.md** ("Screens and layout"):
  - Every screen, kid or parent, must work from 360 px phones to desktop, portrait and landscape, foldables included, with Android's large text on.
  - Nothing may be cut off or overlap.
  - Each stage tests at small phone, tablet and desktop sizes.
- **Decisions Dad made:**
  1. **Option colours:**
     - Savings is gold `#E0A400` and GICs are pink `#D6336C`. Gold is for fills and bars only, never text on white.
     - Every colour pair must meet contrast rules.
  2. **Funds on Home:** all three funds show, with "You don't own any yet" on the ones she doesn't hold.
  3. **Up and down days:**
     - ▲ or ▼ with words, in calm colours, never red.
     - A down day must be as clear as an up day.
     - The daily change gets a **?** saying markets go up and down and one day doesn't matter much.
  4. **The GIC choice screen** says plainly what happens if she doesn't choose by the date, in the maturity notice's own words.
  5. **After the review:** Home approved with no changes.
- **Built:**
  - **Migration `supabase/migrations/20261005000000_kid_home.sql`.** Read functions; a kid can only ask about her own account, and a parent needs the authenticator code.
    - **`fund_overview(account)`:** each fund's name and colour, her units, value, cost and gain, and the latest and previous closes.
      - **Daily change:** the fund's % change between its two latest closes up to today.
      - **Her mix:** whole percents, using the largest-remainder method, so they always add up to exactly 100.
      - **Sparkline:** the last 30 closes.
    - **`my_activity(account, limit, before)`:** her history, newest first, for Home and "See all".
      - **One line per event:** the two ledger rows of a move are grouped by their shared posting key.
      - **Requests included:** pending, declined (with Dad's reason) and expired requests are listed too.
      - **Dates and paging:** each line carries its Edmonton date (`on_day`), worked out by the database. Paging continues after a given line.
    - **`current_rates()`:** today's savings and GIC rates. A special wins inside its dates, and any announced change shows with its date.
    - **`mark_notices_read(ids)`:**
      - A kid marks only her own notices as read.
      - The first time she read one is kept.
      - Dad can't mark them, because his dashboard shows whether she has read them.
    - **The "Daily change" glossary text** is reworded as Dad asked. `docs/GLOSSARY.md` is updated to match.
  - **Home** (`src/kid/home/`):
    - **Order on the page:** total worth first, then the banner, then the savings, GICs and funds cards, then recent activity.
    - **Banner:** a "Your GIC grew!" card for a waiting GIC, plus the newest unread notice with **Got it**. GIC "ready" notices aren't repeated, because the waiting GIC has its own card.
    - **Savings card:** on hold and free to use (while a request is holding money), today's rate, and any announced change.
    - **GICs card:** each GIC with its locked rate, a progress bar, its ready date and what it earns by then. A matured one shows **Choose**.
    - **Funds card:** the mix bar and legend, and all three funds' last market day with ▲, ▼ or ● and a 30-day sparkline.
    - **Recent activity:** the last 5 lines and **See all**.
    - **"Updating…"** replaces every amount while the nightly check is fixing something.
    - **Layout:** one column on phones and two from 840 px, capped at 1100 px wide. Sizes are in rem so large text scales.
  - **GIC choice** (`/kid/gic/:id`):
    - She chooses **Keep it growing**, **Try a different length** or **Move it to savings**.
    - She sees the deadline and what happens without a choice.
    - A summary comes before **Yes, do it**, including what the new GIC will earn, worked out by the database's `gic_interest_cents`.
    - Then `choose_maturity` runs, and that GIC's maturity notice is marked read.
  - **History** (`/kid/history`): her whole history, 30 lines at a time, with **Show more**.
  - **Colours** (`src/lib/colours.ts`, with the tokens in `theme.css`):
    - Every text and shape pair is checked against WCAG 2.2 AA.
    - Gold and the existing Nasdaq-100 orange are too light to stand out on white (2.2 and 2.97 : 1), so every coloured shape gets a dark outline (`--bb-outline`).
    - GIC pink text uses `#B8255A`, because `#D6336C` falls just short on the page background.
    - Up `#15693D` and down `#6A4C9C` are equally strong, both about 6.7 : 1.
    - The total-worth panel's gradient fades to a deeper purple, so the gold tagline keeps its contrast.
  - **Display formats** (`src/lib/format.ts`):
    - Rates, dates and GIC terms match the database's own formats exactly: "2.5%", "Oct 7", "1-year".
    - The browser never converts times into dates; every date comes from the database.
  - **The ? on purple:** a light version (`<Explain light>`).
  - **Demo:**
    - The demo kids have read their notices from more than 3 days ago, so the banner looks realistic.
    - The second rate-cut note no longer repeats the engine's own tip.
  - **Tests:**
    - Test files are type-checked with Node's types (`tsconfig.test.json`); the app itself is not.
    - The end-to-end tests now run in two Playwright projects. The `layout` project runs first, while Robin's GIC is still waiting for her choice, and the rest run after it.
  - **Wording:** all new kid-facing wording is in **`docs/MESSAGES.md` §7**.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **589 of 589 passed**, in 15 files, after `supabase db reset`. That's the 547 earlier tests plus 42 new ones in `kid_home_test.sql`:
    - each fund's units, value, daily change, mix (57 / 32 / 11 from 56.47 / 32.40 / 11.13) and sparkline;
    - a kid with no funds still sees all three funds;
    - only closes up to today count;
    - history lines with their amounts, terms, rates, units and prices, and paging with nothing repeated or missed;
    - isolation: kid B and a parent without the code are refused;
    - rates with a special and an announced change;
    - marking notices read, own notices only;
    - grants;
    - the glossary text.
  - `npm test` (Vitest): **126 of 126 passed**. New: contrast for every colour pair, plus the stylesheet scan for gold text; display formats; history wording.
  - `npm run test:e2e` (Playwright): **25 of 25 passed**.
    - **New in `home.spec.ts`:**
      - Home matches the database to the cent;
      - **Got it** marks a notice read;
      - **See all**;
      - renewing Robin's GIC from start to finish, with the deadline wording, the summary and the database result.
    - **New in `layout.spec.ts`:** Home, history and the GIC choice are checked at 360×780, 412×915 (Galaxy A17), 673×841 (unfolded foldable), 800×1280 and 1280×800 (tablet), and 1440×900 (desktop), each with normal and 130% text.
      - It fails if the page scrolls sideways, anything sticks out or is cut off, side-by-side items overlap, or a button is under 44 px.
      - It saves 36 full-page screenshots to `test-results/layout/`.
  - `npm run timemachine`: **PASS, 14 of 14**. `npm run lint` is clean, and `npm run build` succeeds.
- **Next task, before part 2: the Alberta time-zone change.**
  - **What changed:** Alberta's Official Time Act (passed June 18, 2026) keeps the province on UTC−6 all year from **November 1, 2026**; clocks no longer go back. IANA time-zone data 2026c (July 8, 2026) changed `America/Edmonton` to match.
  - **Found by:** the new date tests. Node (tzdata 2026c) already shows Edmonton as UTC−6 in winter, but the local Postgres (17.11) still switches to UTC−7 on Nov 1, 2026. Production's Postgres may lag the same way.
  - **What would go wrong from Nov 1:**
    - `app_today()` and `app_now()` would start Edmonton's day an hour off.
    - The 4:00 pm Eastern market close is 3:00 pm Alberta time in winter, not 2:00 pm, which affects the "settles at the 2 pm close" wording and the nightly schedule (3:30 pm) for stage 4.
    - The time machine's independent model assumes the old clock changes.
    - The browser and the database could disagree about which day a time falls on.
  - **Already safe:** settlement times are worked out in Eastern time, so which close a trade settles at is still right. Home takes every date from the database.
  - **Recommended fix** (a short task of its own):
    1. Pin the app's own time rule in the database rather than trusting each server's time-zone data.
    2. Update the reference model and the clock tests, and add known-answer tests across Nov 1, 2026.
    3. Review every message that says "2 pm", and stage 4's cron window.
    4. Re-run the time machine.
- **Left for part 2:**
  1. **Graphs:** total worth over time (stacked area) and growth by option, with 1M / 3M / 1Y / All, a $ / % switch, dots for deposits and withdrawals, and the market-move notes. Recharts is added here.
  2. **Buy / Sell:**
     - from and to choices, always through savings;
     - the amount, with the available balance and cap room;
     - every spec warning: the early-break loss in dollars, a fund worth less than she paid, over the available balance, one trade per fund per day, and when it settles;
     - a confirmation summary.
  3. **Transparency:** "How was this calculated?" on interest, dividend and penalty lines (the working is already in each line's note), and "Something looks wrong?" on any line, starting a question thread.
  4. **The notices list:** reading marks them read.
  5. **Accessibility pass** across all kid screens.
  6. **Playwright tests:** a deposit request, buying a GIC, the early-break warning, a trade request and sending a question. The layout test gets extended to the new screens.
  7. **PROGRESS.md** with the full stage 7 entry and the ACCEPTANCE.md boxes.
- **Known issues and notes:**
  - **Full-page screenshots** show the fixed bottom tabs part-way down the page. That's how such captures work; on a device the tabs stay at the bottom.
  - **Fund names** for history lines are also listed in `activityText.ts` (`FUND_NAMES`). They match the `funds` table; if a fund is ever renamed, change both.
  - **The end-to-end tests reload the demo** (new PINs). Run `npm run demo` for a clean set afterwards.
- **Dad to do by hand:** nothing. Optional: review the new wording in **`docs/MESSAGES.md` §7**.

### Stage 6 — Logins, the installable app and the app shell, local only (2026-10-03)

- **Decisions Dad made:**
  1. **Build order is now screens first:** stages 6 → 7 → 8 run against the local database only, then 4 → 5, then the solo beta. Recorded in `docs/BUILD-PLAN.md` ("Build order") and the status above. Deploying, installing on the phone and creating real accounts all move to after stage 4.
  2. **Demo kids:** Robin is a regular account and Sky is a test account (`is_test`), like the time machine. So the parent dashboard shows both the liability total and the test-accounts list.
  3. **The end-to-end tests may reload the demo,** but Claude says so each time, because it signs you out and changes the demo PINs.
  4. **`npm run jobs:local`** was added: synthetic closes, then the nightly job and reconcile, for today.
  5. **The kid login remembers the last username on the device,** with a "Not you?" link to switch.
- **Built:**
  - **Migration `supabase/migrations/20261004000000_logins.sql`.** Four functions, all server only (service role). They're not callable from the app.
    - **`create_kid_account(user, username, display name, is_test)`:** creates her account and profile.
    - **`create_parent_profile(user, username, display name)`:** creates the parent's profile.
    - **`login_precheck(username)`:** says whether it's a kid, gives her hidden email, and reports any lock.
    - **`record_login_attempt(username, succeeded)`:** records the try and applies the lockout.
    - **The lockout:**
      - 5 wrong PINs in a row lock the username for 15 minutes.
      - A right PIN resets the count, and so does the end of a lock.
      - While locked, nothing is checked or recorded, even a right PIN.
      - Each lock raises one `lockout` alert. It fails the health check, so GitHub will email you once stage 4's check runs. A test account's alert is quiet.
      - Unknown usernames and the parent's username lock the same way. Usernames ignore capitals and spaces and are cut to 40 characters.
  - **`supabase/config.toml` (local settings):**
    - public sign-up is off;
    - authenticator-app MFA (TOTP) is on;
    - `kid-login` runs without a signed-in user;
    - the local sign-in rate limit is raised to 300 per 5 minutes, because every kid login shares the function's address.
    - The email provider must stay on: in Supabase, its "sign-up" switch also turns off email logins. Production gets the same settings in stage 4's runbook.
  - **Edge Function `supabase/functions/kid-login`:**
    1. Checks the username and lock (`login_precheck`).
    2. Tries the PIN as her Supabase password.
    3. Records the try (`record_login_attempt`).
    4. Returns a normal Supabase session.
    - A wrong PIN, an unknown username and the parent's username all get the same answer. An Auth outage isn't counted against her.
  - **The app** (one new dependency, `@supabase/supabase-js`):
    - **Kid login** (`src/pages/KidLogin.tsx`):
      - Asks for her username once, then shows a big PIN pad with 76 px keys. It submits by itself at the 6th digit.
      - Remembers her username and name on the device (never the PIN), so she sees "Hi, Robin!" and only enters her PIN. "Not you?" forgets it.
      - Kind messages; the wording is in `docs/MESSAGES.md` §6.
    - **Parent login:**
      - Email and password, then the authenticator code.
      - The first sign-in sets the authenticator up: a QR code, a typeable key, then a code to confirm.
    - **Route guards** (`src/App.tsx`):
      - Parent screens need a parent with the code done (aal2).
      - A kid session is always sent back to her Home, even from the parent login page.
      - A parent without the code is sent to the code step.
    - **Kid shell:**
      - Bottom tabs Home, Graphs and Buy / Sell, plus Wish List only when `feature:wishlist` is on for her. The demo turns it on for test accounts, so Sky sees it and Robin doesn't.
      - A notifications bell with the unread count, and a read-only notices list.
      - **Home** shows her total worth, with the **?** and "Updating…". The other screens are placeholders for stage 7.
    - **Shared pieces:**
      - **`<Explain term>`:** the **?** button and card, reading the glossary from the database.
      - **`<Updating>`:** the "Updating…" state.
      - **The "You're offline" screen:** shown whenever the phone is offline, and data is never cached.
      - **`formatCents()`:** in `src/lib/money.ts`, using whole-number maths only. It refuses fractions and unsafe numbers.
    - **Parent shell:** its own header and tabs. The Dashboard lists each kid's total worth, with test accounts marked. Settings is a placeholder for stage 8.
    - **PWA:** the manifest already had the name, theme colour #5B3FD1 and icons (maskable included). A test now checks it.
  - **Local-only scripts** (`scripts/local/`). All refuse anything but the local Supabase: the API must be `127.0.0.1:54321`, plus the time machine's database guard.
    - **`npm run demo`:**
      - Resets the local database.
      - Creates "Dad", Robin and Sky with real logins. The PINs and the password are random on every run.
      - Walks 92 days ending yesterday evening, with the time machine's price generator and clock. Every action goes through the real kid and parent functions, with `run_daily` and `reconcile` each day at 3:30 pm. It stops on any reconcile problem or alert.
      - Clears the clock override, sets up the parent's authenticator, writes `.env.local`, and prints the logins. They're also saved to `.demo-logins.local`, which is gitignored.
      - **The demo history includes:**
        - deposits approved, one declined with a reason, and a withdrawal approved after 24 hours;
        - a GIC renewed, then moved to savings;
        - a 1-month GIC that matured 2 days ago and is waiting for Robin's choice;
        - 6-month GICs;
        - buys in all three funds, a partial sale and a sell-all;
        - monthly interest, and dividends on Oct 1;
        - a savings-rate cut, plus another announced for next week;
        - a question Dad answered;
        - a pending deposit, and a pending withdrawal from last night with its 24-hour wait running.
    - **`npm run demo:code`:** prints the demo parent's current authenticator code.
    - **`npm run jobs:local`:** tonight's run by hand. It adds synthetic closes, then runs `run_daily` and reconcile, through today after 3:30 pm Edmonton time or through yesterday before then.
    - **`npm run setup-account`:** asks for the role, display name and username, then a hidden PIN typed twice (or email and password for a parent), and whether it's a test account. Nothing is written to the repo.
    - **`npm run env:local`:** points the app at the local Supabase.
    - The demo and `jobs:local` share the nightly step (`scripts/local/nightly.ts`). The time machine itself is unchanged.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **547 of 547 passed**, in 14 files, after `supabase db reset`. That's the 502 earlier tests plus 45 new ones in `logins_test.sql`:
    - who may call the four functions;
    - creating accounts, with duplicates and bad usernames refused;
    - the lookup;
    - the lockout to the minute: 4 failures don't lock; the 5th does; the right PIN is refused while locked and nothing is recorded; 15 minutes later it unlocks and the count starts again; a success resets the count;
    - the alert wording, and a quiet alert for a test kid;
    - unknown and parent usernames;
    - odd input.
  - **Mutation check:** I changed the lockout to 6 tries in the live local database. 12 tests failed. Then I rebuilt the database from empty.
  - `npm test` (Vitest): **58 of 58 passed**:
    - `formatCents` (22);
    - authenticator codes against the RFC 6238 test vectors (9);
    - the local-only guard and synthetic closes (10);
    - the 17 reference-model tests. The old placeholder-screen test went with the placeholder screen.
  - `npm run test:e2e` (Playwright, Pixel 7, production build against the local Supabase): **15 of 15 passed**, twice in a row:
    - **App:**
      - a signed-out visit starts at the kid login;
      - deep links work;
      - the offline screen appears and goes away;
      - the manifest is installable.
    - **Kids:**
      - Robin signs in and sees Home, the tabs, the bell and the **?**;
      - Sky sees the Wish List tab;
      - the remembered username, and "Not you?";
      - a wrong PIN gets a kind message;
      - **5 wrong PINs lock**, even for the right PIN;
      - **a kid can't reach `/parent`, `/parent/settings`, `/parent/mfa` or `/parent/login`**;
      - the PIN door refuses the parent's username;
      - signing out on one device leaves her other devices signed in.
    - **Parents:**
      - **a new parent's first-time authenticator setup** (a wrong code refused, then the dashboard);
      - the demo parent signs in with the code;
      - **a parent without the code is blocked on screen and in the database:** `liability_total` and `approve_request` are refused (403), and accounts and alerts come back empty.
  - `npm run timemachine`: **PASS, 14 of 14**.
  - `npm run lint` is clean, and `npm run build` succeeds.
  - **Safety:** `npm run demo` and `npm run jobs:local` pointed at a hosted Supabase address both refused before touching anything.
- **ACCEPTANCE.md boxes now testable:**
  - **Proven locally, and live once stage 4 sets up production:**
    - "Each girl logs in with her username and PIN".
    - "Five wrong PINs lock the login for 15 minutes and alert Dad". The alert is in `alerts` and fails `health_check()`. The email itself comes with stage 4's GitHub check.
    - "Dad's login requires the second factor".
  - **"Security tests pass…":** now also proven through real logins (the kid and no-code parent tests above).
- **Known issues and notes for later stages:**
  - **Stage 4 (production):**
    - **Auth settings, in the runbook:**
      - turn off "Allow new users to sign up";
      - keep the Email provider on;
      - turn on TOTP MFA;
      - deploy `kid-login` with `--no-verify-jwt`;
      - review the sign-in rate limit (300 is a local-only value).
    - **Then:** deploy to GitHub Pages with the production URL and anon key; widen `npm run setup-account`'s guard to production on purpose; install on your phone; create the real accounts.
  - **Stage 7:**
    - The notices list is read-only, so marking notices as read still needs its small kid function.
    - Home, Graphs and Buy / Sell are placeholders.
    - `useKidSummary` already loads total worth, "Updating…", the Wish List switch and the unread count.
  - **Stage 8:**
    - The dashboard placeholder lists each kid's total worth.
    - Lockout alerts (kind `lockout`) need to appear in the alert list with an Acknowledge button.
  - **The end-to-end tests add two throwaway logins:**
    - "Lockout Test", a test kid;
    - "New Parent", a parent with no data of its own.
    - Run `npm run demo` for a clean set.
  - **The database tests expect an empty database** (as in stage 3). After the demo, run `npm run db:reset` before `npm run test:db`.
  - **The parent and a kid share one sign-in per browser.** On one computer, use a normal Chrome window for a kid and an Incognito window for the parent. On the phones this won't matter: the kid uses Chrome and you use another browser, as planned.
  - **The guard's refusal message** says "the time machine only runs against the local database" even when it comes from the demo, because they share the guard.
- **After the first review (Dad's changes):**
  - **`npm run dev` listens on `127.0.0.1`**, port 5173, and `vite preview` on `127.0.0.1:4173` (`vite.config.ts`). On Dad's computer Chrome forces https for "localhost" (HSTS), so the app is opened at **http://127.0.0.1:5173/Big-Bucks/**. Playwright uses `127.0.0.1` too.
  - **The girls' devices** (now in the status at the top): a Samsung Galaxy A17 phone and Samsung Galaxy tablets.
    - **Stage 7 onwards:** each screen must be checked at phone size and at tablet size in both orientations.
    - **The Stage 6 shell:** it already stretches to any width. On a tablet, the bottom tabs span the full width and the cards fill the screen.
    - **Stage 7:** it should cap the content width (or use two columns) on tablets, and add tablet sizes to the Playwright projects.
  - **Sign-out now affects this device only.** The full test run found it: Supabase's sign-out ends every session by default, so a girl signing out on her tablet would also have been signed out on her phone. A new test covers it.
- **Dad to do by hand:** nothing required. Optional: review the new wording in **`docs/MESSAGES.md` §6**.
- **Try it in Chrome at phone size:**
  1. Make sure Docker Desktop is running. If the local Supabase isn't up, run `npm run db:start`.
  2. Run `npm run demo` if you need fresh logins. It prints them, and they're also saved in `.demo-logins.local`, which isn't committed.
  3. Run `npm run dev`, then open **http://127.0.0.1:5173/Big-Bucks/** in Chrome.
  4. Press **F12**, then **Ctrl+Shift+M** (device toolbar). In the **Dimensions** menu, choose **Pixel 7**, or add the Galaxy sizes with **Edit…**.
  5. **As a kid:** type `demo_robin`, tap **Next**, then tap her PIN. Try the **?** and the bell, then **Sign out**: next time it's "Hi, Robin!" with the PIN pad only.
  6. **As the test kid:** tap **Not you?** and sign in as `demo_sky`. She also has the **Wish List** tab.
  7. **As the parent:** open an Incognito window (**Ctrl+Shift+N**), turn on the device toolbar again, and go to **http://127.0.0.1:5173/Big-Bucks/parent/login**. Sign in with `parent@demo.example` and the demo password. For the code, run `npm run demo:code`.
  8. **Optional:** to try the first-time authenticator setup, run `npm run setup-account`, choose **parent**, then sign in with that email and scan the QR code with your phone.

### Stage 3 — Time machine and nightly reconciliation (2026-10-02)

- **Decisions Dad made:**
  1. **At the plan:**
     - Dividends are paid on the first trading day of each fund's own market. In Jan 2028 that's Jan 3 for the Dow and Nasdaq-100, and Jan 4 for the TSX.
     - `pg` (the standard Postgres client) is added as a dev dependency.
     - "Updating…" clears by itself once a later check finds the account clean. The alert stays open until Dad acknowledges it.
     - The time machine resets the local database.
  2. **After the first run:** a sale by dollar amount **rounds its units down** at 8 decimal places. She gets exactly what she asked for and keeps the sliver of a unit.
     - The spec didn't say how to round them. The independent model guessed "up" and disagreed with the database by 1 cent on 4 sales. That's exactly the kind of thing it's there to find.
     - The database already rounded down, so no migration was needed. The model now follows Dad's rule.
  3. **New rule in CLAUDE.md:** any change that touches money logic must also pass `npm run timemachine` before the stage is called done.
- **Built:**
  - **`supabase/migrations/20261003000000_reconcile.sql`:**
    - **`reconcile(date)`** (server only) re-checks every account from the raw ledger as of the end of that date. It records its run in `job_runs` (`reconcile`). Its checks:
      - Nothing is negative: savings, each GIC, each fund's units.
      - **Every ledger line is explained by its rule, with the right amount.** Each is worked out again here:
        - Deposits and withdrawals match approved requests.
        - Monthly interest = that month's accruals, rounded up.
        - GIC interest = principal × rate × term ÷ 12, rounded up, on the maturity date. A broken GIC posts none.
        - Dividends = units × close × yield ÷ 4, rounded up, on the right day.
        - Trades settle at their own close: buys get units rounded up at 8 places, and sales get proceeds rounded up.
        - Splits scale units by the split ratio.
        - GIC buys, breaks, moves to savings and renewals are balanced pairs carrying the right amount.
        - Penalties are flagged, because the engine never charges one.
      - **Total worth = deposits − withdrawals + interest + dividends + corrections − penalties + realised gains + unrealised gains.** Realised gains are worked out from each sale.
      - What the app shows matches a fresh count: `daily_balances` for that day, and for today also `account_balances`, `fund_positions` and `gic_positions`.
      - Held money ≤ savings; held units ≤ units; each pending request holds the right amount.
      - Every GIC has a purchase line for its principal, and today its balance matches its status. None is past maturity without maturing.
      - Every day's accrual exists and equals (end-of-day savings + waiting GIC money) × rate ÷ 365/366. Every finished month's interest was paid.
      - No posting key is used twice.
      - **Corrections:** a line reversed by a correction counts as never having happened in the accrual check. Otherwise a fix dated today would leave every day since the mistake flagged forever.
    - **Alerts:**
      - One alert (kind `mismatch`) per account per kind of problem, never repeated while it's open.
      - Test accounts' alerts are quiet (`is_quiet`).
      - Each message says what's wrong in plain words, with up to 3 examples in `details`.
    - **`figures_updating(account)`:** true while the latest check found a problem with that account, so the app shows "Updating…". A kid may ask only about herself, and an empty account id is refused.
    - **`acknowledge_alert(id)`:** parent with MFA only.
    - **`health_check()`** (server only) reports:
      - open alerts that aren't quiet;
      - any daily job not finished through yesterday (interest through the day before);
      - no reconcile for yesterday.
    - **Grants:** `reconcile` and `health_check` to the server; `figures_updating` to signed-in users; `acknowledge_alert` to signed-in users (the MFA check is inside). The helper functions get no grant.
  - **`scripts/timemachine/`** (`npm run timemachine`):
    - `db.ts`: the local connection. It **refuses** any address but `127.0.0.1:54322`, any hosted Supabase address, and any database whose `is_local_dev` isn't `true`. Each app call runs as the real role (kid, parent with MFA, or server) with the same sign-in claims Supabase Auth would give, so permissions are exercised too.
    - `prices.ts`: repeatable synthetic closes, whole-number arithmetic, on each market's real trading days. It includes:
      - the Nasdaq-100 falling about 25% from Feb 14 to Mar 6, 2028 (−4% on Feb 24), then recovering;
      - smaller drops for the Dow and TSX;
      - a 2-for-1 Nasdaq-100 split on Nov 15, 2027;
      - the Sep 14, 2027 Nasdaq-100 close arriving a day late.
    - `scenario.ts`: the scripted year, Jul 1, 2027 to Jul 1, 2028. Every step says why it's there; the full list is at the bottom of `docs/TIMEMACHINE-REPORT.md`.
    - `model/`: **the independent reference model**, in exact whole-number fractions (no floating point, no library).
      - It was written from SPEC.md and these decisions **before** I read the Stage 2 job code. It shares input data (closes, holidays, the script) but no logic.
      - It works out settlement times (holidays, early closes, real elapsed time across the clock changes), maturity dates, accruals, dividends and rounding itself.
      - It has its own Vitest known-answer tests from the spec.
    - `run.ts` walks the year:
      - Each day: the scripted actions, then at 3:30 pm the closes, `run_daily` and `reconcile`.
      - It compares everything with the model, injects the faults, writes the report, and resets the local database at the end. Add `-- --keep` to keep the simulated year in the database for inspection.
  - **`docs/TIMEMACHINE-REPORT.md`:** the plain-English summary of the latest run, regenerated each time.
  - **CI (Dad's request at commit time):** `.github/workflows/ci.yml` has a second job, `timemachine`.
    - It runs after the `test` job passes (lint, unit tests, build, pgTAP), on every push and pull request.
    - It starts a throwaway local Supabase in the runner and runs `npm run timemachine`.
    - It uploads `TIMEMACHINE-REPORT.md` as a run artifact, even when the run fails.
    - A money bug therefore fails CI, and deploy (which needs a green CI) won't go.
  - **Smaller changes:**
    - `tsconfig.scripts.json` type-checks the scripts (part of `npm run build`).
    - Vitest now also runs `scripts/**/*.test.ts`.
- **Tests (all run locally on 2026-10-02):**
  - `npm run test:db` (pgTAP): **502 of 502 passed**, in 13 files, after `supabase db reset`. That's the 450 earlier tests plus 52 new ones in `reconcile_test.sql`:
    - a clean month passes;
    - each kind of fault is caught;
    - test accounts are logged quietly and don't fail the health check;
    - "Updating…" turns on, then clears after a correction while the alert stays open;
    - acknowledging needs a parent with MFA;
    - no duplicate alerts;
    - the health check spots jobs falling behind;
    - who may call what.
  - `npm run timemachine`: **PASS, 14 of 14 checks**, in 92 seconds:
    - **Shown figures (nearest cent) every day:** 359 days × 2 kids. Savings, held, available, each GIC, each fund's units (to 8 places) and value, total worth, net deposits and cap room all match the model.
    - **Posted amounts (rounded up):** all 91 ledger events match the model exactly. That includes 24 savings interest, 7 GIC interest, 16 dividend, 13 buy, 5 sell, 3 renewal, 4 GIC-to-savings, 1 break and 2 split postings.
    - **Accruals and graphs:** 732 kid-days of accruals, each within one ten-billionth of a cent, with every 2028 day ÷366. 732 kid-days of graph history match.
    - **Actions:** all 71 were accepted or refused the same way by both, and all 9 planned outcomes happened:
      - refusals: a second same-day trade, a withdrawal under 24 hours old, a late approval, a GIC under $10, a deposit over the lowered cap;
      - two expiries, one of them across the November clock change;
      - the health check failing during the missed week and clear after the catch-up.
    - **Nightly checks:** 367 reconcile runs with no problems and no alerts. Only the late-close day had to wait.
    - **Deliberate faults**, each in a transaction that's undone (a throwaway copy):
      - an extra interest posting;
      - a trade with the wrong units;
      - a GIC with no purchase line.

      Each was caught, with "Updating…" on, and kid B's alert was quiet. The corrected fault cleared "Updating…" while its alert stayed open for Dad, and nothing was left behind afterwards.
    - **Final balances:**
      - Kid A: $1,296.41 from $1,270.00 put in. Savings interest $9.14, GIC interest $5.42, dividends $1.97, fund gains $9.88.
      - Kid B: $1,201.90 from $1,180.00 put in. Savings interest $8.59, GIC interest $0.13, dividends $5.70, fund gains $7.48.
  - **Safety guard:** `TIMEMACHINE_DB_URL` pointing at a hosted Supabase address, or at the wrong local port, is refused before connecting.
  - `npm test` (Vitest): **18 of 18 passed**: the placeholder test plus 17 reference-model tests. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds (type-checking the scripts too).
- **ACCEPTANCE.md boxes now testable:**
  - **Passing now:**
    - "The time machine runs a simulated year (rate changes, maturities, dividends, a crash, a missed week) with every balance correct".
    - "A quarterly dividend posts correctly", in the time machine.
  - **Ready for stage 4:** "30 nights in a row with zero reconciliation mismatches" (needs the nightly job in production).
- **Known issues and notes for later stages:**
  - **Stage 4:**
    - **Nightly order:** fetch prices → `run_daily(today)` → `reconcile(d)` for every date since the last reconcile, as the time machine does after the missed week.
    - The GitHub check calls `health_check()` with the service role key and fails when `ok` is false.
    - `run_daily` returning `waiting` or `failed` still needs its own alert (as noted in stage 2). Today it shows up only through `health_check`'s "behind" report the next morning.
  - **Stage 7:** the kid screens call `figures_updating(her account)` and show "Updating…" in place of her figures while it's true.
  - **Stage 8:**
    - The dashboard lists open `alerts`. Quiet ones go in a separate "test accounts" list. Each gets an Acknowledge button that calls `acknowledge_alert`.
    - **Corrections:** reconcile treats a correction with `reverses_id` as fully cancelling the line it reverses. If the engine ever posted a wrong line that interest was later accrued on, those accrual rows stay flagged even after the line is corrected, because accruals are append-only. Dad acknowledges the alert, but "Updating…" would stay on. If that ever happens, it needs a small follow-up: a way to mark a past accrual as corrected.
  - **Holds are checked only as they stand today:** requests change status, so a past day's holds can't be rebuilt.
  - **Fund cost (average cost) isn't compared with the model.** It isn't money owed: it only feeds "gain since first purchase". The model checks every amount that is money owed or shown as a balance.
  - **The time machine resets the local database at the start and the end**, so any local test data is wiped. Use `npm run timemachine -- --keep` to keep the simulated year for inspection, then `npm run db:reset` before running the database tests: the earlier tests expect an empty database.
  - **No new kid-facing wording:** "Updating…" itself is screen text for stage 7, and the alert messages are parent-only. So `docs/MESSAGES.md` is unchanged.
- **Dad to do by hand:** nothing for this stage. Optional: run `npm run timemachine` yourself (Docker Desktop must be running) and read `docs/TIMEMACHINE-REPORT.md`.

### Stage 2 — The money engine (2026-10-02)

- **Decisions Dad made at the plan:**
  1. A matured GIC waiting for her choice **earns the savings rate** until she chooses or the day-7 auto-move.
  2. A sell by dollar amount that needs more units than she has (the price fell) **sells all her units**, with a note.
  3. A withdrawal under $5 is allowed **only when it empties savings**.
  4. Requests expire **exactly 7 × 24 hours** after they're made.
  5. Dividend yields are **dated settings** (`dividend_yield:dow` …), so yield changes keep their history. The `funds.dividend_yield` column is gone.
  6. `.env.example` stays committable.
- **Built:** seven migrations, all applying cleanly to an empty database.
  - **`…070000_engine_schema.sql`:**
    - `transactions.effective_at`: when the money counts. `posted_at` stays the real time the row was written. They differ only for automatic postings: a trade written at 3:30 pm counts from the 2:00 pm close, and a catch-up run on Nov 10 for Nov 5 counts from Nov 5. So a late run gives exactly the on-time answer.
    - `interest_accruals.gic_waiting_cents`, for decision 1.
    - The `fund_splits` table.
    - `notes.auto_key` and `notifications.dedupe_key`, so automatic notes and notices are never written twice.
    - New job names and the `question` notice type.
    - Yields moved to settings.
    - The two standard market-move notes (rise and drop) as editable settings.
  - **`…080000_engine_core.sql`:**
    - Rounding (units to 8 places), GIC interest, and "interest earned so far" for the break warning.
    - Formatting ($1,234.56, 2.0%, "Nov 1").
    - `rate_on` (a special wins inside its dates) and `setting_on`.
    - Market days and closes from `market_holidays`, in Eastern time, so early closes are 11:00 am Edmonton.
    - Balance helpers and the notice writer.
  - **`…090000_kid_actions.sql`:** `request_deposit`, `request_withdrawal`, `buy_gic`, `break_gic`, `choose_maturity`, `request_trade` and `ask_question`. Each locks her account, checks the rules (minimums, available balance, the cap including pending deposits, one trade per fund per Edmonton day, every move through savings) and writes, in one transaction.
  - **`…100000_parent_actions.sql`:** `approve_request`, `decline_request`, `answer_question`, `add_rate` and `set_setting`, all aal2 only.
    - **`approve_request`:** withdrawals only after 24 hours, and nothing after the 7 days.
    - **`decline_request`:** a reason is required.
    - **`add_rate`:** the effective date defaults to 7 days out and can't be in the past. Specials have an end date. More than 3 decimal places is refused rather than silently rounded.
    - **`set_setting`:** an allowed-keys list. It always refuses `is_local_dev` and `clock_override`, and `launched_at` can be set only once.
  - **`…110000_daily_jobs.sql`:**
    - **The jobs, each idempotent:** `expire_requests`, `apply_split`, `settle_trades`, `mature_gics`, `auto_move_unclaimed_maturities`, `pay_quarterly_dividends`, `post_monthly_interest`, `write_market_move_notes`, `send_rate_notices` and `accrue_savings_interest`.
    - **`run_daily(date)`:** runs them in that order for every date not yet done, recording each in `job_runs`.
    - **A job that's waiting or fails stops the run at that date,** so nothing is processed out of order. The next run starts there. The market-move notes are the exception: they never hold anything up.
    - **A day's savings interest is accrued once that day is over,** in the next day's run. A 3:30 pm run can't know about an 8 pm GIC purchase.
  - **`…120000_reads.sql`:**
    - Views, run with the caller's permissions: `account_balances`, `fund_positions` and `gic_positions`.
    - Functions: `daily_balances(account, from, to)`, `fund_return(account, fund, from)` (Modified Dietz), `liability_total()` (parent or server only, test accounts excluded) and `next_settlement(fund)` for the Buy / Sell screen.
  - **`…130000_function_grants.sql`:** every function's permissions in one list. Postgres lets everyone run a new function by default, and Stage 1's per-schema default couldn't stop that, so this migration revokes everything and grants exactly:
    - kid actions and reads to signed-in users;
    - parent actions to signed-in users, with the aal2 check inside;
    - jobs to the service role only.
  - **`.gitignore`:** now also ignores `*.env`, `**/.env*`, and every `.txt` file outside `docs/`. `.env.example` stays allowed. Checked with sample files.
- **Tests (all run locally on 2026-10-02, after `supabase db reset` from empty):**
  - `npm run test:db` (pgTAP): **450 of 450 passed**, in 12 files. That's the 170 earlier tests plus 280 new ones:
    - `engine_interest_gic_test.sql` (51):
      - $250 at 2% for 30 days posts $0.42, with its working.
      - Old rate before a change, new rate from its effective date.
      - A day in 2028 accrues ÷366.
      - $100 at 5% for 1 year = $105.00, and $100 at 2.5% for 1 month = $0.21.
      - Locked rate after a cut.
      - Renewal carries principal + interest.
      - **Waiting GIC money earns the savings rate,** both when she renews and through the day-7 auto-move, with no gap and nothing counted twice.
      - A broken GIC pays $0 and returns the principal, and the warning shows $0.20.
      - Jan 31 + 1 month = Feb 28, 2027 and Feb 29, 2028.
    - `engine_trades_test.sql` (76):
      - Friday evening settles Monday. Good Friday. Exactly at the close waits.
      - **Early closes:**
        - NYSE, Nov 27, 2026: a 10:30 am request settles at the 11:00 am close; one at 11:30 am settles Mon Nov 30.
        - TSX, Christmas Eve: a 10:00 am request settles at 11:00 am; one at noon skips Dec 25 and 28 to Dec 29.
      - $100 at 420 = 0.23809524 units. Sale proceeds and dividends round up.
      - **Values shown round to the nearest cent:** the $100 buy shows $100.00 on her holding, total worth and graphs right after settling, and at a close of 430 it shows $102.38 while selling would pay $102.39.
      - One trade per fund per day. Held money isn't available.
      - A missing close waits and never uses another day's price.
      - A split keeps the value. Partial sells and average cost. The price-fall sell-all (decision 2).
      - Market-move notes over 2%.
    - `engine_requests_test.sql` (48):
      - The cap counts pending deposits.
      - Declines keep the reason.
      - Withdrawals can't be approved before 24 hours.
      - The $5 rule (decision 3).
      - Expiry to the minute, releasing the hold, with one notice each.
      - Dad can't approve after 7 days.
      - Questions and answers.
      - Lowering the cap takes nothing away.
    - `engine_rates_settings_test.sql` (41): rate and special notices on save, on the day and at the end; specials apply only between their dates; settings validation, including refusing `is_local_dev` and `clock_override`; cap-change notices.
    - `engine_jobs_test.sql` (26): the first run, a missed week caught up in one run, running again posts nothing, every job re-run for every date posts nothing, and a missing close holds the run without skipping ahead.
    - `engine_security_reads_test.sql` (38): kids can't call parent functions or jobs; a parent without MFA is refused; kid A can't touch kid B's GIC, ledger lines or balances; the views and functions return the right figures; the liability total leaves out test accounts; and the safety net covers every new view and function.
  - **Updated Stage 1 tests,** because the schema changed on purpose:
    - `schema_test`: `fund_splits` and the `question` notice type.
    - `reference_data_test`: yields are now settings, so there's 1 more test.
    - `rls_test`: the "account-scoped tables" check now looks at tables only, not views.
  - **Mutation check:** I broke three money rules in the live local database. The tests caught all three (16 failures), and then I rebuilt the database from empty:
    - GIC interest rounded to nearest instead of up;
    - early closes ignored;
    - waiting GIC money dropped from interest.
  - `npm test` (Vitest): 1 of 1 passed. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:**
  - **Passing now:** "All known-answer tests pass (interest, GIC maturity, broken GIC, trade units, rounding up)".
  - **Proven at the database level; the live check comes once the screens (stages 6–8) and the nightly jobs (stage 4) exist:**
    - A deposit request holds the money and Dad approves it.
    - A declined request shows the reason.
    - Expiry after 7 days releases the hold.
    - The cap blocks deposits with a clear message.
    - The 24-hour withdrawal wait.
    - Cashing out goes through savings.
    - Savings interest posts on the 1st, with its working.
    - A 1-month GIC matures right, and the money moves to savings after 7 days.
    - Breaking a GIC early.
    - Next-close settlement (Friday → Monday).
    - One trade per fund per day.
    - Partial sells.
    - The note for a move over 2%.
    - Quarterly dividends.
    - A rate change notice with the 7-day default.
    - Locked GIC rates.
    - A special switching back.
    - The cap-change notice.
    - A skipped night caught up with no duplicates.
    - A missing price makes trades wait.
    - A question and Dad's reply.
- **Known issues and notes for later stages:**
  - **How the ledger keeps fund cost:** a fund row's `amount_cents` is cost, not value. A buy adds what she paid, and a sale removes the average cost of the units sold. So the fund rows add up to the cost of the units she holds, and a sale's savings row (the proceeds) minus its fund row (the cost) is the realised gain.
    - **Stage 3 reconciliation invariant:** total worth = the sum of every ledger row + (fund value − fund cost).
    - Renewals move money GIC → GIC with no savings rows. That's two balanced rows linked by `renewed_from_id`.
  - **Two kinds of rounding (Dad's change after the first review):**
    - Money actually posted rounds up to the cent: sale proceeds, interest and dividends.
    - Values only shown round to the nearest cent: fund holding values, total worth, the graphs and the liability total (`fund_positions`, `account_balances`, `daily_balances`, `fund_value_at`). So a $100 buy shows $100.00 right after settling, not $100.01.
    - **Stage 3:** reconcile must use the same nearest-cent fund value as the screens, so a selling price that's a fraction of a cent higher isn't reported as a mismatch.
  - **Stage 3:** the time machine should call `run_daily`, which the clock override already drives.
    - A missing TSX close leaves that day's market-move notes "retrying", so each run starts from that date again. That's harmless, but the reconcile report shouldn't flag it.
  - **Stage 4:**
    - `fund_splits` and `fund_prices` have no write function yet. The price job needs one, run by the service role and added to the grants list.
    - Alert when `run_daily` returns `waiting` or `failed`. Its result lists the date, job and reason.
    - The first `run_daily` starts from the earliest account's opening date.
  - **Every later stage:** add each new function to a grants list like `…130000_function_grants.sql`. The safety-net tests fail otherwise.
  - **Stage 7:** marking notices as read needs a small kid function, which isn't built yet. `next_settlement(fund)` gives the "settles at Monday's 2 pm close" time.
  - **Stage 8:** "recent auto-approved moves" are the requests of type `move`.
  - **All kid-facing wording is a draft for you to review:** **`docs/MESSAGES.md`** lists every message the girls can see from the money engine, grouped by where it appears:
    - notices;
    - errors on Buy / Sell and requests;
    - "How was this calculated?" lines;
    - notes on history lines;
    - market-move notes.

    Changing parts are shown as `{placeholders}`. Like `docs/GLOSSARY.md`, it's a review copy, regenerated from the migrations after each change. Later stages add their messages to it.
- **Dad to do by hand:**
  1. Review the wording in **`docs/MESSAGES.md`**. **Your wording edits will come back as a new migration** that replaces the affected functions. The Stage 2 migrations stay as they are once committed, because other copies of the database will have run them. After that migration, `docs/MESSAGES.md` is regenerated so the two always match.

### Stage 1 — Database and security (2026-10-02)

- **Built:** six migrations in `supabase/migrations/`, all applying cleanly to an empty database.
  - **`20261002010000_core_tables.sql`:**
    - **Tables:** every table in the Data model plus the Build decisions additions (22 tables with `settings`), with enums, foreign keys, NOT NULL and check constraints. Money is `bigint` cents, units `numeric(20,8)`, accruals `numeric`. Rates and yields are percent per year (`5.000` = 5%).
    - **Signed ledger:** + adds to a vehicle, − takes away. Checks pin the sign per type: a deposit > 0, a withdrawal < 0, a `split_adjust` moves $0, a correction needs a note, and only a correction may set `reverses_id`.
    - **GIC maturity date:** a check enforces the rule (start + term months, moved back to the month's end).
    - **Requests:** checks enforce "every move goes through savings".
    - **Clock:** timestamps default to `app_now()` and dates to `app_today()`, so the time machine moves them.
  - **`…_append_only.sql`:** `transactions`, `rates` and `interest_accruals` reject UPDATE, DELETE and TRUNCATE for every role, the owner included. `interest_accruals` wasn't in the spec's list; it's protected because it's the working behind every interest line.
  - **`…_helpers.sql`:**
    - **`my_account_id()`:** the signed-in kid's account.
    - **`is_parent()`:** true only for a parent signed in **with MFA (aal2)**. A parent with a password alone sees only their own profile.
    - **`feature_enabled(feature, account_id)`:** `off` / `test` / `everyone`, using the newest `feature:<name>` row effective today. A missing or unknown value counts as off, and a kid may ask only about her own account.
  - **`…_rls.sql`:** RLS on every table, with read policies only. Write grants are revoked from `anon`, `authenticated` and `service_role`, and default privileges are changed so **future tables and functions start with no grants** (each later stage must grant on purpose).
    - Kids read only their own rows. They read the shared reference tables, notes with audience `kids`, and every setting except `is_local_dev` and `clock_override`.
    - Parent-only: `wishlist_parent_marks`, `alerts`, `login_attempts` and `job_runs`.
  - **`…_reference_data.sql`:** in a migration, not `seed.sql`, so production gets it too.
    - **Funds:** dow/DIA 1.8%, nasdaq100/QQQ 0.6% and tsx/XIC 2.8%, with colours #2F80ED blue, #F76B15 orange and #0B6E69 teal (TSX was red at first; changed because red reads as "losing money"). The teal differs from the other two in both hue and lightness.
    - **Rates:** the starting rates, effective 2026-01-01.
    - **Settings:** cap 100000 cents and inflation 2.0.
    - **Glossary:** 52 kid-friendly terms. **This wording is a draft for you to review.**
  - **`…_market_holidays.sql`:**
    - **NYSE 2026–2028:** from the official page, all confirmed. Nasdaq follows the same calendar.
    - **TSX 2026:** confirmed.
    - **TSX 2027 and 2028:** the TSX publishes only 2025–2026, so **both** years are calculated from the usual rules and marked `confirmed = false`. You asked for this treatment for 2028; 2027 turned out to be in the same position.
    - **Early closes:** included too (`kind = early_close`, `closes_at` 1:00 pm Eastern), because a trade can't settle at 2:00 pm Edmonton on those days.
    - Source URLs are in the migration's header comment.
  - **Spec details settled in the plan:**
    - `wishlist_items.parent_got_it` is replaced by `wishlist_parent_marks`.
    - Kids don't insert `requests` directly; Build decisions overrides the Data model here.
    - Added the `expired` request status, `requests.held_units` / `sell_all` / `gic_id`, `funds.market`, and `gic_holdings.renewed_from_id` / `rate_id`.
- **Tests (all run locally on 2026-10-02, after `supabase db reset` from empty):**
  - `npm run test:db` (pgTAP): **169 of 169 passed**, in 6 files:
    - `clock_test.sql`: 26 tests.
    - `schema_test.sql`: 44 tests. Tables, money types, no floats, ledger signs, posting-key duplicates refused, GIC maturity dates including Jan 31 → Feb 28 / Feb 29, and request shapes.
    - `append_only_test.sql`: 17 tests.
    - `helpers_test.sql`: 20 tests.
    - `rls_test.sql`: 45 tests.
      - Kid A sees none of kid B's rows in any table, and kid B, a test account, sees none of kid A's.
      - Kids, the parent, anonymous callers and the service role are each refused INSERT, UPDATE, DELETE and TRUNCATE on every table.
      - Kids can't see the parent-only tables.
      - The parent with MFA reads every row of every table.
      - **Safety-net checks on every table and function:** RLS is on, there are no write grants (including column grants), anonymous callers can't read or execute anything, every SECURITY DEFINER function has a fixed `search_path`, and every view runs with the caller's permissions.
    - `reference_data_test.sql`: 17 tests.
  - **Mutation check:** I injected a leaky policy, a stray write grant and a table with RLS off into a throwaway copy of the security test. It caught all three (7 failures).
  - `npm test` (Vitest): 1 of 1 passed. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:**
  - **"Security tests pass: one girl can't see or change the other's data, and no one can edit history":** testable at the database level, and passing. It's fully proven once stage 6 adds real logins.
  - **"Cashing out of a GIC or fund requires moving it to savings first":** partly. The schema refuses withdrawals from anything but savings, and refuses moves that skip savings. The screens come in stage 7.
- **Known issues and notes for later stages:**
  - **Stage 2:**
    - Every new function needs explicit `grant execute` (kids: kid functions only). Every new view needs `security_invoker = true`. The safety-net tests fail otherwise.
    - The parent's settings function must still refuse `is_local_dev` and `clock_override` (from stage 0).
    - `funds.dividend_yield` is an ordinary column, not dated history. If you want yield changes to keep their history like rates do, decide that in stage 2.
  - **Stage 4: the holiday warning must treat unconfirmed years as missing.** The parent-dashboard warning ("60 days before the table runs out") must count a market's year as covered only when its rows have `confirmed = true`. TSX 2027 and 2028 are unconfirmed now, so the warning should remind you to check them against https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar once the TSX publishes them. Confirming a year means adding the published dates and marking them confirmed, in a new migration. Add a pgTAP test that an unconfirmed year triggers the warning.
  - **Stage 5:** the append-only triggers stop TRUNCATE for every role, so `prelaunch_reset()` will have to disable them briefly as the database owner, inside its own transaction.
  - **Stage 6:** public sign-up is still on in `supabase/config.toml` (`enable_signup = true`). Turn it off when logins are built.
- **Dad to do by hand:**
  1. Review the glossary wording in **`docs/GLOSSARY.md`**, a readable export of all 52 terms from the database. **Your wording edits will come back as a new migration** that updates the glossary. The Stage 1 migration stays as it is, because it's committed and other copies of the database have already run it. After that migration, `docs/GLOSSARY.md` is regenerated from the database so the two always match.
### Stage 0 — Foundations and price-data research (2026-10-02)

- **Built:**
  - **App:** React 19 + TypeScript + Vite 8 app with React Router, `vite-plugin-pwa` (manifest uses the icons in `public/icons/`), ESLint, Prettier, Vitest and Playwright. The placeholder home screen shows the icon, "Big Bucks" and "Watch your bucks grow." in Fredoka (bundled with `@fontsource/fredoka`) on brand purple.
  - **GitHub Pages setup:** the base path is `/Big-Bucks/`, set in `vite.config.ts`. It matches the repo name and is case-sensitive. Each build copies `index.html` to `404.html` so deep links work on GitHub Pages.
  - **Supabase:** the CLI is installed as a dev dependency (`npx supabase ...`, v2.119), and the project was set up with `supabase init` (`project_id = "big-bucks"`).
  - **First migration, `supabase/migrations/20261002000000_settings_and_clock.sql`:**
    - **`settings` table:** append-only. Triggers reject UPDATE, DELETE and TRUNCATE for every role. RLS is on with no policies yet. Direct writes are revoked from `anon`, `authenticated` and `service_role`.
    - **Default row:** the migration inserts `is_local_dev = 'false'`.
    - **`reject_append_only_change()`:** a trigger function that stage 1 can reuse on `transactions` and `rates`.
    - **`app_now()`:** honours `clock_override` only when the newest `is_local_dev` row is `'true'`. The override freezes the clock at an Edmonton date and time (`YYYY-MM-DD HH:MI`, or a date alone for midnight). An empty value clears it, and a malformed value raises an error.
    - **`app_today()`:** the Edmonton date of `app_now()`.
  - **`supabase/seed.sql`** (local only) sets `is_local_dev = 'true'`. Production never runs the seed, because `supabase db push` doesn't run seeds.
  - **npm scripts:** `dev`, `build`, `preview`, `test`, `test:db`, `test:e2e`, `lint` (ESLint + Prettier check), `format`, `db:start`, `db:stop`, `db:reset`.
  - **GitHub Actions:**
    - `.github/workflows/ci.yml` runs on every push and pull request: lint, unit tests, type-check and build, then `supabase db start` and the pgTAP tests in the runner.
    - `.github/workflows/deploy.yml` is **manual for now**. Even when started by hand, it deploys only from `main`, and only after checking that CI passed for that exact commit. See "Switching deploy to automatic" below.
- **Tests (all run locally on 2026-10-02):**
  - `npm test` (Vitest): 1 of 1 passed.
  - `npm run test:db` (pgTAP): 26 of 26 passed. The database was rebuilt from empty with `supabase db reset` first, and the CI steps were rehearsed locally (`supabase db start` from a clean stop, then the tests).
  - `npm run test:e2e` (Playwright, emulated Pixel 7 against the production build): 2 of 2 passed. This runs locally only for now, not in CI, as agreed.
  - `npm run lint` is clean, and `npm run build` succeeds.
  - **CI on GitHub:** run #1 passed on 2026-10-02 for commit `fde86ea`, every step green: https://github.com/JarrettWD/Big-Bucks/actions/runs/37092337236
- **What the clock tests prove:**
  - The migration's default is false, and the seed sets it to true.
  - With no override, the clock is real time.
  - An override freezes `app_now()` and sets `app_today()`.
  - Daylight saving is handled: noon in Edmonton is 18:00 UTC in July and 19:00 UTC in December.
  - At 11:30 pm on Dec 31, `app_today()` is still Dec 31 in Edmonton, even though it's Jan 1 in UTC.
  - The newest row wins regardless of `effective_date`.
  - A bad value raises an error, and an empty value clears the override.
  - With `is_local_dev` false, the override is ignored.
  - UPDATE, DELETE and TRUNCATE are rejected.
  - Signed-in and anonymous callers can't insert directly.
- **ACCEPTANCE.md boxes now testable:** none fully yet. This stage is groundwork for the time machine (line 12).
- **Known issues:**
  - The `effective_date` default on `settings` is `app_today()`, which in local dev follows the time machine. That's intended.
  - The Playwright browser (Chromium) must be installed once on any new computer: `npx playwright install chromium`.
- **Notes for stage 1:**
  - `is_local_dev` and `clock_override` always use the **newest row** (highest `id`), whatever its `effective_date`. Every other key uses the normal rule: the newest row effective on or before the date.
  - The parent's settings function **must refuse to change `is_local_dev` or `clock_override`**, so the time machine can never be switched on in production through the app. Add a pgTAP test for that refusal.
  - Stage 1 adds RLS read policies on `settings` (no kid needs the environment keys) and the reusable trigger on `transactions` and `rates`.

#### Switching deploy to automatic

Do this once you've decided between a public repo and GitHub Pro, and Pages is turned on.

1. Open `.github/workflows/deploy.yml`.
2. Under `on:`, delete the `#` at the start of the four `workflow_run` lines, so the block reads:
   ```yaml
   on:
     workflow_dispatch:
     workflow_run:
       workflows: [CI]
       types: [completed]
       branches: [main]
   ```
3. Commit and push. From then on, every push to `main` runs CI first. Deploy starts only when CI finishes **successfully** for that commit, and it deploys exactly that commit. Keep `workflow_dispatch` if you want to redeploy by hand.

#### Price-data research (checked 2026-10-02 on each provider's own pages; nothing signed up for)

What we need:
- One raw daily close a day for DIA, QQQ and XIC, where XIC is listed on the TSX.
- Split events, for the `split_adjust` entries.
- At least a year of history for the backfill.
- Terms that allow a private, non-commercial family app to show the prices to the girls.

| Provider | Free-tier limits | XIC (TSX) on free plan? | Daily history on free plan | Splits on free plan | Terms for our use |
|---|---|---|---|---|---|
| **Alpha Vantage** | 25 requests/day | **Yes.** TSX is documented as `SYMBOL.TRT`, so XIC would be `XIC.TRT` (not yet confirmed with a real key) | **Only the latest 100 days** (`outputsize=full` is premium). Weekly closes have 25+ years and are free | Yes: the `SPLITS` endpoint isn't marked premium. (Split-adjusted daily data is premium, but we want raw closes plus split events anyway) | Personal, non-commercial use allowed. "Commercial" means business use or a commercial activity giving others access, so a private family app looks fine |
| **EODHD** | 20 calls/day (+500 one-time bonus) | **Yes:** the free plan's end-of-day prices cover stocks and ETFs globally | 1 year | 1 year, but only "activated on request via support" | **Problem:** the personal terms forbid "displaying" the data to anyone else or sharing access, which the kids' screens would do |
| **Finnhub** | 60 calls/min | **No:** international (TSX) data is paid only | **None:** OHLC history is paid only (the All-In-One plan, US$3,500/mo) | — | Personal use |
| **Twelve Data** | 8 credits/min, 800/day | **No:** the free Basic plan covers only US equities and ETFs, forex and crypto. TSX needs a paid plan (US$29–99/mo) | Not stated | Yes (reference data) | Personal, non-commercial use allowed |
| **Tiingo** | 50 requests/hr, 1,000/day, 500 symbols/mo | **No:** its ticker list (checked) has DIA and QQQ but no TSX listings | 30+ years | Yes (`splitFactor` in each daily row) | Personal use only, "without displaying or sharing data with others" |
| **Stooq** | — | **No:** its symbol search says XIC.CA doesn't exist, and TSX isn't among its exchanges | — | — | Unusable for automation: the CSV download now sits behind a browser check meant to block scripts, and we won't get around that |

Yahoo Finance wasn't evaluated: it has no official API.

**Recommendation**

| Need | Recommended | Why |
|---|---|---|
| Nightly closes for DIA, QQQ, XIC | **Alpha Vantage, free key** | The only free plan that covers XIC and whose terms fit a private family app. We need about 3–6 calls a day, well under 25, which leaves room for retries |
| Split events | **Alpha Vantage `SPLITS`** (one call per fund, e.g. weekly) | Free. Raw closes plus split events match the spec's `split_adjust` design |
| Backfill (a year or two) | **Decide at stage 4.** My recommendation is option A | The free daily series stops at 100 days. See the options below |

Backfill options, for your decision at stage 4:
- **A. Free (recommended):** the last 100 days from the daily series, plus older history from the free weekly series (25+ years), marked as weekly. Graphs and what-ifs look right, and no trade ever settles on a backfilled price. The open question is whether the data model needs a column marking those rows as weekly.
- **B. One month of Alpha Vantage premium** (US$49.99, then cancel). It gives full daily history in one go.
- **C. EODHD free** (1 year daily). This isn't recommended because its terms forbid showing the data to others.

Caveats:
- XIC's coverage and data quality on Alpha Vantage can't be confirmed without a key. The first thing to check at stage 4 is one `TIME_SERIES_DAILY` call for `XIC.TRT`.
- Free plans change. Recheck the limits when you sign up.

- **Dad to do by hand:** see the numbered list at the end of this stage's chat summary. It's repeated here:
  1. **Decide public repo vs GitHub Pro.** Pages from a private repo needs a paid plan.
  2. **Turn on GitHub Pages:** on GitHub, open the repo **JarrettWD/Big-Bucks** → **Settings** → **Pages**. Under **Build and deployment** → **Source**, choose **GitHub Actions**. No branch to pick.
  3. **First deploy (manual):** go to **Actions** → **Deploy to GitHub Pages** → **Run workflow** → branch **main** → **Run workflow**. It refuses if CI hasn't passed for that commit yet. The site will be at `https://jarrettwd.github.io/Big-Bucks/`.
  4. **When ready, switch deploy to automatic** (steps above).
  5. **Price data:** create a free Alpha Vantage key at alphavantage.co → **Get Free API Key**. Don't paste it into the chat or the repo. At stage 4 you'll store it as a Supabase secret.
