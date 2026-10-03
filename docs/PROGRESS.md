# Big Bucks — Progress log

Claude Code updates this file at the end of every stage. Newest stage at the top.

## Status

- Current stage: stage 0 done (next: stage 1)
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
  - **CI on GitHub has not run yet.** It runs on the first push.
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
