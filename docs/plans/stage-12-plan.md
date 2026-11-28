# Stage 12 plan (re-planned 2026-11-27, for Dad's review)

Status: **proposed, not approved.** Nothing here is built yet. Replaces the Nov 24 draft.

Dad's frame (Nov 27): no rush, launch a finished product. Dad is away **Dec 9–23** (no PC). **Production freeze Dec 7–23**, with the test account running as a soak test. **Launch Sat Jan 9**, after the Jan 4 dividend is proven live on the test account.

Times are Alberta time (UTC−6 all year). Production changes only after 11:45 am and finished before 4:00 pm (RUNBOOK, "When production may change").

## The calendar

| When | What |
|---|---|
| **Fri Nov 27** | Withdrawal A and B started (section 5). Tonight after 9:30 pm: the read-only check of today's 1:00 pm early close. |
| Sat Nov 28 | Approve withdrawal A once its 24 hours are up. |
| Nov 28 – Thu Dec 3 | Build block 1: the non-money items (section 1), one at a time, each reviewed by Dad. **Last merge Thu Dec 3.** |
| Wed Dec 2 | Read-only: the Dec 1 run posted November's savings interest. |
| Fri Dec 4 | Dad's final review of block 1; full local run. Tonight's run should expire withdrawal B. |
| **Sat Dec 5** | **Production session 1** (section 3). |
| Sun Dec 6 | Spare day: rollback if needed. **The girls see nothing of Big Bucks before launch** (Dad, Nov 27): Mom does the try-it session on the test account, and Dad does the install check on a girl's phone without her seeing the app, then removes it (section 7). |
| Dec 6 – 8 (optional) | With Dad's OK, build one or two slip-list items locally on a branch, for Jan 2 (section 2). |
| **Dec 7 – 23** | **Freeze.** Nothing changes production. Soak test (section 4). |
| Thu Dec 24 | Back. Read-only soak review. Christmas Eve early close (1:00 pm, both markets): check it that evening. |
| Dec 24 – Thu Dec 31 | Build block 2 (section 2). **Last merge Thu Dec 31.** |
| Fri Jan 1 | Both markets closed. The evening run posts December's interest. |
| **Sat Jan 2** | **Production session 2** (section 3). |
| Sun Jan 3 | Spare day: rollback before the dividend if Jan 2's evening run shows a problem. |
| Mon Jan 4 | The first quarterly dividend, live on the test account. |
| **Tue Jan 5** | Check the dividend (section 6). |
| Jan 5 – 8 | Rehearse `prelaunch_reset()` on a local copy of the latest backup; Dad's fresh audit; final launch checklist review. |
| **Sat Jan 9** | **Launch** (section 7). |

## 1. Block 1, before the freeze: non-money only (Nov 28 – Dec 3)

No money-function changes. Each item still gets a plan, Dad's OK, its tests, and screen checks at small phone, tablet and desktop. The order puts the quick and launch-critical items first, so that if the week runs short, what's left is the item that can wait.

| # | Item | What changes | Estimate |
|---|---|---|---|
| 1 | **Fix a close: keep the box in focus while typing** | Front end only (the `{p && …}` gate in `FixClose.tsx` unmounts the input on every keystroke). Prices to 2 decimals, a digit-by-digit Vitest test, and the same check on every other parent number box. | ½ session |
| 2 | **Agreement v2 ("matures")** | A migration adding the new agreement wording (data, no function). Must be live before the girls sign. | ½ |
| 3 | **TSX's Jan 1 holiday confirmed** | A one-line data migration (`confirmed = true`, source noted) plus a pgTAP test. See the note below. | rides with #2 |
| 4 | **The inflation switch, made obvious, plus the two Nov 8 wording nits** | A small read-only migration and the front end. | 1 |
| 5 | **A passed deadline shows on Home straight away** (approved Nov 24) | The greyed GIC card ("⏰ Time's up for this GIC…"), screen tests at 12:01 am, and pgTAP tests that the database already refuses. The database already refuses both deadlines found so far: `choose_maturity` from the start of `choice_ends`, and request approval after `expires_at` ("This request ran out of time on …"). **If the sweep finds a deadline the database doesn't refuse yet, that fix is a money-function change: it waits for block 2, and only the screen ships now.** | 1 |
| 6 | **Fixed trades labelled on the Graphs tab** | `fund_chart` (read-only) and the chart. | 1 |
| 7 | **The "record a market closure" screen** | Front end only: `record_market_closure` and `record_early_close` already exist and are tested (audit 3). | 1 |
| 8 | **Backups named by the Alberta date** | `backup.ts` line 243 only, plus a unit test. Ships in the backups repo, not the database. `sync-backup.ps1` is unchanged, so there's no review-and-install. | ½ |

