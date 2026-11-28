# Block 1 plan: Stage 12 items 2–7 (for Dad's review, 2026-11-27)

Status: **approved by Dad 2026-11-27, with three additions** (the full agreement v2 text read by Dad before item 2 is built; item 4's wording fits each kind of request; screenshots of kid-facing wording in each report). Item 1 (the Fix a close focus bug) is on its own branch, `fix-close-focus`.

Ships in **production session 1, Sat Dec 5** (`docs/plans/stage-12-plan.md`, section 3). **No money-function changes**: no change posts, moves, rounds or calculates money, rates, interest, dividends, trades, expiry or the nightly jobs. The only database changes are two data migrations (the agreement text, and a holiday flag) and replacements of read-only functions and a view. Every change is a new migration; none edits a committed one.

## How it's built

- **One branch, `block-1`, in its own worktree** (`../bb-block-1`), cut from main after `fix-close-focus` merges. One commit per item, each with its tests passing.
- **A short report after each item:** what changed, the tests and screenshots at phone (360 px), tablet and desktop sizes, and anything for Dad to look at. **Every report includes screenshots of any kid-facing wording** (the agreement, the inflation switch, the deadline cards, the Graphs labels), which Dad reviews at his evening check-in. Then I go straight on to the next item unless Dad says stop.
- **Order:** Dad's list, except the backup label moves up to fourth. That way the two items to drop if the week runs short (the closure screen, then the Graphs labels) come last:
  1. agreement v2 and TSX Jan 1;
  2. the inflation switch and the two nits;
  3. the passed-deadline card;
  4. the backup label;
  5. the Graphs labels;
  6. the closure screen.
- **The flaky Approvals layout test (Dad, 2026-11-27).** `layout.spec.ts` "parent screens fit at tablet-portrait" timed out once clicking **Answer** (passed in four full runs). If it fails again in any run, it gets fixed, not retried.
- **Thu Dec 3, the freeze candidate:** everything merged to main, then:
  - `supabase test db`, `npm test`, lint and types;
  - end-to-end twice from fresh demos;
  - `npm run rollback:check`;
  - CI green on the exact commit;
  - the local time machine run once for item 2, because its script changes (how the made-up kids sign).

  Then the expected `db push --dry-run` list, for Dad's review on Fri Dec 4.

## Item 2: agreement version 2 ("matures"), and TSX Jan 1 confirmed

**Before building:** Dad reads the full version 2 text end to end (approved 2026-11-27).

**What Dad and the girls see.** In rule 🔒 "A GIC is a promise.", "When a GIC finishes, you have 7 days to choose what's next…" becomes "When a GIC **matures**, you have 7 days to choose what's next…" (with the **?** for "Matures", as on her other screens). **This is the last free chance before the girls sign.**

**Mom or Dad (Dad, 2026-11-27):** "Mom or Dad" wherever it's about reading, talking or asking; "Dad" only where it's something only his parent sign-in can do (saying yes, countersigning, answering in the app, fixing). In version 2 that changes three places: the intro ("Read them with Mom or Dad… When you agree, you sign, and then Dad signs too."), rule 🔑 ("tell Mom or Dad") and the sign line ("I've read these rules with Mom or Dad, and I agree."). Two onboarding lines around the agreement follow the same rule: the Home banner "Let's set up your Big Bucks with Mom or Dad." and the changed-rules banner "…Read your new agreement with Mom or Dad and sign it." Every other "Dad" stays. The full text is in Dad's review message of 2026-11-27, and must be approved before item 2 is built.

**Database:** migration `…_agreement_v2.sql`:
- Inserts version 2: version 1's promises word for word, the intro, rule 🔑 and sign line with "Mom or Dad", and rule 🔒 with "matures". `agreement_versions` is append-only and takes inserts, so no guard is switched off.
- Calls `agreement_changed_notices(2)`. On production that tells only the test kid, "Your Big Bucks agreement has changed".
- **Effect on the test account from Dec 5:** her version 1 signature still covers everything except new deposits. She sees the Home banner asking her to sign version 2, signs it, and Dad countersigns. That is the real re-sign path, tested live before the girls ever need it. Do **test C (a deposit over the cap)** before Dec 5, so it isn't mixed up with the re-sign.
- At launch, `prelaunch_reset` clears every signature, and the girls sign version 2 from the start.

**TSX Jan 1:** migration `…_tsx_2027_new_year_confirmed.sql`:
- `update market_holidays set confirmed = true, source_url = 'TSX is closed every Jan 1 (Dad, 2026-11-27)' where market = 'tsx' and holiday_date = '2027-01-01' and kind = 'closed'`, checking exactly one row changed.
- `is_trading_day` ignores `confirmed`, so trading days, settlement and dividend dates don't move. Only the Dashboard's holiday warning changes, to "confirmed only through Jan 1", because Family Day (Feb 15) is still unconfirmed.
- If you send TSX's official 2027 list, the same migration confirms the whole year instead.

**Tests:**
- **The test helpers sign the latest version.** About 30 pgTAP files, `scripts/local/demo.ts` and the time machine's `run.ts` sign version 1 by number today. They will sign "the latest version" instead: one mechanical change per helper, with no test's meaning changed.
- **`onboarding_test`:** version 2 word for word; version 1 kept unchanged; a girl who signed version 1 is told and is asked to sign version 2 before her next deposit; everything else keeps working.
- **New pgTAP checks for TSX:** Jan 1 confirmed, the trading days unchanged, and the warning's new wording.
- **Vitest and end-to-end:** the onboarding agreement screen shows version 2.
- `docs/MESSAGES.md` §11 updated.

**Estimate:** ½ session, plus about ½ for the test-helper change.

## Item 3: the inflation switch, made obvious, plus the two Nov 8 nits

As approved on Nov 14 (PROGRESS, Stage 12 item 1).

**What she sees (detailed mode only, remembered per device, as now):**
- **The button:** "🛒 Will my money buy as much next year?" with a tag: **Show** when off, **Hide** when on (`aria-pressed` kept).
- **When on:** under the button, "The 🛒 lines on your cards show what your money could buy later on. Tap again to hide them." Each added line starts with 🛒 instead of 💡 (💡 stays for Buy / Sell tips).
- **The Total card**, with her own figures instead of today's general note: "Prices go up about {rate}% a year, so if it didn't grow at all, next year your {total} would buy about what {real} buys today. Growing your money is how you keep up. That's why GICs and funds matter."
- **Nit (a):** "at today's 1% savings rate" becomes "1.0%", the same rate format as everywhere else (`formatRate`).
- **Nit (b):** the Inflation **?** gains "At 1.0%, your savings grow to about $75.95, about 67¢ behind prices."

**Database:** migration `…_inflation_total.sql`, read-only functions only:
- `kid_inflation` also returns her total and what it would buy ({real}), worked out in the database and rounded to the nearest cent, like the savings line's "buys about what…" figure.
- `kid_rate_help` also returns her savings in a year and the gap to prices for nit (b). The browser never does the subtraction (money rule 3).

**Front end:** `Inflation.tsx`, `learnText.ts`, `rateHelp.ts`, `Learn.css`; MESSAGES updated.

**Tests:**
- **pgTAP known answers:** a $95.18 total at 2.0% inflation gives the database's {real}, to the cent; the gap figure; basic mode and the switch off still return nothing.
- **Vitest:** every wording, including "1.0%".
- **End-to-end:** Show/Hide and the 🛒 lines, at the three sizes and with large text.

**Estimate:** 1 session.

## Item 4: a passed deadline shows on Home straight away (approved Nov 24)

**The deadlines the evening run acts on.** There are two:
- **A matured GIC's choice:** `choice_ends`, then the run's auto-move.
- **A request's 7 days:** `expires_at`, then the run's expiry.

The database already refuses both from the deadline itself, not from the run:
- `choose_maturity`: "The 7 days to choose are over…";
- `approve_request`: "This request ran out of time on …".

So nothing that acts on money changes. Before building, I'll recheck every other job the run does (settle, monthly, gic_maturity, dividends, splits, notes, rate notices, badges) for a deadline she or Dad can act on. **If I find one the database doesn't refuse yet, I stop and tell you: that would be a money-function change and waits for block 2.**

**What she sees:**
- **The GIC card,** from the midnight after the deadline until the run: "⏰ Time's up for this GIC. Your {amount} goes into your savings tonight." The card stays visible, with "Choose what's next" greyed out and not tappable. The choice screen opened from an old link says the same.
- **A request past its 7 days,** on her Buy / Sell waiting list, worded for its kind (Dad, 2026-11-27). Only deposits and withdrawals wait for Dad and expire; a buy or sell waits for the close, never for Dad, so it never expires.
  - **A withdrawal** (its money is held): "This request ran out of time. It will be cancelled tonight, and its money is no longer on hold after that." (The hold is released by the run, so it says "after that", not "now".)
  - **A deposit** (holds nothing): "This request ran out of time. It will be cancelled tonight."
- **Dad's Approvals,** with Approve and Decline greyed out:
  - **A withdrawal:** "Ran out of time on {date}. It will be cancelled tonight, and the {amount} she had on hold goes back to her then."
  - **A deposit:** "Ran out of time on {date}. It will be cancelled tonight."

**Database:** migration `…_passed_deadlines.sql`, read-only:
- The `gic_positions` view gains `choice_over` (`app_today() >= choice_ends`). Its grants are restated in the same file, and its row is checked in `explicit_grants_test`.
- `kid_trade_options` and the parent approvals read gain `expired` (`expires_at <= app_now()`) on each waiting request.
- The time comes from the database (`app_today()` / `app_now()`), never the phone's clock, so the time machine and the local clock agree.

**Tests:**
- **pgTAP:** a choice at 12:01 am the day after the deadline is refused while the GIC still waits for the run (as Dad asked), and `choice_over` is true then and false at 11:59 pm before. An approval one minute after `expires_at` is refused while the request still says waiting, with `expired` true.
- **End-to-end with the local clock:** the greyed card at 12:01 am; the run moves the money; the card goes. The same for a request on both screens.

**Estimate:** 1 session.

## Item 7 (built fourth): backups named by the Alberta date

As proposed on Nov 24 (`stage-12-plan.md`, the Nov 24 draft's section 4).

**Changes:**
- In `ops/backup-repo/scripts/backup.ts`, an exported `albertaDate(takenAtUtc)` (UTC−6 all year, the same rule as `sync-backup.ps1`) replaces `taken_at.slice(0, 10)` in the commit message.
- `counts.json` keeps `taken_at` in UTC.
- `sync-backup.ps1` is not touched, so there's no review-and-install.

**Tests:** in `backup.test.ts`, run by `npm test`: 8:45 pm on Nov 24 Alberta (02:45 UTC on Nov 25) gives `2026-11-24`; 7:00 am gives the same day; 11:59 pm and 12:00 am fall on either side of midnight; the message is unchanged apart from the date.

**Ships Dec 5:** copied into big-bucks-backups and pushed, outside 7:00–11:45 am. The first new label is the Dec 6 7:00 am backup.

**Estimate:** ½ session.

## Item 5: fixed trades labelled on the Graphs tab

As approved on Nov 16 (PROGRESS, Stage 12 item 2).

**What she sees:**
- **A fix added units or money:** "You bought $10.00 at $523.33 · price fixed **?**".
- **A sale where she kept the better price:** "You sold $20.00 at $650.10 · price fixed, you kept the better price **?**".
- **The **?**:** "The price Big Bucks first used for this day was wrong. Mom and Dad fixed it, and you got everything you were owed. Your notice has the details."
- The table's "You" column and the graph's pop-up say the same.
- A fixed sale of everything includes the money the fix added.

**Database:** migration `…_fund_chart_fixed_trades.sql`, a new version of the read-only `fund_chart` that reads each trade's correction lines (`fix:close:<fund>:<day>:<request>…`). No table, grant or nightly change.

**Front end:** `graphText.ts`, `Graphs.tsx`; MESSAGES §10.

**Tests:**
- **pgTAP known answers:** a fixed buy shows the fixed close and its tag; a fixed sale of everything shows the added money; a sale where she kept the better price.
- **Vitest** for the words.
- **End-to-end** at the three sizes.
- **On production after Dec 5:** the test kid's #17, #35 and #37 show the fixed closes (518.92, 647.05, 523.33).

**Estimate:** 1 session. **Second to drop**, to January, if the week runs short.

## Item 6: the "record a market closure" screen

**What Dad sees:** Dashboard → **Record a market closure** (next to Fix a close; RUNBOOK's "A close is missing" points here). He picks:
- the market (New York or Toronto);
- the day;
- **Closed all day** or **Closed early at** {time, Toronto time};
- a note (required).

Then a preview, the same pattern as Settings: the trades that will move to the next close, each girl's notice word for word, and the log line. Then **Yes, record it**.

The database's refusals show as written, for example:
- "There's already a close for … on …, so the market was open that day.";
- "Dividends were already paid on …".

**Database:** migration `…_closure_preview.sql`:
- **`parent_change_preview` gains two actions,** `record_market_closure` and `record_early_close`. Each runs the real function and rolls it back with `in_preview()` on, the same way the other Settings previews already work. Neither reaches outside the database.
- **`record_market_closure` and `record_early_close` are unchanged.** They already exist, already log to `parent_actions`, and are already tested (audit 3).

**Tests:**
- **pgTAP:** the preview changes nothing (holidays, requests, notices and the log the same after); it shows the same notices the real call writes; it refuses what the real call refuses.
- **End-to-end:** a closure recorded locally on a day with a waiting buy; the buy moves to the next close and she's told.

**On production:** Dad opens it and looks at a preview, but **doesn't record anything**, because recording marks a real day closed.

**Estimate:** 1 session. **First to drop**, to January, if the week runs short. Until it exists, RUNBOOK's "stop and ask" stays the rule.

## The Dec 5 dry run should list exactly these migrations

1. `…_agreement_v2.sql`
2. `…_tsx_2027_new_year_confirmed.sql`
3. `…_inflation_total.sql`
4. `…_passed_deadlines.sql`
5. `…_fund_chart_fixed_trades.sql` (unless dropped)
6. `…_closure_preview.sql` (unless dropped)

**No Edge Function changes.** The nightly stays v5 and health stays v6. The backup label ships in the backups repo, not by `db push`.

## Totals

About **5½ sessions**, plus ½ for the agreement test helpers, from Nov 28 to Dec 3. With the two droppable items left out, about 4.
