# Big Bucks — Build plan

Thirteen stages: phase 1 (the core, stages 0–8) and phase 2 (the fun layer, stages 9–12). Run one stage per Claude Code session: copy the stage's prompt, paste it in, approve the plan Claude Code proposes, and let it work. Every stage ends with passing tests and an updated `docs/PROGRESS.md`.

The money engine comes before any screens on purpose: the screens only display what the database calculates, so the maths is proven first.

### Build order (changed 2026-10-03: screens first)

Stages 0–3 are done. The rest of phase 1 now runs in this order: **6 → 7 → 8 → 4 → 5**, then the solo beta.

- **Stages 6, 7 and 8 run against the local database only.** The kid-login Edge Function runs on the local functions server, and parent MFA uses the local auth. No production project, no deploy, no phone install.
- **What moves out of stages 6–8:** deploying to GitHub Pages, installing the app on your Android phone, and creating real accounts in production. They happen after stage 4, once the production project exists.
- **What they use instead:** `npm run demo` (added in stage 6) resets the local database and loads two made-up test kids and a parent with about 3 months of activity. You try the screens in Chrome on your computer at phone size.
- **Stages 4 and 5** (live setup, then backups) come next, plus the items moved out of stages 6–8: deploy, phone install, and real accounts with the setup script.
- **The solo beta starts after stage 5**, not after stage 8. Phase 1 is complete when stage 5 is done.

Where a prompt below for stages 6–8 says "deploy", "install on my phone" or "production", read it as "locally" and leave that part for after stage 4.

| Stage | What it builds | You'll need | Order |
|---|---|---|---|
| 0 | Project skeleton, local Supabase, CI, price-data research | GitHub repo, Node, Docker, Supabase CLI | 1st (done) |
| 1 | Database tables, security rules, append-only history | — | 2nd (done) |
| 2 | Money engine with known-answer tests | — | 3rd (done) |
| 3 | Time machine and nightly reconciliation | — | 4th (done) |
| 4 | Scheduled jobs, real prices, alerts; first production setup; then deploy, phone install, real accounts | Supabase project, price-data API key, your Android phone | 8th |
| 5 | Backups, Download backup, restore test, pre-launch reset; **phase 1 done, solo beta starts** | Private backup repo | 9th |
| 6 | Logins, PWA install, app shell (local only) | An authenticator app | 5th |
| 7 | Kid screens: Home, Graphs, Buy / Sell (local only) | — | 6th |
| 8 | Parent dashboard, admin settings, onboarding (local only) | — | 7th |
| 9 | Wish List and goals | — | 10th |
| 10 | Theme colours, animal avatars, badges | — | 11th |
| 11 | Inflation view, learning features, statements, view modes | — | 12th |
| 12 | Launch prep: clean reset, real accounts, go-live | — | 13th |

---

## Phase 1: the core

### Stage 0 — Foundations and price-data research

```text
Stage 0 of the Big Bucks build: foundations. Read CLAUDE.md, docs/SPEC.md (Tech stack & automation, and Build decisions) and docs/PROGRESS.md first. Start with a short plan and wait for my OK.

Build:
1. A React + TypeScript + Vite app with vite-plugin-pwa, React Router, ESLint, Prettier, Vitest and a Playwright skeleton. A placeholder home screen showing the Big Bucks icon (public/icons/), name and tagline "Watch your bucks grow." in Fredoka on the brand purple.
2. `supabase init`, a working local Supabase, and the first migration: a `settings` table (append-only, dated rows) and the functions `app_today()` and `app_now()` in America/Edmonton, honouring a `clock_override` setting only when an `is_local_dev` setting is true. `is_local_dev` defaults to false in the migration and is set to true only by `supabase/seed.sql`, which never runs against production. A pgTAP test proves the override works locally and is ignored when `is_local_dev` is false.
3. npm scripts: `dev`, `build`, `test` (Vitest), `test:db` (supabase test db), `test:e2e`, `lint`.
4. GitHub Actions: CI on every push (lint, unit tests, and database tests against a local Supabase started in the runner), and a deploy workflow that builds for GitHub Pages (correct base path) and publishes from main.
5. A price-data research note in docs/PROGRESS.md. Compare free market-data options (for example Alpha Vantage, Finnhub, Twelve Data, Tiingo, Stooq) for daily closes of DIA, QQQ and XIC (TSX-listed): free-tier limits, whether XIC is covered on the free plan, at least 1 year of history for the backfill, split data, and terms for personal, non-commercial use. Check each provider's current pricing pages; don't rely on memory. End with a recommendation table. Don't sign up for anything; I'll create the account.

Done when: `npm run dev` shows the placeholder screen, all tests pass locally and in CI, and the research note is in PROGRESS.md. Then list what I need to do by hand (GitHub Pages settings, the price-data account) and stop.
```

