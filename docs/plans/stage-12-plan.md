# Stage 12 plan (draft for Dad's review, 2026-11-24)

Status: **proposed, not approved.** Nothing here is built yet. The launch date is set once Dad gives his travel dates.

## 1. Tests Dad can run now, as the test kid (no build needed)

These close the open phase 1 ACCEPTANCE boxes that wait on nothing but a test. Start them now: the expiry needs 7 days.

| Box | The test | Takes |
|---|---|---|
| Five wrong PINs lock the login for 15 minutes and alert Dad | 5 wrong PINs on the test kid's login; the lock message; a try after 15 minutes works; the alert is in the Dashboard's "Test accounts" fold (quiet for a test account). Production has 7 logins and no failed one so far. | 20 min |
| A declined request shows her Dad's reason | Look at the test kid's history for request #11 (declined Oct 15, reason "Decline test") and Home's last-answer line. The data is there; nobody has recorded seeing it on her screen. | 2 min |
| A deposit over the cap is blocked with a clear message | Ask for a deposit just over what the $1,000 cap allows; the message, and no request created. | 5 min |
| Cashing out of a GIC or fund requires moving it to savings first | On Buy / Sell, a GIC and a fund only offer "move to savings"; a withdrawal is only offered from savings. | 5 min |
| A withdrawal waits 24 hours before Dad can approve it | Withdrawal A (for example $5.00): Dad tries to approve at once (refused, with when he can), then approves after 24 hours; it leaves savings. | 2 days |
| An unanswered request expires after 7 days and releases the held money | Withdrawal B, left alone: its $5.00 held, then released at the nightly run 7 days later. #13 (Oct 15 → Oct 22) proved the expiry, but it was a deposit, which holds nothing. | 7 days |
| Breaking a GIC early shows the warning, returns the principal and pays no interest | Break GIC #6 (6-month, $10.00 at 4.0%, opened Oct 17): the warning, $10.00 back, $0 interest. (#2 stays, so its Jan 10 maturity is still seen.) | 5 min |
| "Something looks wrong?" sends Dad a question, and his reply shows in her history | Send one as the test kid; Dad replies; it shows in her history. Production has no question yet. | 10 min |

## 2. Before launch: must-have

In this order (Dad's Nov 16 order kept for items 1 and 2; the money and safety items next):

1. **The inflation switch, made obvious** (Stage 12 item 1). One small read-only migration and the front end. About 1 session.
2. **Fixed trades on the Graphs tab** (item 2). `fund_chart` only. About 1 session.
3. **"Matured" in the maturity notice**: a money-function change to the nightly maturity job (plan, known-answer test, time machine). About 1 session.
4. **The agreement says "matures"**: a new agreement version before the girls sign. About ½ session.
5. **A passed deadline shows on Home straight away** (approved Nov 24): the greyed GIC card, the database refusing a choice from the deadline (already true for GICs; tests added), and the same for every other deadline the evening run acts on. About 1 session.
6. **Fix a close: keep the box in focus while typing**, 2-decimal prices, a digit-by-digit test, and the same check on the other parent number boxes. About ½ session.
7. **The "record a market closure" screen** (`record_market_closure`, `record_early_close`). Planned holidays are already in `market_holidays` (confirmed through Jan 1; TSX's Jan 1 still unconfirmed), so this is for a surprise closure; until it exists, RUNBOOK says "stop and ask". About 1 session.
8. **Backups named by the Alberta date** (proposal in section 4). About ½ session, plus Dad's review.
9. **Two inflation wording nits** (Nov 8). A few minutes; ride along with item 1.

Then, by Dad: **the install check on a girl's phone** (Family Link), **Dad's fresh read-only audit** of everything since the third pre-launch audit, and **a try-it session with each girl** (fix what confuses her before launch).

**About 7½ build sessions** (one evening or one Saturday each), plus Dad's review of each and one production session (a Saturday after 11:45 am) for the migrations and Pages. Realistically **2½–3 weeks** of calendar time.

## 3. Can slip to after launch

Read-only learning and convenience features; none touches money, and each can arrive later as a "What's new" surprise:

- big market days, one note instead of repeats (item 3; it also fixes the stray Dow note from Nov 20, written on the old wrong close);
- "Why save? Why invest?" cards (item 4);
- each month's interest broken down by rate period, and the statement by account;
- "What's inside" and "How bumpy is the ride?";
- reasons to tap on the reflection; the selling learning lines;
- the "recent alerts" summary on the Dashboard; the safety net recording that it fired.

About 6–8 more sessions in all.

## 4. Backups named by the Alberta date (proposal; nothing changed)

- **Today:** the commit message is `Backup ${taken_at.slice(0, 10)}: …` (`ops/backup-repo/scripts/backup.ts`, line 243), and `taken_at` is UTC. A backup after 6:00 pm Alberta (00:00 UTC) gets the next day's label: GitHub's late backstop on Nov 24 at 8:45 pm committed "Backup 2026-11-25".
- **Change:** label by the Alberta date (UTC−6 all year, the same rule `sync-backup.ps1` already uses), for example a small `albertaDate(taken_at)` helper with a unit test (8:45 pm on Nov 24 → "2026-11-24"; 7:00 am → the same day). `counts.json` keeps `taken_at` in UTC, unchanged.
- **Nothing depends on the label:**
  - `sync-backup.ps1` shows the subject in `last-sync.txt` but works out its own dates from the commit time in Alberta time; its 30-hour age warning uses the commit time. **No change, so no review-and-install.**
  - `npm run restore:drill` and RUNBOOK's restore steps read the `backup` folder (`counts.json`, the dump), never the commit message.
  - The backstop's "fresh" check uses the newest bot commit's age (under 12 hours), not its label.
- **Old commits keep their labels** (history isn't rewritten). From the change on, two backups on one Alberta day (the 7:00 am start and a late backstop) share a label; the commit time tells them apart.
- **How it ships:** in Big-Bucks `ops/backup-repo/`, then copied into big-bucks-backups and pushed, as for earlier backup changes, outside 7:00–11:45 am.

## 5. Launch

**Rules for the date:** a Saturday (or a quiet weekday Dad picks), after 11:45 am and finished before 4:00 pm; not the 1st, a month's end, a dividend day (Jan 4) or a GIC maturity day; not a market holiday. If launch is before Jan 4, the dividend box is ticked from the time machine (17 dividends to the cent, green on every push), as ACCEPTANCE allows.

**Before the day:** every box in section 1 ticked; section 2 done and in production; "Every box above is ticked" checked box by box (those waiting on the girls are ticked on the day); `prelaunch_reset()` rehearsed on a local copy of production's latest backup, showing exactly what it removes and keeps; the launch-day checklist written in RUNBOOK.

**On the day** (one step at a time, waiting for Dad after each):
1. Confirm the checklist; "The project has never paused" ticked.
2. Backup by hand; its counts recorded.
3. `prelaunch_reset('clear the test history')` (database owner, SQL Editor).
4. `launched_at` set.
5. The girls' real accounts with the setup script (no names in the repo).
6. Every phase 2 feature switched to "everyone".
7. Each girl: install on her phone, log in with her username and PIN, onboarding, the agreement (version 2, "matures") signed and countersigned.
8. "A deposit-cap change reaches both girls with a notice": ticked the first time Dad changes the cap after launch (or on the day, if he wants a different starting cap than $1,000).
9. Backup by hand again; health check green.
10. **Done when the first nightly run after launch is clean**: reconcile ok, no alerts, the next morning's backup and health check green. Then the first monthly money meeting.
