# Big Bucks — Acceptance checklist

Version 1 is done when every box passes. The "Before any real money" group runs in the local copy; the rest runs live during Dad's solo beta with test-kid accounts. Claude Code: when you finish a stage, say which boxes your work makes testable.

Tick each box as it’s proven. Some features only run on the calendar (monthly interest, maturities, rate notices, dividends), so a few test transactions aren’t enough.

**How long:** run the solo beta for at least 6 weeks (two monthly interest postings, a matured 1-month GIC, a rate change and 30 clean nights), and version 1 in full for about 2–3 months before starting version 2.

**Before any real money (in the test copy)**

- [ ] All known-answer tests pass (interest, GIC maturity, broken GIC, trade units, rounding up)
- [ ] The time machine runs a simulated year (rate changes, maturities, dividends, a crash, a missed week) with every balance correct
- [ ] Security tests pass: one girl can’t see or change the other’s data, and no one can edit history
- [ ] One backup has been restored into the local copy of Supabase, with balances matching

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

- [ ] A savings rate change sends the notice, with the 7-day default, and applies on its effective date
- [ ] Existing GICs keep their locked-in rate after a GIC rate change
- [ ] A special switches back to the regular rate on its end date
- [ ] A deposit-cap change reaches both girls with a notice

**Phase 1, live: safeguards and backups**

- [ ] `select * from public.check_time_rules();` on production shows no ok = false rows
- [ ] 30 nights in a row with zero reconciliation mismatches
- [ ] A deliberately skipped night is caught up the next run, with no duplicate postings
- [ ] A simulated price-service outage makes trades wait rather than settle on an old price
- [ ] A test alert reaches Dad’s dashboard and email
- [ ] Production has a few nights of real closes for DIA, QQQ and XIC, and about two years of history for the graphs
- [ ] A close still missing at 9:00 pm Alberta time alerts Dad, and the alert clears itself when the close arrives
- [ ] The morning health check is green on a normal day, and fails (emailing Dad) when anything is open
- [ ] The daily backup commits to GitHub every day, and the copy on Dad’s computer updates
- [ ] The Download backup button produces a complete zip
- [ ] The project has never paused
- [ ] “Something looks wrong?” sends Dad a question, and his reply shows in her history

**Phase 2**

- [ ] Wish list items can be added and reordered, and become goals only after 7 days
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