### Stage 1 — Database and security

```text
Stage 1 of the Big Bucks build: the database and its security. Read CLAUDE.md, docs/SPEC.md (Users, accounts & privacy; Data model; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build, as migrations:
1. Every table in the Data model section plus the Build decisions additions, with enums, foreign keys, NOT NULL and check constraints. Money in bigint cents, units numeric(20,8), accruals numeric.
2. Append-only triggers on transactions, rates and settings that reject UPDATE and DELETE for every role, the service role included.
3. Helper functions is_parent(), my_account_id() and feature_enabled(feature, account_id) (off / test / everyone).
4. RLS on every table: a kid selects only her own account's rows; the parent selects everything; nobody writes directly (writes come through functions in later stages). Parent-only tables (wishlist_parent_marks, alerts, login_attempts) are invisible to kids.
5. Seed data with no personal information: the three funds (dow/DIA, nasdaq100/QQQ, tsx/XIC) with colours and yields (0.6% Nasdaq-100, 1.8% Dow, 2.8% TSX); the starting rates (savings 2.0%; GICs 2.5/3.0/4.0/4.5/5.0/6.0% for 1/3/6/9/12/24 months); settings defaults (deposit cap 100000 cents, inflation 2.0%); a starter glossary of kid-friendly explanations for every financial term the app uses (I'll review the wording later); and market_holidays for NYSE and TSX for 2026–2028, taken from the exchanges' official holiday pages, with the source URLs in a comment.
6. pgTAP security tests with two test kids and a parent: kid A can't read any of kid B's rows in any table; kids can't insert, update or delete anything directly; nobody can update or delete ledger, rate or settings rows; kids can't see parent-only tables; the parent can read everything.

Done when every database test passes on a freshly reset local database. Note in PROGRESS.md which ACCEPTANCE.md boxes this makes testable, then stop.
```

### Stage 2 — The money engine

