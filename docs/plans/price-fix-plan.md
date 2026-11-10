# The price fix: confirmed closes and in-her-favour corrections

Approved by Dad 2026-11-05, with his decisions below. A reviewed money-function change and a **launch blocker**: the girls' real accounts don't open until it's done.

**Schedule:** build Nov 10–13 in its own worktree and branch; Dad's review Sat Nov 14; production Sat Nov 21 after 11:45 am. Nov 7 goes ahead unchanged (it doesn't touch how prices are stored).

## The problem (found Nov 5, investigated read-only)

At our 4:30 pm Alberta fetch (6:30 pm New York), the provider's bar for that day can still hold a price from a few minutes before the close. Our rule counted any close fetched after the close time as final, so trades settled on it, and the nightly never re-checks a stored close.

Stored close against the official close (Yahoo Finance daily history), with the time we fetched it:

| Day | DIA stored / official (fetched) | QQQ stored / official (fetched) | XIC stored / official |
|---|---|---|---|
| Oct 19 | **519.02 / 518.92, +0.10** (4:30 pm) **trade #17** | 718.36 / 718.36 (5:00 pm) | 57.32 / 57.32, trade #15 |
| Oct 20 | **524.43 / 524.36, +0.07** (4:30 pm) | 717.63 / 717.63 (4:30 pm) | 57.62 / 57.62 |
| Oct 21 | **527.65 / 527.70, −0.05** (4:30 pm) | 725.20 / 725.20 | 57.99 / 57.99 |
| Oct 22 | **527.93 / 527.89, +0.04** (4:30 pm) | 704.47 / 704.47 | 57.46 / 57.46 |
| Oct 23 | **521.42 / 521.37, +0.05** (4:30 pm) | 704.40 / 704.40 | 57.15 / 57.15 |
| Oct 26 | **522.95 / 522.97, −0.02** (4:30 pm) | 712.20 / 712.20 | 57.42 / 57.42 |
| Oct 27 | 523.28 / 523.28 (next day 7:30 pm) | 721.25 / 721.25 (next day) | 57.76 / 57.76, trade #22 |
| Oct 28 | 524.68 / 524.68 (7:30 pm) | 725.61 / 725.61 (7:30 pm) | 57.94 / 57.94 |
| Oct 29 | 522.73 / 522.73 (9:30 pm) | 715.34 / 715.34 (9:30 pm) | 57.87 / 57.87 |
| Oct 30 | **517.10 / 517.13, −0.03** (4:30 pm) | 690.49 / 690.49 | 56.89 / 56.89 |
| Nov 2 | **519.39 / 519.34, +0.05** (4:30 pm) | 681.09 / 681.09 | 57.23 / 57.23, trade #26 |
| Nov 3 | **517.00 / 517.06, −0.06** (4:30 pm) | 685.28 / 685.28 | 56.75 / 56.75, trade #32 |
| Nov 4 | **533.12 / 533.11, +0.01** (4:30 pm) | 691.95 / 691.95 | 58.10 / 58.10 |
| Nov 5 | **514.89 / 514.27, +0.62** (4:30 pm) | **648.58 / 647.05, +1.53** (4:30 pm) **trade #35** | 56.90 / 56.90 |