**About 5½ sessions in 6 days.** That's tight but fits if Dad reviews each item the same day. If it slips, #7 waits for block 2 (RUNBOOK's "stop and ask" covers a surprise closure; during the freeze there are no real girls, and the test kid's trades would just wait) and #6 after it.

**Review points (Dad):** each item's plan before code; each item's diff, tests and screenshots before it merges; **Thu Dec 3 evening, the freeze candidate**: everything merged, `supabase test db`, `npm test`, end-to-end twice, `npm run rollback:check`, CI green on the exact commit (CI runs the time machine on every push; no local time machine run, since nothing here touches money); **Fri Dec 4**, the expected dry-run list.

**About TSX Jan 1.** The database already treats it as closed: `is_trading_day` uses every `closed` row, confirmed or not, so the dividend is due Jan 4 on both markets either way. `confirmed` only feeds the Dashboard warning "TSX holiday dates are confirmed only through …", which shows when the confirmed dates run out within 60 days. So confirming Jan 1 is not a money change and needs no time machine run, but it **is** a production change, so it goes in on Dec 5. After it, the next unconfirmed TSX date is Family Day, Feb 15, still within 60 days, so the warning will move to "confirmed only through Jan 1" rather than disappear. If Dad gives me the link to TSX's official 2027 calendar, the same migration can confirm all of 2027 against it (I won't mark dates confirmed without the source).

## 2. Block 2, after the freeze (Dec 24 – Dec 31)

About **6 sessions** realistically fit in those 8 days (Christmas included). Must-have first, then the slip list by value at launch:

| # | Item | Estimate | Fits? |
|---|---|---|---|
| 1 | **"Matured" in the maturity notice** (money: plan, known-answer test, local time machine to the cent). Changes only future notices; Nov 15's stays as it is. | 1 | **Must** |
| 2 | **Big market days: one note instead of repeats** (also stops a note being written from a close that's later fixed, like the Dow's Nov 20). The girls see these notes from day one. | 1 | **Fits** |
| 3 | **Recent alerts summary on the Dashboard + the safety net records that it fired.** This is how Dad watches the first month. The safety-net record is a new table and function, with grants and a test. | 1 | **Fits** |
| 4 | **"Why save? Why invest?" explainer cards** | 1 | **Fits** |
| 5 | **Reasons to tap on the reflection + the selling learning lines** (together) | 1 | **Fits** |
| 6 | **Monthly interest broken down by rate period + the statement by account** | 1½ | **Doesn't fit** |
| 7 | **"What's inside" + "How bumpy is the ride?"** | 1 | **Doesn't fit** |

**Fits: 1–5 (6 sessions). Doesn't fit: 6 and 7 (2½ sessions)**, which arrive after launch as "What's new" surprises. Neither touches money. Item 6 shows how existing interest was worked out, so it gets a known-answer test when it comes.