```text
Stage 2 of the Big Bucks build: the money engine. Read CLAUDE.md, docs/SPEC.md (The three vehicles; Rates & rate changes; Money flow; Reliability & fairness safeguards; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK. Write the known-answer tests first, then the functions.

Build, as Postgres functions (SECURITY DEFINER, fixed search_path, caller checks, one transaction each):
1. Kid actions: request_deposit, request_withdrawal, buy_gic, break_gic, choose_maturity (renew / to savings / new term), request_trade (buy or sell by amount, or sell all), ask_question. Each validates minimums ($5 savings, $10 GICs and funds), available balance, the deposit cap, one trade per fund per day, and that moves go through savings.
2. Parent actions (require aal2): approve_request (withdrawals only after 24 hours), decline_request (with a reason), answer_question, add_rate (regular or special, with effective date and note), set_setting.
3. Daily jobs, each taking a date, idempotent through posting_key, and recorded in job_runs with catch-up of missed dates: expire_requests, accrue_savings_interest, post_monthly_interest (on the 1st), mature_gics, auto_move_unclaimed_maturities (after 7 days), settle_trades (given that day's closes), pay_quarterly_dividends, apply_split, write_market_move_notes, and run_daily(date) calling them in the right order.
4. Notifications for approvals, declines, expiries, maturities, rate changes (on save and on the effective date) and cap changes.
5. Read functions and views: savings balance, held and available amounts, GIC holdings, fund holdings (units, value, average cost, returns), total worth, daily_balances for graphs, net deposits and cap room, and the liability total (test accounts excluded).

Known-answer pgTAP tests, at minimum: $100 at 5% for 1 year = $105.00; $100 at 2.5% for 1 month = $0.21; a broken GIC pays $0 and returns the principal; $250 in savings at 2% for 30 days in a non-leap year posts $0.42; a day in 2028 accrues ÷366; Jan 31 + 1 month matures Feb 28 in 2027 and Feb 29 in 2028; buying $100 at a close of 420 gives 0.23809524 units; sale proceeds and dividends round up to the cent; the cap counts pending deposits; a withdrawal can't be approved before 24 hours; an unanswered request expires on day 7 and releases its hold; a second trade in the same fund on the same day is refused; held money isn't available; running any job twice for the same date posts nothing new; a renewed GIC carries principal + interest; a GIC keeps its locked rate after a rate cut; a special applies only between its dates.

Done when all known-answer and security tests pass. Note the newly testable ACCEPTANCE.md boxes in PROGRESS.md, then stop.
```

### Stage 3 — Time machine and nightly reconciliation

```text
Stage 3 of the Big Bucks build: the time machine and reconciliation. Read CLAUDE.md, docs/SPEC.md (Reliability & fairness safeguards; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build:
1. reconcile(date) and health_check(): check every invariant in Build decisions for every account, write problems to alerts (quietly logged for test accounts), and mark an account's figures as "Updating…" while a problem is open. health_check() returns any open problems, for use by the daily GitHub check in stage 4.
2. A local-only time machine, `npm run timemachine`, that refuses to run unless it's pointed at the local database. It creates two test kids and a parent, generates synthetic daily closes for the three funds (including a 25% crash over a few weeks and a recovery), then walks the clock forward one day at a time for a full year calling run_daily: deposits and withdrawals, a GIC ladder, renewals, early breaks, trades, a rate cut with notice, a special, an inverted-curve month, a cap change, quarterly dividends, a leap day, and a missed week where the jobs don't run and then catch up.
3. An independent reference model in TypeScript (decimal arithmetic, not floats) that computes the expected balances from the same scripted events. At the end, the time machine compares every account's database balances with the reference model to the cent, runs reconcile for every day, and prints a clear pass/fail summary.
4. A deliberate-fault check: in a throwaway local copy, inject one wrong posting and confirm reconcile catches it.

Done when the full simulated year passes, the injected fault is caught, and all earlier tests still pass. Then stop.
```

### Stage 4 — Scheduled jobs, real prices and alerts

```text
Stage 4 of the Big Bucks build: scheduled jobs, real fund prices and alerts. This is the first stage that touches production. Read CLAUDE.md, docs/SPEC.md (Tech stack & automation; Build decisions) and docs/PROGRESS.md. Before planning, ask me for: the price provider I chose, and confirmation that I've created the production Supabase project and stored the API key as a Supabase secret. Then plan and wait for my OK.

Build:
1. An Edge Function fetch-prices: for each fund and each trading day since its last stored close (using market_holidays), fetch the close from the chosen provider, retry on failure, record split events, and never fill a gap with a guess. A close still missing at 9 pm Mountain time raises an alert.
2. The nightly orchestration: pg_cron (which runs in UTC) wakes every 30 minutes from 21:00 to 04:30 UTC, covering 3:30–9:30 pm Mountain time in summer and winter. The job does nothing before 3:30 pm Mountain time and never repeats finished work, so it stays correct through daylight-saving changes. Order: fetch prices, then run_daily for every date not yet completed, then reconcile.
3. A one-time backfill of 2 years of closes, so graphs and what-ifs work from day one.
4. A daily GitHub Actions health check that calls health_check() with a secret key and fails when there's an open problem, so GitHub emails me. Include a manual "send test alert" option.
5. docs/RUNBOOK.md with numbered steps for production setup: linking the project, pushing migrations, setting secrets, turning off public sign-ups, turning on MFA, and checking the cron job.

Done when the local run catches up after a skipped day, production has a few days of real closes, and a test alert reaches my email. Then stop.
```