Also: QQQ Oct 12, $746.04, matches (trade #3). Every DIA close fetched at 4:30 pm on its own day was off; every DIA and QQQ close fetched at 7:30 pm or later matched. On Nov 5 the stored $648.58 and $514.89 match the prices traded at about 3:52 pm New York, not the 4:00 pm close or the after-hours price at 6:30 pm. The provider gives no "final" marker (its "last refreshed" is a date only).

**Settled trades affected, all against her:** #17, #35 and #37 (added Nov 9). **Other wrong closes:** DIA on 12 more days (the 10 above plus Nov 6, $512.23 stored vs $512.22, and Nov 9, $523.36 vs $523.33), with no trade or dividend from them. DIA has been off on every close fetched at 4:30 pm on its own day so far; QQQ and XIC matched on Nov 6 and Nov 9.

## 1. Confirmed closes

- **Rule:** a close is final only if fetched **at or after 9:00 pm Alberta on its own day**, or on a later day (Dad's decision). One database rule, `confirm_time()`, beside `close_time()`; `final_close()` uses it, so settle, dividends and notes wait for a confirmed close.
- **The nightly function doesn't fetch the day's closes before 9:00 pm.** The 4:30 pm run still does what needs no price (interest, GIC maturities, expiry, monthly posting, rate notices, reconcile); the 9:00 pm run fetches, settles and checks. Price calls: 3 at 9:00 pm plus retries.
- **The late-close path is reused:** a trade waits for its close as the time machine's late closes do; the money counts from the close itself (that day's interest is worked out the next evening).
- **Closes already stored** stay as they are from the cutover; the safety net below covers them.
- **The missing-close alert moves to 10:00 pm** (Dad's decision), after the 9:00 and 9:30 pm attempts. ACCEPTANCE's "A close still missing at 9:00 pm Alberta time alerts Dad…" is reworded to 10:00 pm and re-tested on production.
- **Safety net, `price_mismatch`:** every daily call already returns about 100 days. Each run compares the provider's values for the last 10 trading days with the stored closes; a difference of 1¢ or more raises an alert for Dad with both values, and never changes money by itself. Each run keeps the provider's values in a small read-only log.
- **What she sees while a close isn't confirmed yet** (3:00 pm to about 9:30 pm):
  - Buy / Sell's 💡 line: "Happens at today's 3:00 pm close. The close is confirmed in the evening, by about 9:30 pm, then your units appear."
  - Her waiting line: before 3:00 pm "Waiting for today's 3:00 pm close · asked Nov 4"; after it "Waiting for today's close to be confirmed · asked Nov 4".
  - Home and Graphs use confirmed closes only; a fund's day change shows the previous day until then, labelled with its day.
- **The evening no-change window** now runs from 4:00 pm until the nightly is done (about 9:30 pm). RUNBOOK and CLAUDE.md say so (Dad's decision).

## 2. Correcting trades that settled at a wrong close

Designed with the pre-Stage-12 "fix a close" parent screen: `correct_fund_price` becomes one parent action (MFA, logged, previewed with `in_preview()`, one transaction). For a close that trades or a dividend used, it:

1. **previews each affected trade with its adjustment, always in her favour:**
   - a buy at a close that was too high: the missing units (units at the right close minus the units she got, both rounded up as when settling), added at no cost, so what she paid stays the same;
   - a sell at a close that was too low: the missing cents to savings, rounded up, **plus the savings interest those cents would have earned from the settlement day to the correction day, rounded up** (Dad's decision), so she's made whole;
   - a buy at a close that was too low, or a sell at one that was too high: nothing taken back; the preview says "no change: this one was in her favour", and it's logged;
   - a dividend from a close that was too low: the difference, rounded up (and its missing interest, as for a sale); too high: nothing taken back;
2. **posts each adjustment** as a correction with its own unique key (for example `fix:close:nasdaq100:2026-11-05:35`), a plain note, and a notice for her;
3. **then corrects the stored close** (`fund_price_corrections`, old and new), so her fund value and graphs use the official close.

**Her notice leads with money, not units** (Dad's wording):

> **A price was fixed.** The Nasdaq-100 fund's Nov 5 close was really $647.05, not $648.58, so your buy should have got a little more. We added the missing bit — worth about 2¢. A fix like this can only add, never take away.

Under 1¢: "worth less than 1¢". The exact units go under "How was this calculated?" (for #35: "$10.00 ÷ $647.05 = 0.01545476 units, rounded up; you got 0.01541830, so 0.00003646 more units were added").

- **#35** (QQQ, Nov 5): $10.00 ÷ $647.05 rounded up = 0.01545476; she got 0.01541830: **+0.00003646 units**, worth about 2.4¢.
- **#17** (DIA, Oct 19): $10.00 ÷ $518.92 rounded up = 0.01927080; she got 0.01926709: **+0.00000371 units**, worth less than 1¢.
- **#37** (DIA, Nov 9, added Nov 9; placed Fri Nov 6 at 3:02 pm, settled at Monday's close as it should): $10.00 ÷ $523.33 rounded up = 0.01910841; she got 0.01910731 (at $523.36): **+0.00000110 units**, worth less than 1¢.

## 2b. Catch-up in bounded steps (Dad, 2026-11-06)

**Found Nov 6:** the local end-to-end test catching up 27 days in one call ran past the statement time limit in `reconcile_through`. Every retry would start over and time out again, so a long gap would never recover on its own.

- **Production's limit, read-only Nov 6:** the nightly function reaches the database through PostgREST as `authenticator` (`statement_timeout=8s`, `lock_timeout=8s`) acting as `service_role` (no setting of its own), so each call (`run_daily`, `reconcile_through`, `check_badges_through`) has **8 seconds**. On Oct 28 the two-day catch-up took about 0.15 s (`run_daily`) and 0.23 s (`reconcile_through`) for one account: roughly 50–100 days in one call today, fewer as the girls' history and accounts grow (reconcile re-adds the ledger). Measured properly during the build, with a girl's-size history.
- **The change:** each call does a bounded amount and commits: `run_daily` and `reconcile_through` take at most a few days (for example 5) per call, and the nightly function calls again until it reaches tonight's day or runs short of its own time (it already stops new price calls after 95 s and lets the next kick carry on). Each day's jobs stay in one transaction, so nothing half-happens. A gap of any length then recovers over one or more evenings with no help.
- **Test:** the timer off for 35+ days with trades and a rate change in the gap; catching up completes fully (several calls, or several evenings), every day's jobs once, nothing posted twice (posting keys, interest days, job-days), reconcile ok, the waiting trades at their own days' confirmed closes. Plus a pgTAP check that one call never takes more than its bound.

## 2c. Two screens the change rewrites anyway (Dad, 2026-11-09)

- **Her waiting line names its close** (moved here from the Stage 12 list, since the price fix rewrites that line): Recent activity and Buy / Sell say the same thing.
  - Before the close: "Waiting for today's 3:00 pm close (Nov 9) · asked Nov 6" ("Monday's 3:00 pm close (Nov 9)" when it's a later day).
  - After 3:00 pm, until the close is confirmed: "Waiting for today's close to be confirmed (Nov 9) · asked Nov 6".
- **The funds switch to a new day together.** On Nov 9 Home said "Last market day, Nov 9" while the TSX fund card still said "on Nov 6": XIC's close came in at 5:00 pm, DIA's and QQQ's at 4:30 pm. With confirmed closes (fetched at or after 9:00 pm) all three normally arrive in the same run and switch together. If a fund's day is still behind the others after the 9:00 pm confirm, its card says why in kid words ("Today's TSX close comes in later") instead of showing an older date silently; "Last market day" names the day all her funds have. Tested: one fund's close missing at 9:00 pm, the others confirmed.

## 3. Tests

- **Known-answer (pgTAP):** the confirm rule (before 9:00 pm not final; at or after 9:00 pm, or a later day, final); the 10:00 pm missing-close alert; the 10-day comparison and its alert; the correction path in all four directions plus a dividend; a sell's missing cents **and their interest**, rounded up; #35's and #17's exact figures; no correction twice; the action logged; the preview changes nothing; the notice wording, including "worth less than 1¢".
- **Time machine:** the 4:30 pm fetch a pre-close snapshot and the 9:00 pm close different, **both higher and lower**, with a buy and a sell waiting through the evening; each settles at the confirmed close, matched to the cent with the reference model.
- **End-to-end (local only):** a "snapshot" setting for the made-up price source, locked to your computer like "down": the 4:30 pm price differs from the 9:30 pm one, the buy waits with "confirmed in the evening", then settles at the confirmed close; and the "fix a close" screen correcting a settled trade, with its preview.

## The Nov 21 production session, in order

1. Backup by hand; record the deployed functions for rollback.
2. Merge, dry run (the price-fix migrations only), `db push`, deploy the nightly function, smoke check; the Pages deploy after the evening's nightly is done.
3. **Before the safety net goes live**, with "fix a close": correct the 12 DIA closes with no trades, then #17, #35 and #37 (with their adjustments), so `price_mismatch` doesn't fire on known history. Then switch the comparison on.
4. That evening: closes confirmed at 9:00 pm, the missing-close alert at 10:00 pm, re-test ACCEPTANCE's reworded box. A few evenings of confirmed closes before the girls' accounts can open.
