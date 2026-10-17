# Stage 11 plan — Learning features, statements and view modes

Status: **built and tested locally (2026-10-17); not in production yet.** Approved by Dad 2026-10-17 with the recommended answers to A–H, and five additions (below, they replace anything they contradict). Stage 10's step 10 is still open; nothing for Stage 11 touches production until it's confirmed.

## Dad's five additions (2026-10-17)

1. **The statement identity can't be empty.** Fund gains are worked out on their own, never as what's left over. For each fund: its value at the month's last final close (units × close, to the cent), minus its value at the month before's, minus what she paid for units bought in the month, plus what she got for units sold. Dividends are their own line. Two tests:
   - End = Start + In − Out + Interest + Dividends + Fund gains + Fixes;
   - End = that day's total worth from the existing graph function (`daily_balances`), and Start likewise.
   - **A mutation test** puts in a wrong Fund gains (a version that forgets sells), checks that the identity test then fails, and rolls it back.
2. **Interest timing (from the code):** a statement counts money on the day it's dated (`effective_at`). Savings interest for October is dated the start of Nov 1, so it's on **November's** statement. Interest still accruing (savings before the 1st, a GIC before it finishes) is never part of total worth: not on Home (`account_balances`), not on the graph (`daily_balances`), and not on a statement. A test checks that, for a month with accruing interest, all three agree to the cent, and that the interest appears on the next month's statement.
   - So October's statement is ready **on Nov 1**: once October is over and its nightly jobs have finished through Oct 31, with no "Updating…" for her. It doesn't wait for the interest.
3. **The what-if GIC case** adds, while any what-if GIC is still growing: "GIC interest is paid when each GIC finishes. {n} still growing." So the GICs don't look worse just because they're early.
4. **The reflection box** has "Mom and Dad can see this." under "Why did you sell?"
5. **What's new for accounts made after a feature is on:** already handled. Finishing onboarding marks every feature that's on for her as seen (`finish_onboarding`, since the second audit), so a girl who signs up at Stage 12 with features already on gets no What's new cards for them. A new test proves it for the Wish List (9), Make it yours and Badges (10) and all six Stage 11 switches. One that's switched on after she onboards still gets its card, once.

Six switches, each `off` / `test` / `everyone`, added to `feature_list()` so they appear on Settings:

| Switch | Feature |
|---|---|
| `feature:inflation` | Inflation view |
| `feature:whatif` | What-if comparison |
| `feature:markets` | Compare the markets |
| `feature:reflection` | "Why did you sell?" |
| `feature:statements` | Monthly statements |
| `feature:viewmodes` | Basic and detailed modes |

"Done" means `supabase test db`, `npm test`, Playwright and `npm run timemachine` all pass, and all six switches are on for test accounts only.

## 0. What's already there

- `accounts.view_mode` (`basic` / `detailed`, default `detailed`) has existed since Stage 1, unused.
- The `inflation_rate` setting (2.0%) is editable on Settings with notice rules.
- `requests.reflection` exists, but nothing writes it (see 4: I won't use it).
- The graphs already work out end-of-day totals (`daily_balances`, `fund_value_at`) and "money in vs earned". Statements and the what-if reuse the same rules, so every screen agrees.
- The reference model already records every kid's end-of-day figures and every posting, so statements and the what-if can be checked against it independently.

## 1. Money rules (all six features)

- **Every figure is computed in Postgres from the ledger, rates, settings and closes,** in integer cents (units `numeric(20,8)`, accruals `numeric`). The browser only shows results. No floating point anywhere, SQL or TypeScript.
- **Nothing posts, moves or stores money.** No ledger rows, no balances stored. The only new writes are her reflection text, her view mode and Dad's switches.
- **No money function changes.** Like Stage 10, the migration creates new read functions and the reflection save, and replaces only `feature_list`, `parent_view`, `prelaunch_tables` and the What's new rows. I'll show you the full list, and diff each replaced function against its previous version, before you approve the commit. A pgTAP check fails if any money function mentions the new features.
- **The reflection is a separate call** (`kid_save_reflection`), made by the app only after `request_trade` has succeeded. Skipping it, closing the app or a failed save never blocks, changes or delays the sell.
- **The time machine runs locally** before the commit (these features read money logic), and I'll show you the result. It gets two new checks: every statement, and the what-if, against the reference model.

## 2. What-if comparison

Shown as: "Here's what would have happened if all the money you put in had gone into just one place."

- **What she'd have today** in each of three cases (all in savings, all in 1-year GICs, all in the Nasdaq-100 fund), next to what she really has. All from her real deposit and withdrawal moments (the deposit's `effective_at`).
- **Rates:** the rate in force at each date, specials included and cancelled changes skipped. These are exactly the rules her real money follows (`rate_on`), so the what-if can never use a rate she couldn't have had.
- **Savings case:**
  - each day accrues the end-of-day balance × that day's savings rate ÷ the year's days, in fractional cents;
  - each month's total posts on the 1st, rounded up to the cent.