### Stage 5 — Backups and data protection

```text
Stage 5 of the Big Bucks build: backups and data protection. Read CLAUDE.md, docs/SPEC.md (Backups & data protection; Build decisions) and docs/PROGRESS.md. Ask me for the name of the private backup repo I've created, and which operating system my computer runs, then plan and wait for my OK.

Build:
1. A daily GitHub Action that dumps the production schema and data (supabase db dump through the session pooler connection string, kept in GitHub secrets), exports every table as CSV, writes a row-count file, and commits to the private backup repo. It fails on purpose if the export is empty or the ledger has fewer rows than the previous day. The same run makes a normal API request (a tiny ping() function) so the project always has outside activity.
2. A Download backup Edge Function, parent only with MFA, that returns a zip of every table as CSV and JSON, plus the button wiring for stage 8.
3. A sync script for my computer that pulls the backup repo into a cloud-synced folder I choose (Google Drive, OneDrive or iCloud Drive), with step-by-step instructions to schedule it daily on my operating system.
4. A restore script and runbook section: restore the latest dump into the local Supabase, then compare every account's balances with production's latest export and report pass/fail.
5. prelaunch_reset() per Build decisions: database owner only, backup first, wipes test history, keeps configuration, refuses once launched_at is set. Test it locally.

Done when a backup lands in the private repo, a restore test passes locally, and prelaunch_reset is proven locally (including its refusal after launch). Then stop.
```

### Stage 6 — Logins, PWA install and the app shell

```text
Stage 6 of the Big Bucks build: logins, the installable app and the app shell. Read CLAUDE.md, docs/SPEC.md (App layout & screens; Users, accounts & privacy; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build:
1. The kid-login Edge Function: username + 6-digit PIN, lockout after 5 failures in a row for 15 minutes with an alert to me, then a normal Supabase session. A kid login screen that's simple and friendly, with large touch targets.
2. Parent login: email + password + an authenticator-app code (Supabase MFA), with a first-time enrolment flow. Parent screens require aal2.
3. A setup script I run on my computer to create accounts (asks for role, display name, username, PIN, and whether it's a test account). Nothing personal is written to the repo.
4. PWA: manifest (name "Big Bucks", theme colour #5B3FD1, the icons in public/icons including the maskable one), installable from Chrome on Android, and an offline screen that says "You're offline" rather than showing old numbers.
5. The kid shell: bottom tabs Home, Graphs, Buy / Sell and Wish List (Wish List hidden until its feature switch is on), a notifications bell, the brand theme with Fredoka, a reusable "?" explanation component reading the glossary, a money-format helper (cents → $1,234.56, with tests), and the "Updating…" state.
6. The parent shell: its own routes, never reachable from a kid session.
7. Playwright smoke tests: kid login, lockout after 5 wrong PINs, parent blocked without MFA, kid blocked from parent routes.

Done when tests pass, the app deploys to GitHub Pages, and you've given me numbered steps to install it on my Android phone (kid side in Chrome, admin side in Firefox or Samsung Internet) and create two test kids. Then stop.
```

### Stage 7 — Kid screens

