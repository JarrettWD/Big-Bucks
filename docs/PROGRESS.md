# Big Bucks — Progress log

Claude Code updates this file at the end of every stage. Newest stage at the top.

## Status

- Current stage: stage 1 done (next: stage 2)
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
