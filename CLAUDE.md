# Big Bucks — project rules for Claude Code

Big Bucks is a pretend bank and brokerage for two kids. Dad holds the real cash; the app tracks what each kid has in savings, GICs and three stock funds, and teaches safety, patience and risk. Every number is money Dad really owes, so correctness beats speed and cleverness every time.

- **Spec:** `docs/SPEC.md` is the source of truth for what to build. Its last section, "Build decisions", settles the details; follow it exactly.
- **Build plan:** `docs/BUILD-PLAN.md` splits the work into stages. Work on one stage at a time, only the stage Dad names.
- **Acceptance:** `docs/ACCEPTANCE.md` is the checklist the finished app must pass.
- **Progress:** `docs/PROGRESS.md` records what each stage delivered. Read it at the start of every session; update it at the end of every stage.

## Stack

- Front end: React + TypeScript + Vite, installable PWA (vite-plugin-pwa), hosted on GitHub Pages. Must work well on Android in Chrome; the kids and Dad use Android, not iPhones.
- Back end: Supabase (Postgres, Auth, RLS, Edge Functions in Deno, pg_cron and pg_net). One free-tier project for production. A local Supabase (CLI + Docker) for development, tests and the time machine.
- Charts: Recharts.
- Tests: pgTAP for database functions and RLS (`supabase test db`), Vitest for front-end logic, Playwright for a few end-to-end smoke tests.
- Brand: purple #5B3FD1, gold #FFD166, pink #FF4F87, white; Fredoka for headings. Icons are in `public/icons/`.

## Non-negotiable money rules

1. **Money is integer cents** (`bigint`) everywhere it is stored or posted. Fractional cents exist only in interest accruals (`numeric`) and fund units (`numeric(20,8)`). Never use floating point for money, in SQL or TypeScript.
2. **The ledger is append-only.** `transactions`, `rates` and `settings` reject UPDATE and DELETE for every role, enforced by triggers. Fix mistakes with a reversing or correcting entry that carries a plain-language note.
3. **All money maths runs in Postgres functions**, never in the browser. Each action is one function call in one transaction: it fully happens or not at all. The front end only displays results.
4. **Balances are never stored.** They are derived from the ledger (views or functions). Nothing can drift.
5. **Rounding always favours the kid**: round up to the cent when posting interest, dividends and sale proceeds.
6. **Nothing posts twice.** Every automatic posting has a unique `posting_key` (for example `interest:2026-11`, `gic_mature:<id>`, `dividend:2027Q1:dow`) with a unique constraint.
7. **Never settle a trade on a stale or guessed price.** Wait for the real close.
8. **Time comes from `app_today()` / `app_now()`**, in the America/Edmonton time zone. Never call `now()`, `current_date` or `new Date()` directly in money logic. In local development the clock can be overridden for the time machine; in production the override is ignored.
9. **Every money rule gets a known-answer test before it ships.** If a rule in the spec has no test yet, write the test first.

## Security rules

- Row-level security on every table. A kid can SELECT only her own account's rows. Test accounts (`is_test`) are kids like any other.
- **The app never writes to tables directly.** Every change goes through a Postgres function (SECURITY DEFINER, fixed `search_path`) that checks who is calling, which account, and the rules, then writes. Kids get EXECUTE only on kid functions; parent functions also require MFA (`aal2`).
- RLS hides rows, not columns. Anything a kid must not see (for example the parent-only "Got it" marker) lives in its own parent-only table.
- Secrets (service role key, database password, market-data API key) live only in Supabase secrets or GitHub Actions secrets. Never in the repo, never in the front-end bundle. Only the Supabase URL and anon key go in the app.
- **No personal data in the repo:** no real names, usernames, PINs or emails, not even in tests, seeds or comments. Real accounts are created at runtime by a setup script. The repo may be public; the backup repo is always private.

## How to work

- **Start each stage with a short plan** (files, migrations, tests, anything Dad must do by hand) and wait for Dad's OK before writing code.
- **Database changes are migrations** in `supabase/migrations/`, never edits made in the dashboard. Migrations must apply cleanly to an empty local database.
- **Once a migration has been committed, never edit it.** Fix or change things with a new migration, because other copies of the database may already have run the committed one.
- **Run the tests before saying a stage is done**: `supabase test db` and `npm test` must pass, plus the end-to-end smoke tests once they exist. Show Dad the result.
- **Any change that touches money logic must also pass `npm run timemachine`** (the simulated year, compared to the cent with the reference model) before the stage is called done.
- **Ask before** adding a paid service, a new third-party service, a new dependency with a large footprint, or anything that touches the production project.
- **Never point tests or the time machine at production.** Production gets migrations and deploys only, after the local run passes.
- When the spec is unclear or two parts conflict, stop and ask. Don't guess about money.
- **End every stage** by updating `docs/PROGRESS.md` (what was built, test results, known issues, anything Dad must do by hand), then stop.
- Write for a non-developer: Dad is technical but not a professional programmer. Explain what he has to do in numbered steps, with exact menu names.

## Kid-facing writing

- Short, warm, accurate sentences a 9-year-old can follow. No jargon without a **?** explanation.
- Never shame or nag. Celebrate good decisions (patience, holding through a drop, finishing a GIC), never activity: no streaks, no rewards for opening the app or trading often.
- Canadian spelling and dollars (colour, cheque; $1,234.56).