```text
Stage 7 of the Big Bucks build: the kid screens for phase 1. Read CLAUDE.md, docs/SPEC.md (App layout & screens; The three vehicles; Money flow; Graphs & dashboards; Reliability & fairness safeguards → Transparency) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build:
1. Home: total worth, savings, each GIC (amount, rate, maturity date), the fund mix with daily % change and 30-day sparklines, the action banner (maturity choices, approvals, declines, notices), recent activity with "See all" history, and the maturity choice flow.
2. Graphs: total worth over time (stacked area, one colour per option) and growth by option (% since first deposit), with 1M / 3M / 1Y / All ranges, a $ / % switch, dots for deposits and withdrawals, and the standard market-move notes.
3. Buy / Sell: from and to choices (always through savings), buy or sell, amount with the available balance and cap room, every warning in the spec (interest lost on an early break, in dollars; a fund worth less than she paid; over the available balance; one trade per fund per day; when the trade will settle, such as "at Monday's 2 pm close"), and a confirmation summary before submitting.
4. Transparency: "How was this calculated?" on every interest, dividend and penalty line, and "Something looks wrong?" on any line, starting a question thread I can answer.
5. The notifications list, marking notices as read.
6. Accessibility: touch targets of at least 44 px, readable contrast, labelled controls, and option colours that differ in lightness, not just hue.

Done when Playwright covers a deposit request, buying a GIC, the early-break warning, a trade request and sending a question, and every test passes. Then stop so I can try it on my phone.
```

### Stage 8 — Parent screens, settings and onboarding (end of phase 1)

```text
Stage 8 of the Big Bucks build: the parent side, admin settings and onboarding. This finishes phase 1. Read CLAUDE.md, docs/SPEC.md (App layout & screens → Admin account and Onboarding; Rates & rate changes; Graphs & dashboards → Parent dashboard; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build:
1. The parent dashboard: each kid's total worth; the liability total (test accounts listed separately and excluded); pending approvals, with a countdown on withdrawals until the 24 hours are up; recent auto-approved moves; upcoming GIC maturities; open alerts; open questions; whether each kid has read each notice; and the holiday-table warning.
2. Admin settings, exactly as the spec describes: one screen of rates (tap, type, save), an effective date defaulting to 7 days out, an optional note, the special toggle with start and end dates, a preview before saving, and the full history. Plus the deposit cap, the inflation rate, feature switches (off / test accounts / everyone), editing market-move notes and glossary wording, and the Download backup button.
3. Onboarding: a short, skippable tour; the account agreement in kid-friendly words, which she signs and I countersign, kept in her history; and her first real decision. Steps for features that are switched off are skipped. A "What's new" tour appears the first time a kid sees a newly switched-on feature.
4. Playwright: approving and declining requests, a rate change with notice reaching a test kid, a special ending on time, a cap change notice, and onboarding end to end.

Done when every test passes, the app is deployed, and PROGRESS.md marks phase 1 complete with the list of ACCEPTANCE.md boxes ready for my solo beta. Then stop.
```

---

## Phase 2: the fun layer

Build these while the solo beta runs. Each feature ships switched to "test accounts only", so you try it on your phone before the girls ever see it.

### Stage 9 — Wish List and goals

```text
Stage 9 of the Big Bucks build: the Wish List tab and goals. Read CLAUDE.md, docs/SPEC.md (App layout & screens → Wish List; Learning features → Goals; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build, behind the feature switch feature:wishlist:
1. The Wish List tab: add an item (name, rough price, optional link and photo, 1–5 stars), reorder, progress toward each item from her total worth ("You're 40% of the way there"), a projected date at current rates, a clear "Mom and Dad can see your wish list" line, and a Done list for removed or received items. Photos are stored in Supabase Storage, readable only by that kid and the parent.
2. Goals: an item can become a savings goal only after 7 days on the list, with a "Still want this?" prompt. A goal shows a progress bar and projected date on Home.
3. The parent view of each wish list, with the parent-only "Got it" marker stored in wishlist_parent_marks and never visible to kids.
4. Tests: the 7-day rule, RLS on items, photos and marks, and a Playwright flow.

Done when tests pass and it's switched on for test accounts only. Then stop.
```

### Stage 10 — Theme colours, avatars and badges