**Also in the Jan 2 batch (Dad, 2026-11-27, small and with item 1's review):**
- **(a) The agreement title shows "(version N)" only when she re-signs a changed agreement, never on her first one.** Today `agreement_render` adds it to any version after 1, so the girls' first agreement at launch would read "Your Big Bucks agreement (version 2)". A replacement of that read-only function, with a pgTAP test for both cases.
- **(b) The "Sign your Big Bucks agreement with Dad first" refusals become "with Mom or Dad".** They sit in `require_agreement`, which guards deposits and moves, so they wait for the money review.

**If Dad has Dec 6–8 at the PC:** building #4 and #5 then (on a branch, shipped Jan 2; nothing reaches production in the freeze) frees two sessions, so #6 fits too. That's Dad's call.

**Review points:** each item's plan and diff as in block 1. #1 gets Moose's plan review, since it's money. **Thu Dec 31, the release candidate**: everything merged, the full local suite, end-to-end twice, **`npm run timemachine` locally** (block 2 has a money change), `rollback:check`, CI green.

## 3. The two production sessions

Each step waits for Dad's OK before the next. Read-only checks can be done in the morning; nothing changes production before 11:45 am.

### Session 1: Sat Dec 5

**Morning (read-only):**
1. main is clean, equals GitHub, and CI is green on that exact commit.
2. **Rollback record:** `functions list` (expected unchanged: nightly v5, health v6, kid-login v2, download-backup v1; block 1 deploys no Edge Function) and the current Pages run number and commit.
3. **Withdrawal B:** check that Dec 4's run expired it and released its hold (ticks that box).
4. Fri Dec 4's run was clean: reconcile ok, no open alerts.
5. **Before leaving:** the GitHub token's expiry date (RUNBOOK, "Renew the GitHub token") must be after Jan 31, or the backups stop while Dad is away.

**After 11:45 am:**
1. Backup by hand; its counts recorded.
2. `db push --dry-run`: exactly block 1's migrations, listed in the Dec 4 review (agreement v2, TSX Jan 1, the inflation read-only function, `fund_chart`, and nothing else). Dad reviews.
3. `db push`, then "Remote database is up to date".
4. Deploy to GitHub Pages; confirm the live bundle is the new one.
5. Backups repo: the Alberta-date label, copied into big-bucks-backups and pushed.
6. **Read-only checks:** the agreement's version 2 is the current one; TSX Jan 1 is confirmed; the parent log has a row for each new parent action, if any; reconcile clean; no new alerts.
7. **Phone checks (Dad):** the inflation switch; Fix a close keeps the box in focus while you type a price (**open the box and type, but don't press yes**: a real fix would change a real close); the Graphs fixed-trade labels; the closure screen opens and its preview works (**don't record a closure**: it marks a real day closed); everything at phone, tablet and desktop sizes.
8. Backup by hand again; health check green. Done before 4:00 pm.
9. **That evening after 9:30 pm (read-only):** the nightly run is clean.
10. Sun Dec 6 7:00 am: the first backup labelled by the Alberta date, `Backup 2026-12-06`.

**Rollback:** Pages: re-run the previous deploy. The migrations are additive and safe to leave; a bad one is fixed by a new migration on Sun Dec 6 (quiet before 4:00 pm), never during the freeze. Backup label: revert the commit in big-bucks-backups.

### Session 2: Sat Jan 2

**Morning (read-only):**
1. **The Jan 1 run:** December's savings interest posted, no closes expected (both markets closed), no missing-price alert, reconcile ok.
2. main clean and equal to GitHub, CI green; the local release candidate results (with the time machine) from Dec 31.
3. **Rollback record:** function versions and sha256, the Pages run, the code commit, as on Nov 21.

**After 11:45 am:**
1. Backup by hand; counts recorded.
2. `db push --dry-run`: exactly block 2's migrations, listed on Dec 31. Dad reviews.
3. `db push`; up-to-date check.
4. Edge Functions only if block 2 changed one (the maturity notice and the notes job are in SQL, so none is expected). If one is deployed, its new version is confirmed active.
5. Deploy to GitHub Pages; confirm the live bundle.
6. **Read-only checks:** reconcile clean; no new alerts; the new alerts summary on the Dashboard; any new table has its grants (`explicit_grants_test` passed in CI).
7. Phone checks at the three sizes.
8. Backup by hand again; health check green. Done before 4:00 pm.
9. **Evening (read-only):** the nightly run is clean. **Sun Jan 3 evening as well.** If either shows a problem, roll back Sunday before 4:00 pm, so that Monday's dividend runs on known-good code.

The dividend job isn't touched in block 2, but Jan 4's dividend will then run on launch code, which is the code Dad wants proven.

## 4. The freeze and soak test (Dec 7–23)

- What runs by itself: 13 trading days of nightly runs (prices confirmed at 9:00 pm, settle, daily interest, notes, expiry, reconcile, badges), the morning backup and health check, and the missing-price alerts.
- No holiday or early close falls inside the freeze (the first is Dec 24), and no GIC matures (GIC #2 matures Jan 10, GIC #6 Apr 17).
- **Nothing in the freeze can cost a girl money**: the only account is the test kid. If an alert arrives on Dad's phone, note it and leave it. It's looked at on Dec 24, not fixed in the freeze.
- **The laptop copy pauses** while the laptop is off (`sync-backup.ps1` runs from Task Scheduler). Its 30-hour warning on the first run after Dec 23 is expected, and the copy catches up then. The GitHub backups carry on all through.
- **Dec 24 soak review (read-only):** every night's job runs ok once, every close matches the official close, reconcile clean every day, alerts raised and resolved, every backup present, the health check every morning.

## 5. Tests Dad can run now, on the test account

Each one ticks an open ACCEPTANCE box. Do them as the test kid on your phone, and as Dad on the parent app. The test kid has $95.18 in savings, units in all three funds, and GICs #2 ($20.00, 3-month, matures Jan 10) and #6 ($10.00, 6-month at 4.0%).

**Keep units in all three funds** (don't sell any fund to $0): the Jan 4 dividend needs them. And **don't break GIC #2**.

**A. Withdrawal B: start it TODAY, before 4:00 pm** (the 7-day expiry)
1. As the test kid: **Buy / Sell** → take money out of savings → **$5.00** → **Ask Dad**.
2. Check: the screen says it's waiting for Dad, and savings shows $5.00 held (available drops by $5.00).
3. As Dad: **don't** approve or decline it. Leave it alone for 7 days.
4. Before 4:00 pm today, so that Fri Dec 4's 4:30 pm run is the first one past its 7 days. If it's made later, it expires at Sat Dec 5's run instead, which still works.
5. I check on Dec 5 morning, read-only: status `expired`, the hold released, her notice, and the expiry job's run.

**B. Withdrawal A: the 24-hour wait** (start it today too)
1. As the test kid: a second withdrawal from savings, **$5.00** → **Ask Dad**. (Two can wait at once; there's no limit.)
2. As Dad, straight away: **Approve**. Expected: refused with "Withdrawals wait 24 hours before they can be approved. This one can be approved from …".
3. Sat Nov 28, after that time: **Approve**. Expected: $5.00 leaves savings and she gets a notice.
4. Write down the request number and both times.

**C. A deposit over the cap** (5 min)
1. As the test kid: **Buy / Sell** → put money in. Note the most the screen says she can put in.
2. Type 1¢ more than that → **Ask Dad**.
3. Expected: a clear message and no request created (Dad's Dashboard shows nothing new).

**D. Cashing out only through savings** (5 min)
1. As the test kid: **Buy / Sell**. Pick GIC #2, then each fund.
2. Expected: a GIC or fund only offers "move to savings"; taking money out is only offered from savings.
3. Back out without confirming anything.

**E. Breaking a GIC early** (5 min)
1. As the test kid: **Buy / Sell** → GIC **#6** → break it.
2. Expected: the early-break warning first. Confirm. $10.00 returns to savings, with $0 interest.
3. Write down the warning's words and the new savings balance.

**F. A declined request shows Dad's reason** (2 min)
1. As the test kid: **History** → request #11 (Oct 15, $50.00 deposit, declined).
2. Expected: Dad's reason, "Decline test", is shown. Also note whether Home's last-answer line shows it.

**G. "Something looks wrong?"** (10 min)
1. As the test kid: **History** → tap any line → **Something looks wrong?** → type a short question → send.
2. As Dad: the question shows on the Dashboard; reply to it.
3. As the test kid: the reply shows in her History.

**H. Five wrong PINs** (20 min; **do it once only**: a second lock within 24 hours lasts an hour)
1. Log out the test kid. Enter a wrong PIN 5 times.
2. Expected: the "take a break" message, with 15 minutes.
3. As Dad: an alert in the Dashboard's **Test accounts** fold (quiet, because it's a test account).
4. After 15 minutes: the right PIN works.

Tell me when each is done (with request numbers and times), and I'll check it read-only and tick the box with the evidence.

## 6. Tue Jan 5: the dividend check (read-only)

1. Mon Jan 4's run: `dividends` job ok once for 2027-01-04; reconcile ok; no alerts.
2. Three ledger rows, `dividend:2027Q1:dow`, `dividend:2027Q1:nasdaq100` and `dividend:2027Q1:tsx`, each into savings, none twice.
3. Each one recalculated by hand from the spec's rule (the value of her units × the fund's yearly yield ÷ 4, rounded up to the cent), using the units and the close the job used. Each must match to the cent, along with its "How was this calculated?" working.
4. Her notices and Home lines for the three dividends (Dad's phone).
5. Then ACCEPTANCE's dividend box is ticked with the live evidence.

## 7. Launch day: Sat Jan 9

**The girls see nothing before launch** (Dad, 2026-11-27):
- Their accounts don't exist until step 5 on Jan 9. Production has one account (the test kid) and two logins (Dad and the test kid), and "Allow new users to sign up" is off, so nobody can make an account from the app.
- **Mom's try-it, Dec 6:** on the test account, on a phone Dad hands her. She reads the app as a girl would, and Dad notes anything that confuses her. Fixes go into the Jan 2 batch. The test kid finished onboarding in October, so the try-it shows the everyday screens, not the first-sign-in steps. To try those too: a fresh account on Dad's laptop (local, nothing on production), at phone size.
- **The install check on a girl's phone, without her:** install from the live site, check it opens full screen from its icon and appears in the app list, and that Family Link doesn't hold it. Don't sign in. Then uninstall it and clear the site's data in Chrome (Settings → Site settings → All sites → the Big Bucks site → Delete data), so nothing is left on her phone until Jan 9.
- **Elsewhere:** the test kid's app on Dad's phone, and the GitHub Pages address in his browser history, are worth keeping out of sight too.

**Ready before the day (Jan 5–8):**
- [ ] Every section 5 box ticked; the dividend box ticked on Jan 5.
- [ ] ACCEPTANCE reviewed box by box: only the girl-dependent ones are open.
- [ ] `prelaunch_reset()` rehearsed on a local restore of production's latest backup, showing exactly what it removes and keeps (SPEC: it clears the test history; it keeps every account and login, rates, settings, holidays, funds, prices, corrections, notes, job runs and the parent log).
- [ ] Dad's fresh read-only audit since the third pre-launch audit.
- [ ] The setup script ready on the laptop, with the girls' usernames and PINs typed only at runtime (never in the repo).
- [ ] The girls' phones charged, with Big Bucks installable (the Dec 6 install check passed, and the app removed again so she hasn't seen it).
- [ ] This checklist copied into RUNBOOK's "The pre-launch reset (Stage 12)" in the Jan 2 batch.

**On the day** (one step at a time; Dad says OK after each):
1. **Morning, read-only:** Fri Jan 8's run was clean (reconcile ok, no open alerts); the morning backup and health check green; "The project has never paused" checked and ticked.
2. **After 11:45 am: backup by hand.** Record its counts. The reset needs a backup **from the last 2 hours** whose counts match every table it clears, so steps 2 and 3 happen back to back, with nothing done on the test account in between.
3. **`prelaunch_reset('clear the test history')`**: the database owner, in the SQL Editor (never with a sign-in). Then read-only: the cleared tables are empty, the kept ones are unchanged, and there's one row in `prelaunch_resets`.
4. **`launched_at` set.** Then check that `prelaunch_reset` now refuses.
5. **The girls' accounts** with the setup script.
6. **Every phase 2 feature switched to "Everyone"** in Settings.
7. **Each girl, one at a time:** install on her phone, log in with her username and PIN, onboarding, the agreement (version 2, "matures") signed by her and countersigned by Dad.
8. **The deposit cap:** if Dad wants a different starting cap than $1,000, change it now. Both girls get the notice, which ticks that box. Otherwise it's ticked the first time it changes.
9. **Read-only:** reconcile clean for both girls; no alerts; the parent log has every step.
10. **Backup by hand again; health check green. Done before 4:00 pm.**
11. **Evening after 9:30 pm, read-only:** the first nightly run after launch is clean.
12. **Sun Jan 10 morning:** backup and health check green. **Stage 12 is done.** Then the first monthly money meeting.

**If something goes wrong on the day:** stop at that step. Before step 3, nothing has changed. After step 3, the hand backup from step 2 is the way back (RUNBOOK, "Rebuilding production from a backup"). After step 4, `prelaunch_reset` can never run again, so a mistake is fixed with correcting entries, as always.

## 8. After launch (not scheduled yet)

- **The database suite fails loudly if it runs short (Dad, 2026-11-27).** Run on a database the demo or the end-to-end tests have just loaded, `supabase test db` gives about 1,549 tests instead of 2,386 and says FAIL in among the output. That's easy to misread as a real result. The fix: a wrapper (`npm run test:db`) that resets the local database first, then fails with a plain message if the total is below the expected count, with the expected count kept in one place in the repo and raised whenever tests are added. CI uses the same wrapper. Test tooling only; no money logic.
