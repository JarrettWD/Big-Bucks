# Price fix: build notes (branch `price-fix`)

Working notes for the build of `docs/plans/price-fix-plan.md` (approved by Dad 2026-11-05, with his additions through 2026-11-09). Started 2026-11-13 in the worktree `C:\Dev\Big-Bucks-price-fix`, off `main` b99aac8. No merge, no production change until Dad's review.

**Estimate given to Dad (2026-11-13):** ready for review Wed Nov 18 evening; suggested review Thu Nov 19, production Sat Nov 28 after 11:45 am (Nov 21 only if the review needs no changes).

## Design decisions (how the plan is built)

1. **"Not before 9:00 pm" is the database's rule, not the function's.** A day's close is ready to fetch and store only from `close_ready_at(market, day)`: `confirm_time(day)` = 9:00 pm Alberta for days on or after the cut-over, `close_time(day)` before it. So:
   - `missing_closes` lists only days whose `close_ready_at` has passed, so the nightly function never asks for today's close before 9:00 pm;
   - `store_close` refuses a close before its `close_ready_at`;
   - `final_close` counts a close only if fetched at or after its `close_ready_at`, so settle, dividends and notes can never use an earlier one, even one inserted directly.
   No close is stored "provisionally" and confirmed later; Home, Graphs and statements already read stored closes, so they show the previous day until the 9:00 pm run with no new display code.
2. **The cut-over** is the setting `closes_confirmed_from` (a date), inserted by the migration as `app_today()` on the day it runs (append-only settings; production gets the day of the production session; a local reset gets the reset day). Closes stored before it keep their old rule.
3. **The evening timer:** `nightly_kick` raises missing-close alerts from 10:00 pm (was 9:00 pm). Between the 4:30 pm run and 9:00 pm it doesn't call the function again when the only things outstanding are today's closes and the fund jobs waiting for them ("waiting: today's closes are confirmed at 9:00 pm"); it still retries every 30 minutes if a core job failed.
4. **Bounded catch-up:** `run_daily(p_through, p_max_days)` and `reconcile_through(p_through, p_max_days)` overloads do at most `p_max_days` days per call and commit; the one-argument versions (time machine, demo, tests) stay as they are. The nightly function calls the bounded ones (5 days) in a loop until tonight's day or its own time limit (95 s, as for prices); the next kick carries on.
5. **Provider values log and the mismatch check:** a table `price_observations` (fund, day, close, observed at, price call) with explicit grants (SELECT to authenticated, service_role, backup_reader; written only by a function), filled by the nightly function with the last 15 trading days of each daily call. `check_price_mismatches()` raises a `price_mismatch` alert (new `alert_kind`) for a stored final close that differs by 1¢ or more from a later observation taken at or after that day's `close_ready_at`; it does nothing unless the setting `price_mismatch_check` is `on`. The migration leaves it `off`; Dad switches it on in Settings after the corrections on production day.
6. **"Fix a close" corrects settled trades in her favour** (`correct_fund_price`, extended; one parent action, MFA, logged, previewed):
   - a shared read `close_fix_adjustments(fund, day, new_close)` lists every trade (and dividend) that used the close, with what she got, what she should have got, and the adjustment; the preview and the action use the same rows;
   - buy at a close that was too high: the missing units, `round_up_units($ ÷ new close) − units she got`, posted as a fund-side `correction` row (units, $0 cost) linked to the trade's fund line (`corrects_id`), key `fix:close:<fund>:<day>:<request>`; the links guard (`transactions_check_links`) is widened for exactly this case (a fund correction pointing at the same kid's fund line), and every reader of fund lines is checked to handle it (history, statements, graphs, reconcile);
   - sell at a close that was too low: the missing cents to savings, rounded up, plus the savings interest on them from the settlement day to the correction day, rounded up, as one savings `correction` linked to the trade's savings line;
   - a dividend paid from a close that was too low: the difference, rounded up, plus its interest the same way;
   - anything in her favour already: no change, listed in the preview and logged;
   - then the stored close is corrected (`fund_price_corrections`, old and new).
   - Her notice (type `correction`), money first: "A price was fixed. The Nasdaq-100 fund's Nov 5 close was really $647.05, not $648.58, so your buy should have got a little more. We added the missing bit — worth about 2¢. A fix like this can only add, never take away." Under 1¢: "worth less than 1¢". The units and the working go under "How was this calculated?".
7. **The parent "fix a close" screen** (pre-Stage-12 list) is built here, because production day needs it: pick a fund and day, see the stored close, type the official one and where it comes from, see the preview of every adjustment, then Yes.
8. **Her screens:** the waiting line names its close ("Waiting for today's 3:00 pm close (Nov 9) · asked Nov 6"; after 3:00 pm "Waiting for today's close to be confirmed (Nov 9) · asked Nov 6"), the same on Buy / Sell and in Recent activity; a fund whose day is behind the others after 9:00 pm says "Today's TSX close comes in later" on its card.

## Production day

Sat Nov 21 after 11:45 am, then Mon Nov 23 (first confirmed closes) and Tue Nov 24 (the 10:00 pm box): the steps are in docs/PROGRESS.md, "Price fix: built, ready for Dad's review".

## Progress

- [x] Worktree and branch; design read from the current code (2026-11-13).
- [x] Known-answer database tests (price_confirm 41, close_fix 52, price_words 12).
- [x] Migrations (five, 20261113000000 to 20261113040000).
- [x] Nightly function.
- [x] Screens (her waiting line, late-close note, confirm tip, close-fix lines; Fix a close; the price check in Settings).
- [x] Time machine: 20 of 20.
- [x] End-to-end, two full runs (131 of 131 each); CI.
- [x] Docs (MESSAGES §14 and her lines, RUNBOOK, ACCEPTANCE wording, PROGRESS).