- **1-year GIC case:**
  - each deposit buys a 1-year GIC that day at that day's 1-year rate (a special included);
  - at maturity it renews for another year with everything (principal + interest), at the 1-year rate that day. That's how compounding shows up, as in the real app;
  - interest: principal × rate, rounded up, at maturity;
  - the $10 minimum is left out (said in "How was this calculated?").
- **Nasdaq-100 case:**
  - each deposit buys units at the first final close after the deposit (units rounded up at 8 decimals);
  - splits adjust units;
  - dividends are paid by the real pro-rata rule, rounded up, and kept as cash (decision C);
  - today's value = units × the latest final close, to the nearest cent, as her real fund value is shown.
- **Counting like her real money (decision B):** interest counts when it would really be paid: savings on the 1st, a GIC at maturity. So a GIC case under a year old shows no interest yet, just as her real GIC doesn't. The comparison with her real total worth is then like for like.
- **Withdrawals (decision A):** taken out of the what-if at their real moment, by the real rules:
  - savings: from the balance;
  - Nasdaq-100: units sold at that day's close, proceeds rounded up;
  - GICs: from matured money first, otherwise the newest GIC is broken (principal back, no interest), as a real break works.
- **Corrections:** "money in" corrections count like deposits and "money out" ones like withdrawals. "Earned" corrections are left out (they are Dad's fixes to earnings, not money she chose where to put).
- **Wording (MESSAGES §14, for review):** her real total first, then the three cases, then "Different choices do better at different times. Nobody can know ahead of time." Never "you lost", "you could have" or "wrong". "How was this calculated?" lists the assumptions above in kid words.
- **Shown in both modes.** Basic mode: four big figures. Detailed mode: the figures plus "How was this calculated?"

## 3. Compare the markets

- The three funds' **% change over the same period**, all starting at 0%, one line each in its fixed colour.
- **Ranges:** 1M, 3M, 1Y, 2Y (as far back as the price history goes), and "Since you started" when she has an account.
- **Closes:** split-adjusted. Weekly backfill closes are used here only (as the graphs already do; they are history, never money).
- **Data size:** daily points up to 3 months; weekly points for 1Y and 2Y. That's at most about 110 points × 3 funds.
- **Detailed mode only.**
- **Wording:** "Same time, different markets. Each fund follows a different group of companies."

## 4. Reflection: "Why did you sell?"

- **When:** right after a fund sell request succeeds, an optional box: "Why did you sell? (You can skip this.)" with **Save** and **Skip**.
- **Her words only:** no suggested answers. At most 300 letters.
- **Storage (decision E):** its own table, `sell_reflections`: request id (unique), account, text, when.
  - Not `requests.reflection`: I'd rather not write to a table the money functions use; that column stays empty and is noted as unused.
  - One per sale; append-only (no edits), like the ledger.
- **Shown:** on that sale's line in her history ("Why I sold: …"), in "View as", and to Dad in the history he views. RLS: her rows, or the parent. Her sister never sees it.
- **Backups, Download zip and restore drill** pick the new table up automatically. `prelaunch_tables` adds it, so the pre-launch reset clears it with the requests.

## 5. Monthly statements

- **Lines:**
  - Starting balance (end of the month before);
  - Money in (deposits, and "money in" corrections);
  - Money out (withdrawals, and "money out" corrections);
  - Interest (savings, GIC and late interest);
  - Dividends;
  - Fund gains or losses (the change in her funds' value that isn't money moved in or out);
  - Fixes from Dad (corrections that count as "earned"), only when there are any;
  - Ending balance.
- **Basic mode** shows Start, Money in, Money out, Earned (interest + dividends + fund gains + fixes) and End.
- **Computed live from the ledger (decision D), never stored.** It can't drift from the ledger, needs no new nightly job, and adds nothing to backups or the reset.
  - **The month is "final" first:** the month is over, and its nightly jobs (both chains) have finished through its last day, with no "Updating…" for her. After that its numbers can't change: anything posted later counts from its own day, which is in a later month. Savings interest is dated the 1st, so it belongs to the next month (addition 2).
  - **Before that:** "Your October statement will be ready on Nov 1."
- **Exact by definition and by test:** End = Start + In − Out + Interest + Dividends + Fund gains + Fixes, to the cent.
  - Start and End are her end-of-day total worth (the same as the Total worth graph).
  - Every ledger line in the month must fall into exactly one line above. Internal moves (savings ↔ GIC ↔ fund) cancel out.
  - A pgTAP test checks the identity for every account and month and fails on any ledger line that isn't counted. The time machine checks every month of the simulated year against the reference model, to the cent.
- **The first statement is partial:**
  - test_kid's October 2026 starts on the day her account opened: "Starting balance (Oct 10, when your account opened): $0.00";
  - after the pre-launch reset, each girl's first statement is her launch month, partial the same way;
  - test_kid's first real one is October, ready on the evening of Nov 1.
- **Who sees them:** she does (Statements, from Home and her history). Dad sees them in "View as".
- **Download (decision H):** **Print or save as PDF** through the browser's own print, with a print-friendly layout. No new service, no files stored.

## 6. Basic and detailed modes

- **Per account, not per device** (`accounts.view_mode`): the same on her phone and her tablet. She switches with "Simpler view / More detail" at the bottom of Home (`kid_set_view_mode`). Not logged; it's her choice and isn't money.
- **Basic:**
  - **Home:** total worth very large; three big lines (Savings, GICs, Funds); her goal; the banner; the last 3 activity lines; no sparklines, mix or daily % rows.
  - **Graphs:** Total worth over time, My mix, and Money in vs earned (dollars only).
  - **Learning features:** the what-if as four big figures; statements in their simple form; no inflation view; no Compare the markets.
- **Detailed:** everything there is today, plus the learning features in full.
- **Buy / Sell is the same in both modes:** money actions keep every warning.
- **Defaults (decision F):** test_kid stays detailed. For the girls at launch, Dad picks each one's starting mode at Stage 12 (set from "View as" or the setup script), and each can switch.
- **While `feature:viewmodes` is off,** everyone sees today's detailed screens.

## 7. Inflation view

- **The rate:** the `inflation_rate` setting in force today (2.0%, Dad edits it on Settings). It's never typed into the app.
- **A toggle on Home, "What will it buy? 💡",** remembered on that device only (a screen preference, like a graph range). It adds a line to each card:
  - **Savings:** "In a year, at today's 1.5% savings rate, your $184.11 would grow to about $186.87. Prices usually go up too, about 2% a year right now **?**, so it would buy about what $183.20 buys today."
  - **GICs (each):** the same, to its maturity, at its locked rate.
  - **Funds:** "Funds don't have a set rate. Over the past year, the Nasdaq-100 fund went up 18%, while prices went up about 2%." Looking back, never a promise forward.
  - **The total** gets one gentle line, and a closing note: "That's normal. It's one reason people use GICs and funds too."
- **Calculations in Postgres:** the regular savings rate and monthly compounding, as the wish list's projection already does (`wish_savings_rate`); GIC locked rates; the fund's 1-year change from final closes. Everything to the nearest cent and worded "about".
- **Not scary:** no red, no "losing money". A **?** "inflation" glossary entry: "Prices slowly go up over time. A treat that costs $1.00 now might cost $1.02 next year."
- **Basic mode: hidden (decision G).** The younger girl sees it by switching to detailed.

## 8. Data, RLS and backups

- **New table:** `sell_reflections` (RLS: her rows, or the parent; append-only guard; kids write only through `kid_save_reflection`).
- **No other new tables.** Statements, the what-if, markets and inflation are reads. View mode uses the existing column.
- **Backups and Download zip:** automatic (they find every table). **Restore drill:** automatic. **Pre-launch reset:** `prelaunch_tables` adds `sell_reflections`; view modes stay (accounts are kept), so Dad resets the girls' modes at Stage 12 if he wants.
- **What's new:** six new rows in `whats_new_features` (append-only, inserts only), wording in MESSAGES §11.

## 9. Performance on phones

- **What-if:** one database call, simulated day by day in Postgres. I'll time it on a two-year simulated history and aim for under half a second; if it's slower, I'll tell you before going further. Run only when its card opens, never on Home's first load.
- **Compare the markets:** at most about 330 points. It loads with the Graphs tab (Recharts is already loaded lazily).
- **Statements:** one month per call; the list of months is a small separate call.
- **Inflation lines:** one small call when the toggle goes on.
- No new pictures or libraries. The bundle grows by a few KB of screens.

## 10. Tests

- **pgTAP:**
  - **Statements:** known answers for a month with every kind of line, a partial first month, a month not final yet, the identity for every account and month, and a ledger line that isn't counted (must fail). RLS: her sister can't read them.
  - **What-if:** known answers for each case: a special-rate deposit, a GIC renewal, a split, a withdrawal from each case, a deposit made before a rate change.
  - **Reflection:** saved after a sell; refused for a buy, someone else's sell, twice, or over 300 letters; RLS; append-only; the sell itself is untouched when the reflection fails.
  - **Inflation and markets:** known answers. **Switches:** each feature is off for a real kid while "test accounts only". **No money function** mentions the new features.
- **Vitest:** wording, formatting, the basic/detailed screen choices.
- **Time machine:**
  - each kid's statement for every month of the simulated year, from the model's own postings and end-of-month figures, to the cent;
  - the what-if on the last day, all three cases, from a separate model simulation, to the cent.
  - Run locally, result shown to Dad.
- **Playwright:** every new screen in both basic and detailed mode, at the six sizes with normal and large text; the reflection after a real sell; a statement's print layout.

## 11. What Dad tests on the phone as test_kid (after the switches go on)

1. Settings → the six switches → each "Test accounts only".
2. As test_kid: the What's new cards, one per feature. **Show me** opens each.
3. **Modes:** Home → "Simpler view": big numbers, fewer cards, Graphs has three graphs. Switch back to "More detail". On the tablet too, it stays as chosen (per account).
4. **Inflation:** Home → "What will it buy? 💡" on: a line on Savings, each GIC, each fund and the total; the **?** opens. Off again.
5. **What-if:** Graphs → What if? Her total, then the three cases, then "How was this calculated?" Compare with her real total.
6. **Compare the markets:** Graphs → three lines from 0%; try 1M / 1Y / Since you started.
7. **Reflection:** sell $10.00 of a fund she holds (settles at the next close). "Why did you sell?" appears: type a reason → Save. Then history: the sale line shows "Why I sold: …". Sell again another day and tap Skip: the sell still goes through.
8. **Statements:**
   - before Nov 1: Statements says "Your October statement will be ready on Nov 1.";
   - **on Nov 1:** October 2026 appears, starting "Oct 10, when your account opened: $0.00". October's interest isn't on it: it's dated Nov 1, so it opens November's statement;
   - check each line against her history: deposits $200.00, the fund line, and the end equal to her total worth on Oct 31 (the Total worth graph's Oct 31 point);
   - **Print or save as PDF** shows a clean one-page layout.
9. **Large text and landscape** on the new screens; nothing cut off.
10. **Your phone → View as test_kid:** her mode, statements, what-if and reflections, all read-only.

## 12. Production steps (after Stage 10's step 10 is confirmed, and after Dad's OK at each)

Never 7:00–11:45 am, or from 4:00 pm until that evening's nightly run shows done.

1. Check last night's run and the outbox, from the backup in step 2 (as in Stage 10).
2. Take a backup by hand. It must be green.
3. `supabase db push --dry-run` lists only the Stage 11 migration.
4. `supabase db push`, then the dry run again: "Remote database is up to date."
5. (No Edge Function changes in this stage. If that changes during the build, `functions deploy` goes here.)
6. Deploy to GitHub Pages; I check the live bundle.
7. Take a backup by hand: `sell_reflections` present (0 rows), six new What's new rows.
8. The six switches → Test accounts only. Then the phone test above (steps 2–7 and 9–10; step 8 completes on Nov 1).
9. Take a backup by hand, then the restore drill on it.
10. The next evening: every job OK as before. Nothing in this stage runs at night.

## 13. Decisions for Dad

- **A. What-if withdrawals:** taken out by the real rules at their real moment (savings from the balance; fund units sold; GICs from matured money first, else the newest broken with no interest). Recommended; it's honest and teaches that GICs lock money. Alternative: ignore withdrawals and compare only what she put in.
- **B. What-if counts interest like her real money** (savings on the 1st, GICs at maturity), so it compares like for like with her real total. Recommended. Alternative: add interest earned so far.
- **C. The Nasdaq-100 case pays dividends as cash.** Recommended. Alternative: leave dividends out.
- **D. Statements computed live from the ledger once a month is final, nothing stored.** Recommended. Alternative: a stored, append-only statement made by a new nightly job.
- **E. Reflection in its own append-only table, one per sale, 300 letters, no edits, seen by her and Dad.** Recommended.
- **F. View mode per account. test_kid stays detailed; Dad picks each girl's starting mode at Stage 12.** Recommended.
- **G. Inflation view hidden in basic mode.** Recommended. Alternative: a one-line version in basic.
- **H. Statement download through the browser's Print / Save as PDF.** Recommended (no new service).