```text
Stage 10 of the Big Bucks build: personalisation and badges. Read CLAUDE.md, docs/SPEC.md (App layout & screens → Look and feel; Reliability & fairness safeguards → Keeping them excited; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build, behind feature:personalisation and feature:badges:
1. Theme colours: a set of about 8 that all keep text readable; the option colours stay fixed.
2. About 16 animal avatars from Microsoft's Fluent Emoji (MIT licence): copy only the files you use into the repo, with the licence and attribution. Add a moose drawn in the Big Bucks style if the set has none. Each avatar sits on a circle in her theme colour and appears on Home, her badges and her questions.
3. Badges that reward decisions, never activity: first GIC, a GIC held to maturity, holding a fund through a 10% drop, a GIC ladder of 3 or more, first dollar of interest, reaching a goal. Evaluate them in the nightly job and on the related events, with a notification. No streaks, no rewards for opening the app or trading.
4. Accessories (party hat, sunglasses, crown, graduation cap) as overlays unlocked by badges, and a picker.
5. Tests for each badge rule, including cases that must not award one.

Done when tests pass and both switches are on for test accounts only. Then stop.
```

### Stage 11 — Learning features, statements and view modes

```text
Stage 11 of the Big Bucks build: the learning features. Read CLAUDE.md, docs/SPEC.md (Learning features; Graphs & dashboards; Build decisions) and docs/PROGRESS.md. Start with a short plan and wait for my OK.

Build, each behind its own feature switch:
1. Inflation view: a toggle on Home and each option showing what her money will really buy, using the inflation-rate setting, in the spirit of the spec's example.
2. What-if comparison: what she'd have today had everything gone into savings, a 1-year GIC or the Nasdaq-100, calculated in the database from her real deposit dates.
3. Compare the markets: the three funds over the same period.
4. Reflection prompt: after a fund sale, ask "Why did you sell?", save it with the request, and show it in her history.
5. Monthly statements: starting balance, deposits, withdrawals, interest and gains, ending balance, matching the ledger exactly.
6. Basic and detailed modes: basic has big numbers and fewer graphs; either kid can switch.
7. Tests: what-if and statements against the reference model from stage 3, plus a Playwright pass in both modes.

Done when tests pass and the switches are on for test accounts only. Then stop.
```

### Stage 12 — Launch prep

```text
Stage 12 of the Big Bucks build: getting ready for the girls' launch. Read CLAUDE.md, docs/SPEC.md (Decisions & phasing → Launch plan), docs/ACCEPTANCE.md and docs/PROGRESS.md. Start with a short plan and wait for my OK.

1. Rehearse prelaunch_reset() on a local copy of production's latest backup and show me exactly what it removes and keeps.
2. Write a launch-day checklist in docs/RUNBOOK.md: confirm every ACCEPTANCE.md box, take a backup, run the reset, set launched_at, create the girls' real accounts with the setup script, switch every phase 2 feature to "everyone", confirm the nightly jobs, backups and health check all run on the clean project, and install the app on each girl's phone.
3. Walk me through the launch-day checklist one step at a time, waiting for me after each step.

Done when launched_at is set and the first nightly run after launch is clean.
```

---

## Handy prompts for later

**Resume a stage** (new session, unfinished work):

```text
Continue stage <N> of the Big Bucks build. Read CLAUDE.md and docs/PROGRESS.md, tell me where things stand and what's left, then carry on.
```

**Fix a bug found in the beta:**

```text
Bug in Big Bucks. What happened: <describe>. What I expected: <describe>. Severity: <Money / Broken / Confusing / Cosmetic>. Read CLAUDE.md first. Write a failing test that reproduces it, then fix it, run every test (and the time machine if money is involved), and log the fix in docs/PROGRESS.md.
```

**Add a version 2 feature** (after launch): describe it, point Claude Code at the Version 2 list in docs/SPEC.md, and ask for a plan behind a new feature switch, tested on your test account first.
