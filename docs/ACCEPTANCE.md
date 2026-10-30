# Big Bucks — Acceptance checklist

Version 1 is done when every box passes. The "Before any real money" group runs in the local copy; the rest runs live during Dad's solo beta with test-kid accounts. Claude Code: when you finish a stage, say which boxes your work makes testable.

Tick each box as it’s proven. Some features only run on the calendar (monthly interest, maturities, rate notices, dividends), so a few test transactions aren’t enough.

**How long:** run the solo beta for at least 6 weeks (two monthly interest postings, a matured 1-month GIC, a rate change and 30 clean nights), and version 1 in full for about 2–3 months before starting version 2.

**Before any real money (in the test copy)**

- [x] All known-answer tests pass (interest, GIC maturity, broken GIC, trade units, rounding up) (2026-10-14: CI run #47, `bdfe365`, pgTAP Files=38, Tests=1816, Result: PASS; green on every push since)
- [x] The time machine runs a simulated year (rate changes, maturities, dividends, a crash, a missed week) with every balance correct (2026-10-14: PASS 14 of 14, compared to the cent with the reference model; CI's timemachine job green on run #47 and every push since)
- [x] Security tests pass: one girl can’t see or change the other’s data, and no one can edit history (2026-10-14: the RLS, grants and append-only checks are part of CI run #47's 1816 pgTAP checks, all passing)
- [x] One backup has been restored into the local copy of Supabase, with balances matching (2026-10-10: production backup `2cc0fd4`, 39 of 39 tables, every balance; RUNBOOK "Restore drill")

**Phase 1, live: accounts and logins**

- [ ] Each girl logs in with her username and PIN
- [ ] Five wrong PINs lock the login for 15 minutes and alert Dad
- [ ] Dad’s login requires the second factor
- [ ] Both girls completed onboarding and signed the account agreement

**Phase 1, live: money in and out**

- [ ] A deposit request holds the money, Dad approves it, and it lands in savings
- [ ] A declined request shows her Dad’s reason
- [ ] An unanswered request expires after 7 days and releases the held money
- [ ] A deposit over the cap is blocked with a clear message
- [ ] A withdrawal waits 24 hours before Dad can approve it
- [ ] Cashing out of a GIC or fund requires moving it to savings first

**Phase 1, live: savings and GICs**

- [ ] Savings interest posts on the 1st and matches “How was this calculated?” (checked by hand once)
- [ ] A 1-month GIC matures on the right day with the right interest, rounded up
- [ ] The maturity banner appears; with no choice for 7 days, the money moves to savings
- [ ] Breaking a GIC early shows the warning, returns the principal and pays no interest

**Phase 1, live: stock funds**

- [ ] A buy in each fund settles at the next market close (a Friday-evening request settles Monday)
- [ ] Only one trade per fund per day is allowed
- [ ] Settlement times read 2:00 pm in Alberta in summer and 3:00 pm in winter (4:00 pm Toronto), and a 2:30 pm winter request settles the same day
- [ ] A partial sell works, and proceeds land in savings
- [ ] Each fund’s value tracks its ETF (DIA, QQQ, XIC) to the cent
- [ ] The standard note appears on a day a fund moves more than 2%
- [ ] A quarterly dividend posts correctly (live, or in the time machine if no quarter falls in the solo beta)

**Phase 1, live: rates and settings**

- [x] A savings rate change sends the notice, with the 7-day default, and applies on its effective date (2026-10-29: Dad saved 2.0% → 1.0% on Oct 19, effective Oct 26, 7 days ahead; the kid had the notice that evening and "The new savings rate is now 1.0%" on Oct 26; backup `37e9784` shows Oct 25 at 2.000% and Oct 26 and Oct 27 at 1.000% (rate 12), each day once; PROGRESS Oct 26–29)
- [ ] Existing GICs keep their locked-in rate after a GIC rate change
- [ ] A special switches back to the regular rate on its end date
- [ ] A deposit-cap change reaches both girls with a notice

**Phase 1, live: safeguards and backups**

- [x] `select * from public.check_time_rules();` on production shows no ok = false rows (2026-10-10, RUNBOOK production setup step 6)
- [ ] 30 nights in a row with zero reconciliation mismatches
- [x] A deliberately skipped night is caught up the next run, with no duplicate postings (2026-10-29: the nightly timer off Oct 26–28, so Oct 27 never ran; Oct 28's 7:30 pm run caught up one day at a time: Oct 26's interest, then Oct 27's jobs and Oct 28's, each once and ok (job_runs 312–335), reconcile ok; the $10 test buy (request #22) settled at Oct 27's close, XIC $57.76, not Oct 28's; no posting key, interest day or job-day twice; interest right across the rate change: Oct 25 at 2.000%, Oct 26 and 27 at 1.000% (backup `37e9784`); PROGRESS Oct 26–28)
- [ ] A simulated price-service outage makes trades wait rather than settle on an old price
- [x] A test alert reaches Dad’s dashboard and email (2026-10-10: Send test alert, email arrived, Dashboard alert acknowledged)
- [x] Production has a few nights of real closes for DIA, QQQ and XIC, and about two years of history for the graphs (DIA and QQQ Oct 12–14, XIC Oct 13–14, 2026, the TSX closed for Thanksgiving on Oct 12; backfill: 100 daily closes and weekly closes back to Oct 11, 2024)
- [x] A close still missing at 9:00 pm Alberta time alerts Dad, and the alert clears itself when the close arrives (2026-10-29: the nightly timer off until 9:13 pm; the 9:30 pm check raised `missing_price` alerts 5, 6 and 7 for the Dow Jones, Nasdaq-100 and TSX Oct 29 closes at 9:30:00, and each cleared itself as its close was stored: 9:30:03, 9:30:15, 9:30:28; PROGRESS Oct 29)
- [x] The morning health check is green on a normal day, and fails (emailing Dad) when anything is open (green Oct 13 and 14, 2026; red with GitHub's email on Oct 12, when a `backup_failed` alert was open)
- [ ] The daily backup commits to GitHub every day, and the copy on Dad’s computer updates
- [x] The Download backup button produces a complete zip (2026-10-10, on Dad's phone: csv and json folders, manifest.json, README.txt)
- [ ] The project has never paused
- [ ] “Something looks wrong?” sends Dad a question, and his reply shows in her history

**Phase 2**

- [x] Wish list items can be added and reordered, and become goals only after 7 days (2026-10-25: Dad on production as the test kid: the day-7 "Still want this?" made a goal, shown on Home with its progress bar; the second wish showed "Can be your goal from …"; Move up kept its order after reopening the app, the goal unchanged, and moving back worked; PROGRESS Stage 9)
- [ ] Theme colours and avatars save and show everywhere
- [ ] Badges unlock at the right moments, with their accessories
- [ ] Inflation view numbers match a hand check
- [ ] Monthly statements match the ledger
- [ ] What-if, compare the markets and the reflection prompt work

**Ready for the girls’ launch when**

- [ ] Every box above is ticked in the solo beta
- [ ] A try-it session was held with each girl, and what confused her is fixed
- [ ] The database is reset to a clean start, with no test history
- [ ] Backups, alerts and the nightly checks all run on the clean project

**Ready for version 2 when**

- [ ] Every box above is ticked
- [ ] No open bugs affect money
- [ ] At least two monthly money meetings have been held
- [ ] Each girl can explain the three options and why she chose her mix
- [ ] The girls are asking for more
