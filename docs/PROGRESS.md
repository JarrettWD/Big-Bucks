# Big Bucks — Progress log

Claude Code updates this file at the end of every stage. Newest stage at the top.

## Status

- Current stage: **stage 8 in progress**, local only. Part A is committed; Part B runs in four parts (B1–B4), each stopping for Dad's review. B1 and "View as <kid>" are committed. B2 (Settings, with the 7-day notice rule and Cancel) is committed. B3 (Fix a mistake) is committed. **B4: the kid wording is drafted in MESSAGES.md §11, waiting for Dad's review**; the screens come after.
- Build order (changed 2026-10-03, screens first): stages 6 → 7 → 8 against the local database only, then 4 → 5 (live setup), then the solo beta. Deploy, phone install and real accounts move to after stage 4. Phase 1 is complete when stage 5 is done. See "Build order" in `docs/BUILD-PLAN.md`.
- **The girls' devices:** a Samsung Galaxy A17 phone and Samsung Galaxy tablets, all Android with Chrome. Every layout must work on both the phone and the tablets (portrait and landscape), and every stage checks both.
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

### Stage 4 — Live setup (not started; comes after stage 8)

- **Dad's rule (2026-10-04):** "Before creating real accounts or any real deposit: run an independent pre-launch audit of the whole money engine and security setup (fresh agent, read-only), fix findings, then proceed."

### Stage 8 — Parent screens, settings and onboarding, local only (started 2026-10-03)

- **The plan Dad approved (2026-10-03):**
  - **Part A, the Approvals screen** (deposits, withdrawals and "Something looks wrong?" questions), then stop for Dad's review.
  - **Part B, the rest:** the dashboard, settings (rates, specials, cap, inflation, yields, feature switches, notes and glossary wording, the Download backup button placed but off until stage 5), onboarding with the account agreement and "What's new", and **Fix a mistake**.
  - **Phone first:** Dad mostly uses a Samsung S26 phone, sometimes a PC. Every screen still follows the screen-size rule.
  - **Every parent action that changes money or rates** shows a summary and a confirmation first, and is recorded with who did it and when.
  - Parent wording can be plainer; anything the girls see as a result goes in MESSAGES.md.
  - The demo data fills the screens.
- **Dad's additions at approval:**
  1. **Previews never cause anything outside the database,** now or later (for example push notifications in a future stage). A test enforces it, and CLAUDE.md tells future notification code to skip previews.
  2. **Recreating the parent functions changes nothing except adding the log row,** with a test or diff check proving behaviour is otherwise unchanged.
  3. **Fix a mistake (Part B):** from any history line and from a question. Corrections can go either way, but each is a new linked entry (never an edit), has a note she can read, rounds in her favour, needs an extra confirmation when it reduces her balance, and can never take savings below zero. Known-answer tests first, plus a time machine run.
- **Part A, the Approvals screen: built, waiting for Dad's review (2026-10-03).** Not committed yet.
- **Migration `20261011000000_parent_audit_approvals.sql`** (new):
  - **`parent_actions`, the log of every parent action:** who (`done_by`), when (`done_at`, from `app_now()`), what, which kid, the request, question, rate, setting or alert it was about, a plain-English summary and the details (note, reason, answer, new rate…).
    - Append-only for every role, the database owner included (the same triggers as the ledger).
    - Only the parent with the code can read it; kids can't, even about themselves.
    - It stores the user id, so Mom's login (version 2) shows as her.
  - **The six parent actions are logged without being changed** (Dad's addition 2):
    - `approve_request`, `decline_request`, `answer_question`, `acknowledge_alert`, `add_rate` and `set_setting` were **renamed** to `…_unlogged`, not edited. Their bodies are byte for byte what stages 2 and 3 committed.
    - A new function with the same name, arguments, defaults, result and security settings calls the committed one, then writes one log row, in the same transaction. If the action is refused, nothing is logged.
    - Nobody can call the `…_unlogged` functions directly, so nothing can skip the log.
  - **Previews stay inside the database** (Dad's addition 1):
    - `in_preview()` is true while a preview's dry run is running.
    - `move_preview` (Buy / Sell) is wrapped the same way (renamed to `move_preview_unflagged`, body unchanged) and turns the flag on for its dry run.
    - **CLAUDE.md** (Security rules) now says: anything that reaches outside the database (push notifications, email, HTTP via pg_net or an Edge Function) must check `in_preview()` and do nothing in a preview; never use a Supabase database webhook for it; any new preview turns the flag on. It also says every parent function writes one log row.
  - **`parent_inbox()`:** everything the Approvals screen shows. Every amount, date and time comes from the database:
    - deposits and withdrawals waiting, real kids first, then test accounts, oldest first;
    - when each was asked, the 24-hour unlock time and the seconds left, when it expires and the seconds left;
    - for a deposit: the cap, money put in so far, deposits waiting and room left;
    - for a withdrawal: savings, on hold and free to use;
    - savings after approving;
    - open questions, with the history line they're about (the kid's own `my_activity` line, including its "How was this calculated?" working);
    - the latest 20 decisions from the log, with who and when.
  - **`parent_decision_preview(kind, id, text)`:** what approving, declining or answering would do.
    - It runs the real (logged) action with `in_preview()` on, captures the notices she'd get and the log line, then always rolls it all back.
    - A rule the action would break comes back as the action's own message.
    - Kids and a parent without the code are refused outright.
- **The screen (`src/parent/approvals/`):**
  - **Tabs:** Dashboard · **Approvals** (with the number waiting) · Settings, at the bottom on phones and along the top from 720 px.
  - **Approvals:** "Deposits and withdrawals", then "Questions" (side by side from 960 px), then "Recent decisions".
    - **Each request card:** the amount, the kid (test accounts tagged **Test**), when she asked, and the money behind it. A withdrawal inside its 24 hours shows "🔒 24-hour wait: you can approve from Oct 4 at 10:38 pm (in 23 h 59 min)", and its **Approve** stays off. The countdown counts the database's seconds; when it runs out, the screen asks the database again. The expiry date turns bold in the last 24 hours.
    - **Approve:** the summary ("Approve Robin's $50.00 deposit?"), the cash reminder with her savings before and after ("Only approve once you have Robin's $50.00 in cash… $402.70 → $452.70"), an optional note, **Robin will see:** with the real notice, then **Yes, approve $50.00** or **Back**.
    - **Decline:** a reason is required; the button stays off until there is one, and she sees it in the preview.
    - **Answer:** her question, the line it's about with its working, your answer, the preview, then **Send answer**.
    - **The button only works once the preview matches exactly what's typed,** so you confirm what you saw.
    - **After each decision:** "Done. Approved Robin's $50.00 deposit. Recorded: Dad, Oct 3 at 10:39 pm."
  - **Wording:** parent wording is in `approvalsText.ts`. The girls' notices didn't change; MESSAGES §1 now explains that Dad's note, reason or answer appears exactly as typed, and that he sees the preview first.
  - **Also fixed, found by the tests:** when Dad finishes the code step on one device, Supabase ends his other half-finished sign-ins. The code screen used to say "That code didn't work" forever on the other device. It now says the sign-in has ended and to tap **Cancel and sign out**, then sign in again.
- **Demo additions:** a $10 withdrawal from Robin past its 24 hours (ready to approve), a $5 withdrawal asked for at the moment the demo finishes (a live countdown), and an open question from Robin about her September interest line. Sky's $15 withdrawal is the test-account request. Every earlier demo decision now shows in "Recent decisions" as Dad's.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **824 of 824**, after `supabase db reset`. That's 769 before, plus 54 new in **`parent_approvals_test.sql`**, plus 1 in `rls_test.sql` (a kid can't see the log). `schema_test.sql` and `rls_test.sql` know the new table.
    - **Unchanged behaviour:**
      - the md5 fingerprints of the six committed bodies and `move_preview`'s, taken before the migration ran;
      - each wrapper's arguments, defaults, result and security settings match the original;
      - each wrapper calls the original exactly once and writes nothing itself;
      - the grants are as before;
      - refusals give the committed messages word for word;
      - all 769 earlier tests (which call these functions by name) still pass.
    - **The log:**
      - one row per action, with who, when (the app clock), the kid, the target and the summary;
      - refusals log nothing;
      - update, delete and truncate are refused for everyone;
      - a kid and a parent without the code see nothing, and a kid can't write to it.
    - **`parent_inbox`:** known answers at 3:30 pm for a 10:00 am withdrawal: unlocks in 66,600 seconds (18 h 30 min), expires after 7 days, the cap and balances, savings after ($60.00 or $105.00), the open question with its line, recent decisions newest first. Who may call it.
    - **`parent_decision_preview`:** leaves nothing behind (no decision, notice, ledger line, log row or released hold); its notice and log line are word for word what the real action then writes; problems come back as the real messages; a kid is refused.
    - **Previews never reach outside the database:**
      - A stand-in for future outside-world code (a trigger that refuses to run unless `in_preview()` is true) proves both previews run their dry runs with the flag on and the real actions with it off.
      - The flag is off again afterwards.
      - A guard fails if any function that makes an HTTP call skips `in_preview()`, or if any table has a database webhook.
  - `npm test` (Vitest): **167 of 167** (5 new in `approvalsText.test.ts`: the countdown and its rounding, card facts, the unlock and expiry lines, and the confirmation wording).
  - `npm run test:e2e` (Playwright): **52 of 52**.
    - **New `approvals.spec.ts`**, in its own Playwright project that runs after the kid tests, because it changes Robin's requests. Each test is checked against the database:
      - **the screen matches the database:** what's waiting, the counts, the tab's "N waiting", and the 24-hour lock with the database's own time;
      - **approving a withdrawal:** going **Back** changes nothing; the summary shows her savings before and after; the note shows in the preview; then the ledger line, the request, her notice (word for word the preview) and the log row (Dad, the request);
      - **declining:** **Yes, decline** stays off until there's a reason; then the request, no ledger line, her notice and the logged reason;
      - **answering:** her line and its working are shown; then the question, her notice and the log row.
    - **`layout.spec.ts`:** the Approvals screen, an approval with its preview open, and an answer being written, at all six sizes with normal and 130% text: no problems.
    - **`parent.spec.ts`:** a new test for a sign-in ended on another device. Its tests now run one at a time.
  - `npm run timemachine`: **PASS, 14 of 14** (the parent functions it calls now go through the logged wrappers).
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable locally** (they're ticked live in the solo beta): "A deposit request holds the money, Dad approves it, and it lands in savings"; "A declined request shows her Dad's reason"; "A withdrawal waits 24 hours before Dad can approve it"; and Dad's side of "'Something looks wrong?' sends Dad a question, and his reply shows in her history".
- **Known issues and notes:**
  - **Previews skip ID numbers** on requests, notices and log rows, as Buy / Sell's previews already did. Nothing else is left behind.
  - **On one computer,** the kid and parent sign-ins share a browser, so use a normal window for a kid and an Incognito window for the parent (as in stage 6).
  - **The end-to-end tests reload the demo** (new PINs and a new parent password). Run `npm run demo` for a fresh set.
  - The Dashboard is still the stage 6 placeholder, plus a link to Approvals. It's built in Part B.
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run demo`, then `npm run dev`.
  2. Open an **Incognito** window in Chrome (**Ctrl+Shift+N**) and go to **http://127.0.0.1:5173/Big-Bucks/parent/login**.
  3. Press **F12**, then **Ctrl+Shift+M**, and pick a phone size.
  4. Sign in with `parent@demo.example`, the password the demo printed, and the code from `npm run demo:code`.
  5. Tap **Approvals**.
- **Follow-up the same night (Dad's request, not committed): nothing can skip the log.** The six renamed originals (`approve_request_unlogged`, `decline_request_unlogged`, `answer_question_unlogged`, `acknowledge_alert_unlogged`, `add_rate_unlogged`, `set_setting_unlogged`), plus `move_preview_unflagged` and the log writer `log_parent_action`, can only run inside their logging wrappers. No code changed: the migration already revoked every grant. These tests now prove it:
  - **Every role:** no role but the owner (`postgres`) may execute any of them. That covers `anon`, `authenticated` (kids and parents), `service_role`, `authenticator` and every Supabase role. Before, the test checked only three roles' privileges.
  - **Real calls, in the database** (`parent_approvals_test.sql`, section 7): each of the eight is actually called as a parent **with** the authenticator code, as a kid, as a signed-out visitor and as the server role. All 32 calls are refused with "permission denied for function …". The waiting deposit, the open question, the open alert, the ledger, notices, log, rates and settings are all unchanged.
  - **No other path:** a guard fails if any function anywhere in the database (outside the test schema) calls an original, except its own wrapper (and `log_parent_action` only from the six wrappers).
  - **Real calls, through the app** (`approvals.spec.ts`, first test): Dad signed in with the code, Robin signed in with her PIN, and a signed-out visitor each call the six originals through the Supabase API (`/rest/v1/rpc/…`). All 18 calls get 401 or 403 "permission denied for function …". Robin's withdrawal still waits, her question is still open, and nothing else changed.
  - **Mutation check:** I granted kids and parents EXECUTE on `approve_request_unlogged`, and added a function that called `decline_request_unlogged` directly, in the live local database. Five tests failed, as they should: the privilege checks, the "no other path" guard, and the real calls (the parent's direct approval went through). Then I rebuilt the database from empty.
  - **Results (2026-10-03):**
    - `npm run test:db`: **832 of 832**, after `supabase db reset` (8 new).
    - `npm test`: **167 of 167**.
    - `npm run test:e2e`: **53 of 53** (1 new).
    - `npm run timemachine`: **PASS, 14 of 14**.
    - `npm run lint` is clean and `npm run build` succeeds.
  - **`dev-5180`** stays in `.claude/launch.json` (Dad's choice): a second dev server on port 5180 for when 5173 is taken.
- **Part A committed** (`26949da`, 2026-10-04) after Dad's review. CI passed (test and timemachine).
- **The Part B plan Dad approved (2026-10-04):** four sub-parts, each followed by a stop for Dad's review.
  - **B1:** request expiry becomes a parent setting, plus the dashboard (described below).
  - **B2:** Settings: the rates screen with specials, preview and history; the cap, inflation, yields, expiry and feature switches; editing market-move notes and glossary wording; the Download backup button, placed but off until stage 5.
  - **B3:** Fix a mistake.
  - **B4:** onboarding, the account agreement and "What's new".
- **Dad's two additions:**
  1. **Request expiry is a parent setting:** default 7 days, allowed 3–30, changed from Settings with the usual preview, confirmation and log row. Each request's expiry is fixed when she asks; a changed setting applies only to new requests. Update SPEC, the glossary and any kid wording that says "7 days".
  2. **Dashboard warning** when any real kid's request expires within 48 hours, with dates worked out by the database. Test accounts' warnings are folded away like their alerts.
- **Dad's answers to the plan's questions:**
  1. Stop for review after each of B1, B2, B3 and B4.
  2. **Yes, tell the girls when request expiry changes,** with a short notice (for example "Dad now has up to 10 days to answer your requests"), sent when the change takes effect. The account agreement (B4) must use the current setting, not a fixed "7 days".
  3. **Corrections only in dollars,** into or out of savings.
  4. **Warning wording:** "expires tomorrow at 4:00 pm (in 29 hours)".
- **Design notes from the plan:**
  - Each request gets `expires_at` when she asks. The nightly expiry job, approving, the Approvals screen and the dashboard all use it.
  - Two of Part A's originals change on purpose: `approve_request_unlogged` (the expiry check) and `set_setting_unlogged` (the new key and its notice). A test proves nothing else in them changed.
  - Corrections use a new `corrects_id` link, not `reverses_id`, which reconcile treats as "never happened".
- **B1, request expiry and the dashboard: built, waiting for Dad's review (2026-10-04).** Not committed yet.
- **Migration `20261012000000_request_expiry_dashboard.sql`** (new):
  - **The setting `request_expiry_days`:** starts at 7 days; whole days from 3 to 30.
    - Each deposit and withdrawal gets `requests.expires_at` when she asks: the setting in force that Alberta day × 24 hours.
    - A trigger sets it, replacing anything an insert says, and another refuses any later change, for every role.
    - Requests made before this migration got exactly 7 days.
    - Moves have no expiry; a check constraint enforces both rules.
  - **Two Part A originals changed on purpose:**
    - `approve_request_unlogged`: approving uses the request's own expiry. The message now says when: "This request ran out of time on Oct 16 at 10:00 am (after 10 days), so it has expired."
    - `set_setting_unlogged`: accepts the new key, and sends the girls' notice when a change starts today.
    - **Proof that nothing else changed:** a test swaps the new lines back for the committed ones and gets the committed md5 fingerprint. Part A's fingerprint test now lists the two new fingerprints, with a comment saying why.
    - The `set_setting` wrapper's log line adds "Request expiry set to 10 days from Oct 6."
  - **The girls' notice `rule_change`:** "Dad now has up to {N} days to answer your requests", with a body saying requests already made keep their time.
    - Sent when the change takes effect: right away when it starts today, otherwise by the expiry job on that day (catch-up included).
    - Never sent when the number doesn't change, and never the same news twice in a row to a kid.
  - **`expire_requests`:** expires each request at its own `expires_at` (`decided_at` = that time). Her notice says how long it waited ("waited 10 days…").
  - **The nightly check:** `reconcile_account` is wrapped like Part A's functions (renamed to `reconcile_account_core`, body unchanged). The wrapper adds the `expiry` problem once the expiry job has done the date:
    - a request still waiting after its expiry;
    - one approved after it;
    - an expired one with the wrong time.
  - **`parent_inbox`** uses each request's own expiry.
  - **`parent_dashboard()`**, every figure and date from the database:
    - each kid's figures;
    - the liability (real kids only), with test accounts listed apart;
    - what's waiting;
    - **the 48-hour warning**, real kids and test accounts apart;
    - automatic moves in the last 14 days;
    - GICs waiting for her choice or maturing within 30 days;
    - open alerts, with quiet ones apart;
    - rate, cap and rule notices in the last 30 days, with when each kid read them;
    - the holiday-table warning, 60 days before a market's confirmed dates run out (unconfirmed years count as missing). The TSX's starts on Nov 1, 2026.
    - **The warning's wording (Dad's choice):** "Robin's $25.00 deposit expires tomorrow at 6:00 pm (in 28 hours)."; "…ran out of time today at 10:00 am. Tonight's run cancels it."; "(in 30 minutes)", "(in 1 hour)". Hours round down. `fmt_relative` says today, tomorrow, yesterday or the weekday.
  - **`parent_settings()` and `parent_change_preview()`:**
    - The Settings screen's figures: the rule in force, any scheduled change, and the history with who and when (from the log).
    - The rolled-back dry run (with `in_preview()` on, per CLAUDE.md) shows the log line and exactly what the girls will be told, and when. For a change that starts later, it dry-runs that day's notice too. B2 extends it to rates.
  - **Glossary:** "Request expiry", worded without a number of days, because Dad can change it.
- **Screens:**
  - **Dashboard** (`src/parent/dashboard/`), on phones in this order:
    1. **Needs you:** what's waiting, with **Open Approvals**; "⏳ Running out of time", each warning linking to Approvals; test accounts' warnings folded under "Test accounts (n)"; the holiday warning.
    2. **Alerts**, each with **Acknowledge**: a confirmation, then a log row ("Done. Alert acknowledged. Recorded: Dad, …"). Test accounts' alerts are folded.
    3. **The girls:** each total worth with savings, GICs, funds and money put in; **What you owe them**; test accounts listed apart, "not included".
    4. **GICs coming due.**
    5. **Automatic moves (last 14 days).**
    6. **Have they read it?** Each notice, and when each kid opened it.
    - Two columns from 960 px.
  - **Settings** (`src/parent/settings/`), the B1 part: **Time to answer a request**.
    - Shows the current number, any scheduled change and the history.
    - **Change** opens a confirmation:
      1. days (checked as typed: whole days 3–30);
      2. **Starts on** (defaults to today, from the database);
      3. an optional note for your records;
      4. "This will be recorded: Request expiry set to 12 days from Oct 4.";
      5. the girls' notice, and when they get it ("right away" or "On Oct 7");
      6. then **Yes, change to 12 days** or **Back**.
    - After saving: "Done. … Recorded: Dad, Oct 4 at 1:07 pm."
  - The stage 6 placeholders are gone.
  - **Her history line** for an expired request now reads "Nobody answered in time, so it was cancelled. You can ask again any time."
- **Docs:**
  - **MESSAGES.md §1:** the expired notices say "waited {days} days"; a new "Time to answer a request" section with the `rule_change` notice and when it's sent.
  - **MESSAGES.md §7:** the expired history line.
  - **GLOSSARY.md:** "Request expiry".
  - **SPEC:** "Stale requests"; Build decisions (the rule, the notice, the 48-hour warning, and "the account agreement quotes the setting in force"); the admin settings list; the settings keys; the data model (`expires_at`, `rule_change`, `parent_actions`).
  - The other "7 days" in SPEC are different rules (GIC choice, rate notice, wish-list goal) and are unchanged.
- **Demo:** Robin's $25 and Sky's $8 deposits, asked 6 days before, so the dashboard shows a warning and a folded test-account one.
- **Time machine:** the scenario now lengthens expiry to 10 days from Jan 10, 2028 (saved Jan 5).
  - Sky's Jan 8 deposit still expires after 7 days (Jan 15).
  - Her Jan 12 $15 withdrawal is still waiting on day 9, and expires after 10 days (Jan 22), releasing the hold.
  - The independent model has its own expiry rule (set when she asks, from the rule in force that day) and its own known-answer tests.
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **911 of 911**, after `supabase db reset`. New:
    - **`request_expiry_test.sql` (60):**
      - the default;
      - expiry fixed when she asks, and unchangeable by anyone;
      - 3 and 30 allowed; 2, 31, 7.5, "ten" and "010" refused;
      - the log line;
      - the notice on the day a change starts, only once, and not for the same number, including on a catch-up night;
      - 7-day and 10-day requests side by side;
      - approve at 9:59 am, refused at 10:00 am with the new message;
      - the expired notices saying 7 and 10 days;
      - the Approvals screen's expiry;
      - the two "only these lines changed" proofs;
      - the nightly check's new rule (caught, not before expiry, not before the job runs, cleared once expired);
      - the Settings read, the preview (with nothing left behind, and in-preview on) and who may call.
    - **`parent_dashboard_test.sql` (19):**
      - totals and liability against `account_balances`;
      - waiting counts;
      - the warning's known answers (ran out, 30 minutes, 28 hours, exactly 48 hours in, 48 hours and 1 minute out, 1 hour) and test accounts apart;
      - moves (14 days), GICs (waiting, 22 days, too far), alerts and quiet alerts, notices read;
      - the holiday warning on Oct 31 (none) and Nov 1 (TSX);
      - who may call.
    - **Updated:** the glossary count (55), the notification types (`rule_change`) and Part A's two fingerprints.
  - `npm test` (Vitest): **174 of 174**. New: the dashboard wording (moves, GICs, counts, read status) and the Settings wording (days typed 3–30, when they're told), plus 2 model tests for the expiry rule.
  - `npm run test:e2e` (Playwright): **57 of 57**.
    - **New `dashboard.spec.ts`** (reads only, so it runs early, in the layout group), each check against the database:
      - the girls' totals, what you owe, and what's waiting;
      - Robin's warning in the database's words, Sky's folded until opened, and the link to Approvals;
      - GICs waiting, and each notice's read status.
    - **New in `approvals.spec.ts`:** changing expiry. A later-dated preview ("On Oct 7…") then **Back** changes nothing; 31 is refused; then 10 days from today, with the log line, the status message, the setting and Robin's notice word for word as previewed.
    - **`layout.spec.ts`:** the dashboard (folded lists opened) and Settings (a change being previewed) at all six sizes, normal and 130% text.
    - **`parent.spec.ts`** checks the new dashboard.
    - **Test helper:** parent sign-ins now take turns through a lock shared by all test workers. With up to nine at once, one finishing the code step was ending another's half-finished sign-in (Supabase's rule, found in Part A).
  - `npm run timemachine`: **PASS, 14 of 14**, on the finished B1 code. 78 of 78 actions agreed with the model (3 new), and 12 of 12 planned outcomes, including the three new expiry checks.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none can be ticked yet (they're live). Newly testable locally: an unanswered request expires at its own time with a notice, and the dashboard's liability total leaves out test accounts.
- **Known issues and notes:**
  - The browser pane's screenshots cropped at 2× pixel scaling during my own check (the page measured exactly 412 px, with no sideways scroll), so I reviewed the Playwright full-page shots instead.
  - Requests still running out of time but not yet cancelled show on the dashboard until the nightly run, because nothing runs nightly locally. Run `npm run jobs:local` to process them.
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run demo`, then `npm run dev`.
  2. In an Incognito window go to **http://127.0.0.1:5173/Big-Bucks/parent/login** and sign in (password from the demo, code from `npm run demo:code`).
  3. Look at **Dashboard**, then try **Settings → Change**.
- **B1 committed** (`a90475e`, 2026-10-04) after Dad's review. CI passed (test and timemachine).
- **"View as <kid>", its own step before B2: plan approved by Dad (2026-10-04).**
  - **Dad's decisions:**
    - Views aren't logged.
    - No local time machine run for this step, because no money logic changes; CI runs it.
    - **New rule in CLAUDE.md ("How to work"):** run the time machine locally only when a step changes money logic. Otherwise rely on CI. When it is needed, run it in the background while Dad reviews, and report the result before committing.
    - **For B4:** the account agreement gets a line that Mom and Dad can see her account, for example "Mom and Dad can look at your Big Bucks screens any time, just like they can see your wish list." It will be drafted into MESSAGES.md with the rest of the agreement.
  - **Built, waiting for Dad's review.** Not committed yet.
- **Migration `20261013000000_parent_view.sql`** (new; reads only): **`parent_view(account, read, args)`**.
  - **Who:** a parent with the authenticator code; kids (even for themselves), a parent without the code, signed-out visitors and the server role are refused.
  - **What:** it allows only a fixed list of 20 reads and refuses anything else ("There's no "trade_options" to view."). Each read is answered by the same read function or view her own app uses, for that one account:
    - her name;
    - today;
    - her balances, Home GICs, unread notices and unread count;
    - "Updating…" and the Wish List switch;
    - current rates;
    - funds, history, notices and questions;
    - all the graph reads.
  - Her own read functions didn't change.
  - It's `stable`, and has no insert, update or delete (a test checks).
- **Screens:**
  - **`src/kid/kidView.ts`:** whose screens these are, and how they read. In her own app, the screens read exactly as before. In "View as", **every read goes through `parent_view`**, including the reads her app makes straight from tables and views (balances, GICs, notices), which a parent could otherwise see for every kid.
  - **Marking notices read** goes through one helper that does nothing when Dad is viewing.
  - **Her shell** (`KidShell`) now serves both:
    - her name and the links come from the view;
    - in "View as", a banner sits on top: "Viewing Robin's screens — read-only" with **Exit**;
    - only Home and Graphs are tabs (Buy / Sell and the Wish List are hers), and there's no Sign out;
    - any other address (like Buy / Sell's) goes to her Home.
  - **Switched off in "View as", and pointing at the banner for screen readers:** "Choose what's next" and "Choose" (a waiting GIC), "Got it", and "Something looks wrong?". "Show more" and opening a line's "How was this calculated?" still work, because they only read.
  - **Dashboard:** a **View as Robin** button on each girl's card (and on each test account).
  - **Routes:** `/parent/view/<her account>`, plus `/history`, `/graphs` and `/notices`, behind the parent guard (authenticator code).
- **Not through `parent_view`:** the funds list (names and colours) and the glossary. They're the same reference data for everyone, not hers, and a parent may read them anyway.
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **930 of 930**, after `supabase db reset`. New **`parent_view_test.sql`** (19):
    - **Each of the 20 reads compared** with what kid A herself gets through her own app's reads, run as her with her own permissions. Kid B (a test account) has her own data, so a wrong account would show.
      - All 20 match, and none is empty.
      - Her unread notices and balances are hers, not her sister's, which matters because a parent could see both.
    - **Viewing changes nothing:** after every read, no request, ledger line, notice, question, GIC or log row has changed, and nothing is marked read.
    - **Who may call:** refused for a kid (herself or her sister), a parent without the code, signed-out visitors and the server role. Unknown reads and unknown accounts are refused.
    - **Every kid action refuses a parent with the code:** deposit, withdrawal, GIC buy, GIC break, the maturity choice, a trade and a question ("Only a kid's account can do this."); marking notices read ("Only a kid can mark her notices as read."); even Buy / Sell's preview. None changed anything.
    - **Her own app is unchanged:** a kid still can't read her sister.
  - `npm test` (Vitest): **174 of 174**.
  - `npm run test:e2e` (Playwright): **61 of 61**.
    - **New `viewas.spec.ts`** (reads only, so it runs early, in the layout group). Each check is against what Robin herself gets, run as her in the database:
      - **from the dashboard:** the banner, "Hi, Robin!", her total worth, only Home and Graphs as tabs, "Choose what's next", "Got it" and "Something looks wrong?" switched off, no Sign out, Buy / Sell's address goes to her Home, and **Exit** goes back to the dashboard; nothing changed;
      - **her history** (as many lines as she has, up to the first 30), **her questions** and **her notices**, with the same "New" tags; after leaving, the bell still counts them, and **nothing was marked read**;
      - **her Graphs:** the mix's percents match hers; the Nasdaq-100 note shows;
      - **through the app's API with Dad's own signed-in session (with the code):** all 9 of her actions are refused with the database's messages; **with Robin's own session, `parent_view` is refused**; nothing changed.
    - **`layout.spec.ts`:** View-as Home, history with a line open, notices, and three graphs, at all six sizes with normal and 130% text: no problems.
  - `npm run timemachine`: **not run locally** (Dad's rule: no money logic changed). CI runs it on push.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none (this is a new parent tool, not in the checklist).
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run demo`, then `npm run dev`.
  2. Sign in as the parent in an Incognito window.
  3. On the **Dashboard**, tap **View as Robin**.
- **"View as" committed** (`32f9ef6`, 2026-10-04) after Dad's review.
- **B2, Settings: built, waiting for Dad's review (2026-10-04).** Not committed yet.
- **Migration `20261014000000_settings_screen.sql`** (new). No money logic changes: rates and settings are still saved by the committed `add_rate` and `set_setting`, unchanged.
  - **Two new parent actions, each logged** in `parent_actions` in the same transaction:
    - `edit_note(note, wording)`: reword a market-move note already written (at most 300 letters).
    - `edit_glossary(term, wording)`: reword a **?** explanation (at most 400 letters). Terms are fixed, because the app asks for them by name.
    - Notes and the glossary are wording, not money history, so they're edited in place. The log keeps the wording **before and after**.
    - Refused: the same wording, no words, too long, an unknown note or term, a kid, or a parent without the code.
  - **`parent_change_preview` now covers rates and the two edits.** It still runs the real action with `in_preview()` on and always rolls it back.
    - Each of the girls' notices now says **when** she gets it: right away, on the day a change goes live, or the day after a special ends. For a special that's three notices.
    - It also returns plain "facts" for the screen (before → after, from when, and for a special, the rate it goes back to).
    - `notices_on` is gone (each notice has its own date). B1's test was updated to match.
  - **`parent_settings` returns everything the screen shows:**
    - every rate in force today, any special (its last day and the regular rate underneath), scheduled changes, and the full rate history with notes, who and when;
    - the cap, inflation, the three dividend yields and the feature switches (wishlist, personalisation, badges, plus any other switch already set), each with its scheduled changes and history;
    - the standard up-day and down-day notes, the latest 30 notes written, the glossary;
    - the latest 10 Settings changes, with who and when.
    - The defaults come from the database: a new rate starts 7 days out, and a special runs a week.
- **The screen (`src/parent/settings/`):**
  - **Jump links** at the top: Rates · Cap and limits · Inflation and dividends · Feature switches · Wording · Backup. Pairs of cards sit side by side from 960 px.
  - **Rates:** one list (savings, then the six GIC terms), each with **Change**. Change opens, under that rate:
    1. the new rate (typed as a percent; kept as exact text, never a decimal number);
    2. **Limited-time special**, with first and last day;
    3. **Starts on** (7 days out by default);
    4. a note the girls see;
    5. the preview: "3-month GIC: 3.0% → 2.75% from Oct 11.", "GICs already bought keep their locked-in rate.", the log line, and **each notice the girls will get and on which day**;
    6. **Yes, save 2.75% from Oct 11** or **Back**.
    - A special in force shows "⭐ Special until Oct 11, then 5.0%". Below the list: **History of rate changes**.
  - **Deposit cap** (typed in dollars), **Time to answer a request** (B1, unchanged), **Inflation rate**, **Dividend yields**, **Feature switches** (Off / Test accounts only / Everyone): each the same way, with a start date, preview, confirmation and history.
  - **Market-move notes:** the standard up-day and down-day wording (dated settings, for new notes), and the notes already written, each with **Edit**.
  - **The ? explanations:** "Show all 55 explanations", a **Find a word** box, and **Edit** on each.
  - **Backup:** the **Download backup** button, switched off, saying it arrives in stage 5.
  - **Recent changes** at the bottom.
  - As before: the button only works once the preview matches exactly what's typed, and after saving it says "Done. … Recorded: Dad, Oct 4 at 3:12 pm."
- **Docs:**
  - **SPEC:** the Download backup button sits on Settings (the B2 plan); Build decisions now describe the Settings preview, and editing notes and explanations in place with a log; the data model says `parent_actions` includes rewording.
  - **MESSAGES §5 and §6** and **GLOSSARY.md:** Dad can reword these in the app. Edits made in the app stay in that database and aren't copied back to these files.
  - No new kid wording: the rate, special and cap notices are the stage 2 ones.
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **993 of 993**, after `supabase db reset`. New **`settings_screen_test.sql`** (63):
    - the rates as shown, and the 7-day and one-week defaults;
    - **rate previews, exact JSON:**
      - savings 2.0% → 1.5%: the notice now and the "now live" one on Oct 12;
      - a one-week special: three notices with their dates;
      - a change from today: one notice only;
    - previews leave nothing behind (rates, settings, notices, log, notes, glossary);
    - the real messages for a past date, a special ending before it starts, too many decimals, an unknown term, not savings or a GIC, not a number, and 100% or more;
    - **saved for real:** her notice right away and the one on Oct 12 are **word for word what the preview showed**, and so is the log line;
    - Settings shows the scheduled change and the history (note, who, when);
    - **a special ending on time:** in force on its last day, gone the day after, and both kids told it has ended;
    - cap, inflation, yield and switch previews (the cap's notice to both kids, no notice for inflation, "Off → Test accounts only"); the cap's card with its scheduled change and history;
    - rewording a note and an explanation: the preview, the log's before and after, she reads the new wording, and every refusal;
    - who may call: a kid, a parent without the code; only the four Settings functions are callable at all, and the helpers are internal;
    - all three dry runs run with `in_preview()` on; the real action with it off.
    - **Updated:** B1's preview test (the new shape), and Part A's "nothing skips the log" guard now allows the two new actions to log themselves.
  - `npm test` (Vitest): **179 of 179** (5 new: typed percents and wording, and the rate and setting wording).
  - `npm run test:e2e` (Playwright): **66 of 66**.
    - **New `settings.spec.ts`**, in its own project that runs last, because it changes rates and the cap:
      - **a rate change:** a typo is refused, **Back** changes nothing, then save; the rate, the log, the status message, and **Sky's notice word for word as previewed, also seen in her own app**;
      - **a one-week special:** three notices, the day-after notice word for word, "Special until …, then 5.0%", and the database's rate on its last day and the day after;
      - **the cap:** both girls' notices word for word;
      - a feature switch, rewording a note (with **Back** first) and an explanation, each checked in the database;
      - Download backup is switched off.
    - **`layout.spec.ts`:** Settings with request expiry being changed, then with a one-week special previewed and every history and the glossary opened, at all six sizes, normal and 130% text: no problems.
  - `npm run timemachine`: **not run locally** (Dad's rule: no money logic changed). CI runs it on push.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none can be ticked yet (they're live). Newly testable locally: Dad's rate change, special, cap change and their notices, all from the app.
- **Known issues and notes:**
  - **Rates change one at a time.** An inverted-curve month means changing several terms, and each sends the girls its own notice.
  - **Rewording in the app doesn't reach the repo.** A note or explanation reworded on the live app changes only that database. GLOSSARY.md and the migrations keep the original wording.
- **Questions for Dad:**
  1. ~~Should a dividend yield change send the girls a notice?~~ **Answered: yes** (built after the review, below).
  2. ~~Feature names OK?~~ **Answered: yes.**
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run demo` (already done; the demo is loaded), then `npm run dev`.
  2. In an Incognito window go to **http://127.0.0.1:5173/Big-Bucks/parent/login** and sign in (password from the demo, code from `npm run demo:code`).
  3. Tap **Settings**. Try **Change** on a rate, tick **Limited-time special**, and watch the notices appear. **Back** changes nothing.
- **Dad's B2 review (2026-10-04): a gap and three changes.** Dad set savings from 1.75% to 1.0% starting the next day and it was accepted, which broke the 7-day notice promise. Dad's decisions:
  1. The database refuses a rate or dividend yield cut that starts less than 7 days out. Raises can start right away. The preview and the refusal explain the rule. Known-answer tests first, and a time machine run.
  2. A dividend yield change sends the girls a notice, with the same advance notice as a rate change.
  3. **Cancel** for a planned rate or setting change: an appended cancellation (no edits), logged, with one notice to the girls if they'd been told, and none if they hadn't.
  4. The feature switch names are fine.
  - **Asked and answered:** cancelling a promised raise less than 7 days before it starts counts as a cut, so it's refused. A cut is measured day by day: each of the next 7 days, before and after.
- **Fixes: built, waiting for Dad's review (2026-10-04).** Not committed yet. All in the still-uncommitted migration `20261014000000_settings_screen.sql`.
  - **7 days' notice for a cut:**
    - For each day from today to today + 6, the rate the girls expect before the change is compared with the rate after it. If any day would be lower, the change is refused and nothing is saved.
    - It covers a new rate, a special below the regular rate, a newer special replacing an announced one, stacked changes, a dividend yield, and cancelling a raise.
    - It lives in the logged `add_rate` and `set_setting` wrappers. The committed originals are unchanged; their fingerprint tests still pass.
    - The message: "This would lower the savings rate on Oct 6, sooner than 7 days from today. A cut needs 7 days' notice so the girls have time to react: start it on Oct 12 or later. A raise can start right away."
    - The rate and yield editors show the rule up front: "A lower rate needs 7 days' notice so the girls can react: it can start on Oct 12 at the earliest. A higher rate can start today."
  - **Dividend yield notices:** when Dad saves a change (only if the number changes), and a "now live" notice on the day it starts if that's later (from the nightly run). Wording in MESSAGES §1, "Dividend rates".
  - **Cancel:**
    - A new append-only table `cancellations` points at the rate or setting row. Nothing is edited or deleted.
    - Every reader skips cancelled rows: `rate_on`, `setting_on`, `feature_enabled`, `current_rates` (her "next rate"), the nightly rate and yield notices, and the expiry rule's notice.
    - Kids who were told get one notice ("The savings rate change on Oct 13 is cancelled", saying what applies instead). That's rates, specials, the deposit limit and dividend yields. Kids who weren't told get nothing: inflation, feature switches, standard notes, and request expiry before its day.
    - Refused: a change that's already started, one already cancelled, and `launched_at`.
    - Logged as "Cancelled: Savings rate set to 1.0% from Oct 13."
    - On screen: every planned change has **Cancel change**, which shows a confirmation with an optional note, the log line and the girls' notice. The history keeps cancelled changes, marked "(cancelled)".
  - **Time machine:** the independent model now has the 7-day rule, dated dividend yields and cancellation, with 3 new known-answer tests. The scenario has 11 new steps:
    - a short-notice savings cut and a short-notice yield cut, both refused;
    - a savings cut announced, then cancelled (interest stays at 1.5%);
    - a 9-month GIC raise whose cancellation 3 days out is refused;
    - a TSX yield raise from today (January's dividend pays 3.5%);
    - a Dow yield cut, cancelled (April's dividend still pays 1.8%);
    - a cap cut to $500, cancelled (January's deposits still fit).
  - **PROGRESS, Stage 4:** Dad's rule about the pre-launch audit is recorded at the top of the stage log.
  - **Docs:** SPEC (admin settings, rate notice, Build decisions, data model), MESSAGES §1 (dividend rates; a planned change is cancelled).
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **1062 of 1062**, from empty.
    - New **`notice_and_cancel_test.sql`** (68): Dad's case and every edge above, with exact wording; yield notices on save and on the day; cancellation for rates, specials, the cap and a yield (told), and for inflation, request expiry and a switch (not told); readers skipping cancelled rows; refusals; who may call; append-only.
    - **Updated:**
      - `engine_interest_gic_test.sql`: its same-day "rates fell" cut is now inserted directly, standing for a cut announced a week earlier, because Dad's path refuses it.
      - `clock_test.sql`: truncating `settings` is still refused, but now first by the `cancellations` link, so it checks for any refusal plus that every row is still there.
      - `schema_test.sql`: the new table.
      - Part A's "nothing skips the log" guard: allows `cancel_change`.
      - `settings_screen_test.sql`: scheduled changes now carry ids, and history rows carry "cancelled".
  - `npm test` (Vitest): **182 of 182** (3 new model known answers).
  - `npm run timemachine`: **PASS, 14 of 14**. 89 of 89 actions agreed with the model (11 new), and 23 of 23 planned outcomes. `docs/TIMEMACHINE-REPORT.md` is regenerated.
  - `npm run test:e2e` (Playwright): **67 of 67**. New in `settings.spec.ts`: Dad's case refused on screen with the rule shown, then saved with 7 days' notice, then cancelled (Sky's notice word for word as previewed; the rate row kept, the cancellation added); a TSX yield raise and Robin's notice word for word. `layout.spec.ts` adds the Cancel confirmation at all six sizes, normal and 130% text.
  - `npm run lint` is clean and `npm run build` succeeds.
- **Known issues and notes:**
  - The rule protects what the girls expect, so **a special can't be ended early** once it's inside the week, and an announced cut can't be pulled earlier.
  - Request expiry has no notice rule (not asked). Lowering the cap still takes nothing away.
- **Dad's second review (2026-10-04): fixes look good, plus one more.** A lower deposit cap gets the same 7-day rule (the girls are told, and a cut shrinks their room to deposit). Raises start right away. Known-answer tests first, a time machine run, then commit, push and confirm CI.
  - **Built:**
    - The `set_setting` wrapper and `cancel_change` check the cap day by day, like rates and yields. So a lower cap needs 7 days, and cancelling a promised cap raise inside the week is refused.
    - Refusal: "This would lower the deposit limit on Oct 6, sooner than 7 days from today. A cut needs 7 days' notice so the girls have time to react: start it on Oct 12 or later. A raise can start right away."
    - The cap editor shows the rule up front.
    - The model has the same rule.
  - **Tests:**
    - **11 new known answers** in `notice_and_cancel_test.sql`, written first and failing before the fix: tomorrow, today and 6 days out refused (the preview too), nothing left behind, exactly 7 days allowed with the girls told a week ahead, a raise today, and cancelling a promised raise refused.
    - **1 new model known answer.**
    - **Updated:**
      - `engine_requests_test.sql`: its same-day "lowering the cap never takes money away" test now inserts the cap directly (an announced cut), like the GIC test.
      - `settings_screen_test.sql`: its cap preview is now 7 days out.
      - **Time machine scenario:** the May cap cut (to $800 from May 1) is now announced on Apr 24, and a new step refuses a $700 cap with 2 days' notice.
  - **Results (all run locally on 2026-10-04):**
    - `npm run test:db`: **1073 of 1073**, from empty.
    - `npm test`: **183 of 183**.
    - `npm run timemachine`: **PASS, 14 of 14**. 90 of 90 actions agreed with the model, and 24 of 24 planned outcomes.
    - `npm run test:e2e`: **67 of 67**.
    - Lint is clean and the build succeeds.
- **B2 committed** after Dad's review (see git log).
- **B3, Fix a mistake: built, waiting for Dad's review (2026-10-04).** Not committed yet.
  - **Dad's rules** (the plan's addition 3, plus his three for B3):
    - savings only, in dollars, either direction;
    - a new linked entry, never an edit;
    - a note she can read is required;
    - rounds in her favour;
    - never more than her free savings;
    - an extra check for every reduction;
    - **typo guard:** an addition over the deposit cap or $100 (whichever is lower) gets the same extra check, with the amount in large type;
    - **View as stays read-only:** a line there has a "Fix a mistake" link to Dad's own screen for that line; the fix is never made inside View as;
    - the preview uses the preview flag.
- **Migration `20261015000000_fix_a_mistake.sql`** (new):
  - **Links on `transactions`:** `corrects_id` (the ledger line it fixes), `corrects_request_id` (a declined or expired request) and `question_id` (her question). Only a `correction` may carry them, and a trigger makes sure they point at the same kid and that the correction is in savings. They aren't `reverses_id`: the line being fixed still counts.
  - **`correct_savings(account, line, question, add/take, amount, note, check, key)`**, logged in `parent_actions` in the same transaction:
    - **Rounding in her favour:** Dad may type up to 4 decimal places. An addition rounds up to the cent and a reduction rounds down ($1.234 adds $1.24; $1.239 takes $1.23). Taking less than a cent is refused. At most $10,000.00.
    - **The database enforces the extra check:** for a reduction, or an addition over the line, the confirmed amount must equal the amount. Without it: "Taking money away needs the extra check: confirm $1.23 first." / "Adding more than $100.00 needs the extra check: confirm $150.00 first."
    - **Never more than free savings:** "That's more than Robin has free to use ($70.42: $100.42 in savings, $30.00 on hold for her requests). A correction can't take money she doesn't have free."
    - **Linked:** to a history line, a question, or both. A waiting request is refused ("approve or decline it instead"). A question about a request has no ledger line, so the fix links to the question.
    - **Nothing posts twice:** each correction carries a key from the screen (`correction:<key>`). A double tap gets "This correction is already saved."
    - **Her notice** (new type `correction`): "Dad fixed a mistake: $1.24 added to your savings" · "It fixes "Savings interest" on Oct 1. Dad said: "September interest was short"".
    - **Log line:** "Corrected Robin's savings: +$1.24, fixing "Savings interest" on Oct 1." The details keep what Dad typed before rounding.
    - Fixing doesn't answer her question: Dad still answers it on Approvals.
  - **`correction_preview(args)`:** the real correction with `in_preview()` on, always rolled back. It returns:
    - the line;
    - her savings, what's held and what's free;
    - the extra-check line;
    - the amount after rounding and her savings after;
    - the log line and her notice.
  - **`parent_corrections(account)`:** her corrections, newest first, with what each fixes, who and when.
  - **`my_activity`** gains one column, `fixes` ("Savings interest on Oct 1", or "your question from Oct 3"). Nothing else in it changed.
  - **`line_words`:** a history line in her history's words, matching `activityText.ts`.
- **Screens:**
  - **New `src/parent/fix/`**, at `/parent/fix/<her account>?line=…` or `?question=…`:
    1. the line (and question) being fixed, and her savings, what's on hold and what's free to use;
    2. **Add to her savings / Take from her savings**, the amount, and the note she'll read;
    3. **the preview:**
       - the rounding ("You typed $1.2340. It's rounded up to $1.24, in Robin's favour.");
       - her savings before → after;
       - the log line;
       - **Robin will see this right away:** with her notice;
    4. **the buttons:**
       - a small addition: **Yes, add $1.24 to Robin's savings**;
       - a reduction or a big addition: **Next: check the amount**, then a pink-bordered box with the amount in large type ("−$2.00"), why it gets a second look, and **Yes, take $2.00** or **Back**;
    5. "Done. … Recorded: Dad, Oct 4 at 7:30 pm.", and **Corrections so far**.
  - **View as:** opening a line (not a waiting request) shows a **Fix a mistake** link with "Opens your own parent screen for this line. Nothing changes here." There's nothing to type or press there.
  - **Approvals:** each question has **Fix a mistake** next to **Answer**. The fix screen links back so you can answer her.
  - **Her history:** a correction line opens to **What this fixes** ("This fixes: Savings interest on Oct 1.").
- **Docs:** MESSAGES §1 (the notice) and §7 (the correction line); SPEC (Corrections, Build decisions "Fix a mistake", data model).
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **1146 of 1146**, from empty. New **`fix_a_mistake_test.sql` (73)**, written first and failing before the migration existed:
    - **Before typing:** the screen's figures ($100.42 savings, $30.00 held, $70.42 free; the check line is $100 with a $1,000 cap).
    - **Rounding:** $1.234 → 124 cents, $1.239 → −123, $0.0001 → 1. Refused: $0.004, 5 decimals, letters, a minus sign and zero.
    - **The extra check:**
      - none for $100.00; needed for $100.0001 and for any reduction;
      - refused without it, or with the wrong amount;
      - a $50 cap lowers the line to $50.
    - **Free savings:** $70.43 refused with the figures; $70.42 and $70.429 allowed.
    - **Links:**
      - refused: no link, an unknown line, her sister's line or question, a waiting request, a question with a different line;
      - allowed: a declined request, and a question about a request.
    - **The note:** required, at most 300 letters.
    - **The preview:** exact JSON, leaving nothing behind.
    - **Saved for real:**
      - the new line, with the interest line itself untouched;
      - her savings;
      - her notice and the log line, word for word what the preview showed;
      - a double tap posts once;
      - a reduction from a question, a fix to the declined request, and a test account.
    - **The rest:**
      - her history's `fixes`, and Dad's list;
      - who may call: a kid, a parent without the code, a signed-out visitor and the server role are refused, and the helpers are internal;
      - the preview flag is on in the dry run and off for the real correction;
      - link rules: only corrections, the same kid, savings only.
    - **Updated:** `schema_test.sql` (the new notice type), and Part A's "nothing skips the log" guard (it now allows `correct_savings`, which logs itself).
  - `npm test` (Vitest): **191 of 191**. 8 new: the Fix a mistake wording, "What this fixes", and 3 model known answers.
  - `npm run timemachine`: **PASS, 14 of 14**. 96 of 96 actions agreed with the model (6 new), and 27 of 27 planned outcomes.
    - The model has its own correction rule.
    - **New scenario steps on Feb 2, 2028:**
      - add $0.4567 to kid A (→ $0.46);
      - take $5.009 from kid B (→ $5.00): refused without the check, then made with it;
      - add $120.50 to kid A: refused without the check, then made with it;
      - taking more than kid B has free is refused.
    - February's interest then accrues on the corrected balances, to the cent.
    - Run on the final B3 code (run twice: once before and once after two late read-only additions, both PASS).
  - `npm run test:e2e` (Playwright): **72 of 72**. New **`fix.spec.ts`** (5 tests, in its own project, which runs last):
    - **View as stays read-only:** her line has no box or button for fixing, only the link. The link leads to Dad's screen for that line, the banner is gone, and nothing changed.
    - **$1.234 added from View as:** rounded to $1.24, linked to her interest line, **her notice word for word as previewed**, the log, and "Recorded: …".
    - **Taking $2:** the extra check in large type (at least 36 px). **Back** changes nothing; then it's saved.
    - **$150:** the typo guard's check. Taking one cent more than she has free is refused, and the button stays off.
    - **From a question on Approvals:** the question, its line, and the link back.
    - **`layout.spec.ts`:** the fix screen with a reduction previewed, and at its extra check, at all six sizes, normal and 130% text.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none (no box covers corrections).
- **Known issues and notes:**
  - **How the graphs count a correction:** "Money in vs money earned" counts it as money earned, and "Growth by option" counts it as money moved into savings, not growth. That's right for most fixes, but a fix to a deposit shows as earned rather than as money in.
  - **Her history shows a correction on the day it's made,** not next to the line it fixes. The correction line says what it fixes.
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run demo`, then `npm run dev`.
  2. In an Incognito window go to **http://127.0.0.1:5173/Big-Bucks/parent/login** and sign in (password from the demo, code from `npm run demo:code`).
  3. On the **Dashboard**, tap **View as Robin** → **See all** → tap a **Savings interest** line → **Fix a mistake**.
  4. Try **Take from her savings**, $2 and a note (from a **Money in** line: since the review, a reduction can't be more than its line), then **Next: check the amount**. **Back** changes nothing.
- **Dad's B3 review (2026-10-04): two problems and six changes.** He added +$500 and +$1,000 corrections to a $0.56 interest line with one extra tap each, and her history showed "A correction" and his note but not what it fixed. Rounding as built is right. His changes:
  1. any addition over $100 needs the exact amount typed again, and the database refuses it without that;
  2. no single correction larger than the deposit cap, with a message pointing to a normal deposit;
  3. a reduction linked to a line can't be more than that line's amount (and never more than her free savings); additions may be more;
  4. a warning, not a block, when an addition is more than its line;
  5. her history line and notice name what the correction fixes;
  6. the graphs count a correction like the line it fixes.
- **Built (still uncommitted, so the uncommitted migration `20261015000000_fix_a_mistake.sql` was changed in place):**
  - **Typing the amount again:** `correct_savings` now takes `p_confirm`, the amount again as text, which must equal exactly what was typed before rounding.
    - A reduction: the screen sends it when Dad taps to confirm.
    - An addition over $100: Dad types it a second time.
    - Refusals: "Adding more than $100.00 needs the amount typed again to confirm ($500.00)." and "The amount typed again ($15.00) doesn't match $150.00. Please type it again."
    - The old "the lower of the cap and $100" line is now just $100, because the cap is now the ceiling.
  - **The ceiling:**
    - "A single correction can't be more than the deposit limit ($1,000.00). If this is new money, use a normal deposit instead."
    - For a reduction: "…If she's taking money out, use a normal withdrawal instead."
    - Exactly the cap is allowed. The old $10,000 limit is gone.
  - **Line limit:** "A fix can't take more than the line it fixes: "Savings interest" on Oct 1 was $0.42." Earlier reductions from the same line count too: "…was $0.42, and earlier fixes already took $0.30, so at most $0.12 is left." Additions may be more.
  - **Warning:** the preview returns "This is more than the line it fixes ($0.42). Is that right?" The screen shows it in a gold box; the button still works.
  - **What it fixes, in her words:**
    - The notice title is now the history title: "A correction · fixes Savings interest on Oct 1" (or "A correction · about your question from Oct 3").
    - The body is "Dad added $1.24 to your savings. Dad said: "…"" or "Dad took $2.00 out of your savings. …".
    - Her history line has the same title, with Dad's note under it. The separate "What this fixes" panel is gone.
  - **The graphs:** a new column, `transactions.counts_as`, is set when the correction is made.
    - `money`: a fix to a deposit or withdrawal line, or to a declined or expired deposit or withdrawal.
    - `earned`: a fix to anything else (interest, dividends, trades, GICs, penalties). A fix to a fix counts like the fix it corrects.
    - A fix with no line (a question about a request) is whichever Dad chooses on screen: "Earned (like interest)" (the default) or "Money in or out (like a deposit)".
    - Three graph reads changed only on the line marked "B3":
      - `daily_balances`: money corrections are money moved that day (the deposit dots, and "Money in vs money earned");
      - `money_in_vs_earned`: the same, for money in before the range shown;
      - `growth_by_option`: earned corrections are growth, not money moved.
    - The deposit cap's "money put in" is unchanged: a correction never uses up or frees deposit room.
  - **Screen:**
    - after the amount, the preview says how her graphs will count it, and shows any warning;
    - **Next: check the amount** for a reduction (a tap) or an addition over $100. The second step shows the amount in large type, plus **Type the amount again to confirm** for the addition; its button stays off until something like an amount is typed;
    - a refusal on that step keeps Dad there to type it again.
- **Docs:** MESSAGES §1 (the notice) and §7 (the history line); SPEC Build decisions ("Fix a mistake") and the data model.
- **Tests (all run locally on 2026-10-04):**
  - `npm run test:db` (pgTAP): **1167 of 1167**, from empty. `fix_a_mistake_test.sql` now has **94** tests, rewritten first and failing against the old rules:
    - the ceiling at $1,000 and $1,000.01, both ways, and at $50.00 and $50.01 with a $50 cap;
    - typing again: none at $100.00, needed at $100.0001; missing, $50 for $500, "yes", and $100.00 for $100.0001 all refused;
    - the line limit: $0.43 from a $0.42 line refused, $0.42 allowed, a $20 declined request, and two reductions together ($0.30, then $0.13 refused and $0.12 allowed);
    - warnings: shown for $500 on a $0.42 line; none at $0.42, on a reduction, or with no line;
    - how the graphs count it: a deposit and a declined deposit are money, interest is earned, the line decides over Dad's choice, a question-only fix defaults to earned or takes Dad's choice, anything else is refused;
    - the notice titles and bodies, and her history lines;
    - the graphs on a day with two money fixes (+$150.00, −$20.00) and two interest fixes (+$1.24, −$0.30):
      - money in that day is $130.00;
      - money in vs earned is $230.00 in and $1.36 earned;
      - savings growth is $0.94, with $130.00 of money moved;
    - only corrections may carry `counts_as`.
  - `npm test` (Vitest): **193 of 193**. The model has 2 new known answers (the ceiling, and the line limit taken together), and the history title tests are new.
  - `npm run timemachine`: **PASS, 14 of 14**. 99 of 99 actions agreed with the model and 29 of 29 planned outcomes.
    - The model has its own ceiling and line limit: it finds her latest line of that kind and tracks what earlier fixes took from it.
    - **The Feb 2, 2028 steps** (9 actions; each refusal was planned):
      - +$0.4567 to kid A's interest line, with no check needed;
      - −$5.009 from kid B's deposit line: refused without the tap, then made with it;
      - +$120.50 to kid A: refused without typing it again, then made;
      - +$1,500.01 refused (over the $1,500 cap);
      - $50 from kid B's interest line refused (more than the line);
      - $0.01 from the same line allowed;
      - $9,000 refused.
  - `npm run test:e2e` (Playwright): **73 of 73**. `fix.spec.ts` now has 6 tests:
    - a $1.234 fix: her notice word for word as previewed, and **her history line "A correction · fixes Savings interest on …"**;
    - the warning when an addition is more than its line;
    - a reduction over its line refused, then $2 from a Money in line: one tap (no box to type in), **Back** changes nothing, then saved;
    - over the cap refused; $150 needs typing again: $15 refused with the message, then $150.00 saved;
    - more than she has free refused;
    - from a question on Approvals.
    - `layout.spec.ts`: the fix screen now previews a reduction from a deposit line.
  - Lint is clean and the build succeeds.
- **Demo reloaded** after the tests (new logins in `.demo-logins.local`).
- **Known issues and notes:**
  - "Reductions from the same line" counts only reductions, so an addition to a line doesn't make room for a bigger reduction later.
  - A line with no amount (a fund split) can't have money taken through it; link the fix to another line or her question.
- **Dad to do by hand:** nothing. To try it:
  1. Run `npm run dev`. The demo is already loaded; the logins are in `.demo-logins.local`.
  2. Sign in as the parent in an Incognito window.
  3. Tap **View as Robin** → **See all** → a **Savings interest** line → **Fix a mistake**.
  4. Try **Add to her savings** with $500: a warning, then **Next: check the amount** asks you to type it again.
  5. Try **Take from her savings** with more than the line: refused.
- **Dad's retest (2026-10-04): B3 looks good.** He accepted both choices: GIC and penalty fixes count as earned, and corrections don't change deposit room. Committed and pushed (see git log).
- **B4, step 1: the kid wording, drafted for Dad's review (2026-10-04).** No screens yet (Dad's instruction). Everything is in **MESSAGES.md §11**:
  - **Welcome**, with the steps listed; steps for switched-off features are left out.
  - **The tour**, skippable: Home, the three options, Graphs, Buy / Sell, the Wish List and the bell.
  - **Make it yours** and **your first wish** (each only if that feature is on).
  - **The account agreement**:
    - 14 house rules in kid words, from SPEC's house rules and the money rules, including Dad's line "Mom and Dad can look at your Big Bucks screens any time, just like they can see your wish list";
    - Dad's promises;
    - her signature, Dad's countersignature and its notice, and the history line.
  - **The first decision**, after her first deposit lands.
  - **What's new**, for the Wish List, Make it yours and Badges, plus the pattern for later features.
  - **No fixed numbers:** a table lists each placeholder ({cap}, {expiry_days}, {cut_notice_days}, {savings_rate}, the GIC rate range, minimums and waiting periods) and where it's read from. Settings numbers come from the setting in force; fixed rules come from the database's own rule.
  - **Five questions for Dad**, at the end of §11: gifts and allowance; whether the signed copy keeps that day's wording; Dad signing on his own phone; reading fixed rules from the database; the crash example.
- **Next:** after Dad's review of the wording, a short plan for the B4 screens, then build them.
- **Dad's answers to the five questions (2026-10-05), now in MESSAGES §11:**
  1. Gifts and allowance: yes, within the cap, through a normal deposit request.
  2. The signed copy is frozen, and number changes come by notice. A new or reworded rule means a new version to sign; the old one stays in her history. Drafted: the "agreement has changed" notice, a Home banner, the new version with **New** and **Changed** marks, and the version number in the history line.
  3. Dad signs on his own phone.
  4. Fixed rules are read from the database.
  5. The crash example is Dad's wording: "A big drop can turn $100 into $80, and sometimes less, for a while. Markets have usually come back, but it can take a long time."
  - SPEC Build decisions now has "The account agreement".
  - Committed and pushed (docs only), waiting for Dad's review of the wording.
- **Dad's wording review (2026-10-05), applied in MESSAGES §11:**
  - Dad's promises no longer promise the rate notice (it's automatic) and say mistakes are fixed openly, with a note, rounding in her favour (a fix can take money back).
  - Rule 11: Big Bucks (not Dad) gives the notice for a cut; good news can start right away.
  - Rule 2 reworded (room comes back when money goes out). Rule 15, "Mom and Dad can see your account", has a bold heading.
  - The tour says stock funds have "usually" grown the most, and each option "has a good side and a catch".
  - **New rule 14:** "Your PIN is yours."
  - **First decision:** only choices she can afford with her free savings; under {min_invest}: "Once you have {min_invest}, you can try a GIC or a fund."
  - Committed and pushed (docs only). Next: the B4 screens plan, waiting for Dad's OK.

### Stage 7 — Kid screens: Home, Graphs, Buy / Sell, local only (finished 2026-10-03)

The whole stage in one place. The details, Dad's decisions and each review are in the part 1 and part 2 entries below, and the Alberta time fix made during the stage.

- **Built:**
  - **Home** (part 1): total worth, the "Things for you" banner (a matured GIC, the newest notice), savings with what's on hold and free to use, GICs with their locked rates and ready dates, her mix and all three funds with sparklines, and recent activity with **See all**.
  - **The GIC choice** (part 1): renew, a new term, or move to savings, with what each earns.
  - **Buy / Sell** (part 2a): the Buy / Sell toggle with From ➜ To, the amount checked after she pauses, the spec's warnings, a summary before **Yes, do it**, GICs as tappable cards, her waiting requests, and selling by typing the shown value.
  - **Transparency** (part 2b): the notices list with the database's dates, **How was this calculated?** on every line, **Something looks wrong?** with Dad's answers in her history, and the accessibility pass.
  - **Graphs** (part 2c): all six graphs, one at a time with tabs: total worth over time, growth by option (time-weighted), money in vs money earned, my mix today, the GIC ladder, and stock fund detail with her buys and sells and the market-move notes.
  - **Alberta time:** UTC−6 all year from Nov 1, 2026, pinned in the database.
- **Migrations added in stage 7** (all read functions except the time fix and the sell-all rule): `20261005000000_kid_home`, `20261006000000_alberta_time`, `20261007000000_buy_sell`, `20261008000000_notices_questions`, `20261009000000_sell_shown_value`, `20261009010000_option_colours`, `20261010000000_graphs`.
- **Tests (final run, 2026-10-03):**
  - `npm run test:db` (pgTAP): **769 of 769**, after `supabase db reset`.
  - `npm test` (Vitest): **162 of 162**.
  - `npm run test:e2e` (Playwright): **41 of 41**, including the layout and accessibility checks on every kid screen and all six graphs at six sizes, normal and 130% text.
  - `npm run timemachine`: **PASS, 14 of 14**.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none can be ticked yet: every box in Phase 1 is proven live, and the "Before any real money" group needs stage 4 (backups) and stage 5. Stage 7 makes the kid side of these testable in the local copy, ready for the solo beta:
  - **Money in and out:** a deposit request holding money; a deposit over the cap refused with a clear message; a withdrawal showing when Dad can say yes (24 hours); cashing out of a GIC or fund only through savings (Buy / Sell only offers moves through savings); a declined request with Dad's reason in her history.
  - **Savings and GICs:** savings interest with its "How was this calculated?" working; the maturity banner and the choice screen; breaking a GIC early with the warning in dollars.
  - **Stock funds:** each trade's settle time ("Monday's 2:00 pm close"), 3:00 pm in winter; one trade per fund per day ("traded today"); a partial sell; **the standard note on a day a fund moves more than 2%** (on the fund graph).
  - **Rates and settings:** rate and cap notices in the bell.
  - **Safeguards:** "Something looks wrong?" from her side (Dad's side of answering is stage 8).
- **Known issues and limits:**
  - Dad's screens (approving, declining, answering questions, rates and settings) are stage 8; until then the demo and tests do Dad's part through the database functions.
  - "Cancel a waiting request" is on the version 2 list.
  - Savings growth steps once a month (interest posts on the 1st), as Dad decided; the graph says so.
  - The "Show as a table" view for "All" can be long (one row a day). Fine for a year or two; worth a look after a few years.
  - The demo's TSX dip and Nasdaq-100 jump are made-up prices, in the demo only.
  - Nothing is deployed: the app still runs only against the local database. Deploy and phone install come after stage 4.
- **Dad to do by hand:** nothing. To try it: `npm run demo`, open **http://127.0.0.1:5173/Big-Bucks/** in Chrome, and sign in as Robin or Sky with the PINs it prints.

### Stage 7, part 2 — Buy / Sell, transparency and the graphs: all reviewed (2026-10-03)

- **The plan Dad approved:**
  - **2a:** Buy / Sell, then stop for review.
  - **2b:** notices (with dates from the database), "How was this calculated?", "Something looks wrong?" and the accessibility pass, then stop.
  - **2c:** all six graphs from the spec, then stop.
- **Decisions Dad made:**
  1. A **Buy / Sell toggle plus From/To lists**:
     - **Buy:** Cash → Savings (a deposit), or Savings → a new GIC or a fund.
     - **Sell:** a GIC (broken whole) or a fund → Savings, or Savings → Cash (a withdrawal).
  2. **Her waiting requests** are shown on Buy / Sell, read-only. "Cancel a waiting request" was added to the SPEC version 2 list; it isn't built.
  3. **Debounce:** `move_preview` runs only after she pauses typing.
  4. **The amount box** refuses negatives, letters and more than 2 decimals, with a friendly message that goes in MESSAGES.md. It turns text into cents with BigInt, never floats.
- **Part 2a, Buy / Sell: built, waiting for Dad's review.**
- **Migration `supabase/migrations/20261007000000_buy_sell.sql`** (new). It only reads; no engine function or money rule changed.
  - **`fmt_close(close)`:** a close in words, from today's point of view.
    - Forms: "today's 2:00 pm close", "tomorrow's …", "yesterday's …", or "Monday's 3:00 pm close (Oct 5)".
    - It uses the pinned Alberta rule (`edmonton_local`). It's internal: the app can't call it directly.
  - **`trade_options(account)`:** everything the screen needs before she types:
    - free to use, and the room left under the deposit cap;
    - each fund: value, cost, gain, what she can sell (the same limit `request_trade` uses), whether she traded it today, and when a trade would settle;
    - each active GIC, with the interest she'd give up by breaking it today;
    - today's GIC rates;
    - her waiting requests: "Dad can say yes from …" on a withdrawal still inside its 24 hours, and when each trade settles;
    - the "Updating…" flag.

    A kid sees only her own account; a parent needs the authenticator code.
  - **`move_preview(kind, amount, fund, gic, term, sell_all)`:**
    - **How it checks:** it runs the real action function (`request_deposit`, `request_withdrawal`, `buy_gic`, `break_gic` or `request_trade`) in a sub-transaction, then always rolls it back. The preview and the real action therefore can never disagree about the rules.
    - **What it returns:**
      - the exact problem message, if any;
      - the warnings: early_break, fund_below_cost, deposit_wait, withdraw_wait and market_price;
      - when a trade settles;
      - for a GIC, what each term earns on her amount (the same `gic_interest_cents` maturity uses).
    - **Who can call it:** kids only.
    - **Trace it leaves:** skipped ID numbers on requests and GICs. No money, hold, notice or ledger line survives a preview, and a test proves it.
- **Screen `src/kid/trade/`:**
  - **`Trade.tsx`:**
    - Buy / Sell toggle, then From ➜ To lists that only offer allowed pairs.
    - The amount, with "free to use", deposit room, or "your fund is worth about …", plus **Sell all of it** for funds.
    - For a GIC: the six terms, with what her amount earns at each.
    - Warnings, then a summary with **Yes, do it**, then **Done** with **Back to Home** and **Make another move**.
    - Her waiting requests (read-only) beside the form, or under it on phones.
    - "Updating…" replaces the form while the nightly check is fixing something.
  - **`moves.ts`:**
    - The From/To rules (every move goes through savings).
    - Typed text → whole cents, using string and BigInt arithmetic only.
    - The friendly amount messages.
  - **The check runs only after she pauses typing** (500 ms). Picking a choice is checked straight away. A fund already traded today is labelled "(traded today, again tomorrow)" and gets a note instead of an amount box.
  - **`tradeText.ts`:** all the screen's words, listed in **`docs/MESSAGES.md` §8**.
  - **Labels:** every control has a proper label. Problems are announced to screen readers (`aria-live`). Controls are 48 px or more.
- **Found and fixed while trying it in the browser:**
  - A problem message showed below the six GIC terms, off-screen on a phone. Problems and warnings now sit right under the amount box.
  - Switching Buy / Sell now starts each side at its own first choices.
  - "6 months GIC" now reads "6-month GIC".
  - The Done message is worded before her holdings reload, so breaking a GIC can't lose the message.
- **SPEC:** "Cancel a waiting request" was added to the version 2 list.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **690 of 690 passed**, after `supabase db reset`. That's the 634 earlier tests plus 56 new ones in **`buy_sell_test.sql`**:
    - **`fmt_close`:** Friday evening → Monday; after the close → tomorrow; TSX Thanksgiving → Tuesday while the Dow trades Monday; 3:00 pm from Nov 2; the 12:00 pm early close on Nov 27; today's and yesterday's.
    - **`trade_options`:** balances, cap room, funds, the GIC's interest so far (a known answer: $0.06), rates and waiting requests.
    - **Preview problems match the real actions word for word:** deposit minimum and cap, withdrawal over what's free, GIC minimum and term, fund buy and sell limits, a fund she doesn't own, another kid's GIC, and the second trade in a day.
    - **Known answers:** the GIC quotes for $100 at every term (1 month $0.21, 9 months $3.38, 2 years $12.00), the early-break warning, and the fund-below-cost warning (worth $475.00, paid $500.00).
    - **Nothing left behind:** a preview leaves no request, hold, GIC, ledger line, notice or broken GIC.
    - **Who may call:** kid B, a parent without the code, signed-out visitors and grants.
  - `npm test` (Vitest): **150 of 150 passed**. The 12 new tests cover the From/To rules, and amounts typed every way (good and bad).
  - `npm run test:e2e` (Playwright): **31 of 31 passed**.
    - **New `trade.spec.ts`**, as Sky (the test account):
      - a deposit request;
      - bad amounts, and one check after a pause;
      - buying a GIC;
      - the early-break warning in dollars, then breaking it;
      - a fund trade with its settle time, then "traded today";
      - a withdrawal with its 24-hour time.

      Each is checked against the database.
    - **`layout.spec.ts`:** Buy / Sell (opening, a GIC with its terms, and the break warning) at all six sizes, normal and 130% text.
  - `npm run timemachine`: **PASS, 14 of 14**. `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none can be ticked yet (they need the live app). Buy / Sell's warnings, cap room and one-trade-a-day are now testable locally.
- **Dad's review of 2a (2026-10-03): "tested and looks good", with four changes, all done:**
  1. **GICs are tappable cards, not dropdown lines:**
     - In the From list her GICs are one choice: "🔒 One of your GICs", or "🔒 Your GIC" when she has just one.
     - **Which GIC?** then shows a card for each GIC: amount, term, rate and ready date (or "Ready today").
     - The cards are a radio group, so screen readers announce them as choices, and two GICs of the same size are easy to tell apart.
     - This fixes the cut-off From line on small phones with large text.
     - `dropdownPlaces()` in `moves.ts` has its own test.
  2. **SPEC:** all six graphs are version 1 (the phase 1 list, with "Remaining graphs" removed from version 2). BUILD-PLAN stage 7 item 2 lists all six.
  3. **Demo:** Sky buys $60 of the TSX three market days before the end. The demo's last three TSX closes then ease down 1.5% a day, under the 2% market-move note, so her TSX is worth less than she paid ($57.30 against $60.00 on 2026-10-03) and Buy / Sell shows the warning. Robin's TSX dips the same way. They're made-up prices, in the demo only.
  4. **Try-it address:** **http://127.0.0.1:5173/Big-Bucks/** everywhere. The demo now prints it.
- **Also changed:** the line under the amount for a fund sale now reads "You can sell up to {amount}, or all of it."
  - Before, it read "worth about $57.29" while the warning said $57.30.
  - The limit is her units' value rounded down, the database's own limit. Values shown elsewhere round to the nearest cent.
- **Tests after the review:**
  - `npm run test:db`: **690 of 690**.
  - `npm test`: **151 of 151** (1 new).
  - `npm run test:e2e`: **32 of 32**. New: selling a fund worth less than she paid, with the warning and summary in dollars against the database; she then goes back without selling. The GIC-break test now taps a card.
  - Lint is clean and the build succeeds.

- **Part 2b: notices, "How was this calculated?", "Something looks wrong?" and accessibility. Built, waiting for Dad's review.** Not committed yet. Part 2a is commit `ab6f3fc`, and its CI passed.
- **Migration `20261008000000_notices_questions.sql`** (new; reads only):
  - **`my_notices(account, limit, before_id)`:** her notices, newest first, each with its Alberta date (`on_day`, from `edmonton_local`) and whether it's new.
  - **`my_questions(account)`:** her questions with Dad's answers, the line each is about, and the asked and answered dates.
  - **Who can call them:** a kid sees only her own; a parent needs the authenticator code.
- **The notices list (`src/kid/notices/`)** uses `my_notices`, which fixes the known issue: no dates are worked out in the browser any more.
  - Opening the list marks its notices read, and the bell count drops. The **New** tags stay until she leaves.
  - A "Dad answered" notice links to **See your questions**.
  - **`albertaDate()` is removed** (with its 8 tests). The SPEC "Time and dates" rule now says the browser never turns a time into a date, and the "if Alberta's rule changes" checklist no longer mentions the browser.
- **History lines open (Home and "See all"):** each line is a button (`aria-expanded`) with a panel under it.
  - **How was this calculated?** shows the working the database wrote on the line when it posted. That covers savings interest, GIC interest, dividends, fund buys and sales, a GIC broken early, and a penalty. Nothing is worked out in the browser. A penalty's note moved from the line itself into this panel.
  - **Her questions about the line**, with Dad's answers.
  - **Something looks wrong?** calls `ask_question` with the line's ledger id.
    - A request line (waiting, declined or expired) has no ledger entry yet, so the question begins with `About "{line}, {amount}" on {date}: ` instead.
    - An empty question is refused on screen.
  - **"Your questions" on the "See all" page:** the whole thread stays in her history. It shares one list with the lines, so a new question shows in both places at once (a bug the tests caught).
- **Accessibility pass:**
  - **New checks in `layout.spec.ts` on every kid screen,** at 6 sizes with normal and 130% text:
    1. Every control has a name a screen reader can say.
    2. Text contrast is measured on the real page: 4.5:1, or 3:1 for large text. A deliberately pale test line was caught at 4.08:1, so the check works.
    3. Tap targets now include dropdowns, text boxes and the cards and checkboxes she taps.
  - **Screens now checked:** the kid login, Home, history, a history line opened with the question box, the GIC choice, the notices list, and Buy / Sell (three states).
  - **Result:** no problems found on any of them.
  - **Colours that differ in lightness, not just hue:** measured, and **two pairs are too close.** GIC pink and Dow blue differ by 1.19:1, and savings gold and Nasdaq-100 orange by 1.34:1. A proposal is waiting for Dad's decision (below); nothing has changed yet.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db`: **707 of 707** (17 new in `notices_questions_test.sql`). They include:
    - dates either side of midnight on Nov 1, 2026;
    - paging, and "new" clearing once read;
    - questions with answers and dates;
    - who may call them.
  - `npm test`: **143 of 143**. That's 151 before, minus the 8 `albertaDate()` tests.
  - `npm run test:e2e`: **36 of 36**. New `transparency.spec.ts` (4 tests):
    - the notices list, against the database's dates, with marking read;
    - "How was this calculated?" against the line's working;
    - "Something looks wrong?", with Dad's answer arriving as a notice and in her questions;
    - asking about a waiting request.
  - Lint is clean and the build succeeds.
  - **Time machine not re-run:** part 2b only adds reads and screens, with no money logic. Its last run this session passed, 14 of 14.
- **For Dad to decide: option colours spread by lightness.** Same hues, with the lightness spread so every pair differs by at least 1.44:1, up from 1.19:1:

  | Option | Now | Proposed |
  |---|---|---|
  | Savings (gold) | `#E0A400` | `#E0A400` (same) |
  | Nasdaq-100 (orange) | `#F76B15` | `#F06008` (a little deeper) |
  | Dow Jones (blue) | `#2F80ED` | `#146DE4` (a little deeper) |
  | GICs (pink) | `#D6336C` | `#A82250` (deeper raspberry) |
  | TSX (teal) | `#0B6E69` | `#074945` (deep teal) |

  - **If he agrees:** a new migration for the fund colours, then `theme.css`, `colours.ts`, and a new test that every pair differs by at least 1.4:1.
  - **Before the graphs either way:** in 2c, each option will be named on the graphs too, so colour is never the only clue.
- **Dad to do by hand:** nothing. To try it, open **http://127.0.0.1:5173/Big-Bucks/** in Chrome and sign in as Sky. Then:
  - open the bell;
  - tap a history line (Home or **See all**);
  - tap **Something looks wrong?**.
- **Dad's review of 2b (2026-10-03): approved, with two changes, both done.**
  1. **Option colours spread by lightness** (migration `20261009010000_option_colours.sql`, `theme.css`, `colours.ts`):

     | Option | Was | Now |
     |---|---|---|
     | Savings | `#E0A400` | `#E0A400` (same) |
     | Nasdaq-100 | `#F76B15` | `#F06008` |
     | Dow Jones | `#2F80ED` | `#146DE4` |
     | GICs (fill and text) | `#D6336C` / `#B8255A` | `#A82250` |
     | TSX | `#0B6E69` | `#074945` |

     - **New test:** every pair of options differs by at least 1.4:1 (it was 1.19:1).
     - **Only the savings gold** still needs its outline.
  2. **Selling by typing the shown value** (migration `20261009000000_sell_shown_value.sql`; money logic, so known-answer tests came first and the time machine ran).
     - **The problem:** her units' value is shown to the nearest cent ($57.30). The engine refused anything above the exact value ($57.2866…), and its message quoted the value rounded down ($57.29).
     - **The rule now** (`sell_amount_is_all`): the shown value sells all of her units, and so does anything up to the exact value when that's a fraction of a cent higher. More is refused, quoting the shown value.
       - `request_trade` records such a sale as "sell all", holding every unit.
       - The preview adds a `sells_all` note.
       - Buy / Sell shows "Your TSX is worth about $57.30", the same as Home.
     - **Sell all at the same price pays at least the shown value,** because it's units × close, rounded up. For example, $57.1845 shown as $57.18 pays $57.19.
     - **The honest limit:** a sale settles at the next close, so if the price falls first, selling all pays less than was shown. A test proves this too: $57.18 shown, a close of $38.00, $55.44 paid.
     - **The rule is a little narrower than "up to the exact value rounded up":** with that, typing $100.01 on a holding worth exactly $100.00008 would have sold all, and an existing engine test rightly refuses that.
     - **SPEC "Stock funds"** records the rule, and MESSAGES §2 and §8 are updated.
  - **The time machine caught a gap in its own model,** not the database. The model treated a day's close as known from 3:30 pm, but the database (like production) gets it with the 4:30 pm nightly run. Comparing a sale with its value made the gap matter, so the model now has `knownClose()`, with its own test. Re-run result: **PASS, 14 of 14**, and 75 of 75 actions agreed.
- **Tests after the 2b review:**
  - `npm run test:db`: **728 of 728**. New in `sell_shown_value_test.sql` (21):
    - the shown value at two prices;
    - a cent under (a sale by amount) and over (refused);
    - proceeds at the same price;
    - a fall before the close;
    - the rule itself.
  - `npm test`: **146 of 146**: the lightness test, and the model's known close and the shown-value sale.
  - `npm run test:e2e`: **36 of 36**. The fund-sale test now also types the shown value and gets "sells all of it" and "Sell all of your TSX?".
  - `npm run timemachine`: **PASS, 14 of 14**.
  - Lint is clean and the build succeeds.
- **Part 2c, the six graphs: plan approved by Dad on 2026-10-03, not built yet. Build it next session.**
  - **Dad's answers:**
    1. **Growth %:** time-weighted. Each day's change ignores money moved in or out, so a deposit is never growth. "Money in vs money earned" already gives the simple view.
    2. **Layout:** one graph at a time, picked with tabs at the top (Total worth · Growth · Money in · Mix · GICs · Funds), on every screen size.
    3. **The $ / % switch:** only on growth by option and fund detail.
  - **Database:** one new migration, reads only, with known-answer tests first.
    - **`growth_by_option(account, from, to)`:**
      - Each day's time-weighted % gain for savings, GICs and each fund, plus the dollars earned (for $ / %).
      - GICs step up when they mature.
    - **`money_in_vs_earned(account)`:** each day's net deposits (deposits − withdrawals) and total worth.
    - **`my_mix(account)`:** savings, GICs and each fund, in whole percents that add up to exactly 100 (largest remainder, like Home).
    - **`gic_ladder(account)`:** each GIC from start to ready date, for the next 24 months.
    - **`fund_chart(account, fund, from)`:** the fund's daily closes, plus her buys and sells (date, price, amount).
    - **`market_notes(from, to)`:** the market-move notes in a range.
    - **Total worth over time:** uses the existing `daily_balances`, including the dots for money in and out.
  - **Screen (Graphs tab):**
    - **Recharts** (in the approved stack, about 150 KB), loaded only when Graphs opens, so the other screens stay fast.
    - **The graphs:**

      | Graph | Ranges | $ / % | Extras |
      |---|---|---|---|
      | Total worth over time (stacked area) | 1M / 3M / 1Y / All | $ | dots for deposits and withdrawals |
      | Growth by option (a line each) | 1M / 3M / 1Y / All | ✓ | dots |
      | Money in vs money earned | All | $ | the gap is what she earned |
      | My mix today (donut) | Now | % | |
      | GIC ladder (bars to each ready date) | Next 24 months | $ | |
      | Stock fund detail (price, her buys and sells marked) | 1M / 3M / 6M / since first purchase | ✓ | market-move notes |

    - **Every graph has:**
      - lines named on the graph itself (never colour alone);
      - one sentence on what it shows;
      - a **?** for key words;
      - **Show as a table** (every number readable without seeing the graph);
      - keyboard and screen-reader support;
      - a layout that fits from 360 px to desktop with large text.
    - **Wording:** in MESSAGES.md §10.
  - **Tests:**
    - **pgTAP** known answers for each function: a deposit isn't growth, the mix adds to 100, GIC growth steps up at maturity, and buy and sell points match the trades.
    - **Vitest:** ranges and data shaping.
    - **Playwright:** each graph against the database (the last total-worth point equals Home's), the ranges, the $ / % switch, the table view and the notes; plus the layout and accessibility checks on Graphs.
    - **Time machine:** a run before stopping.
  - **Then stop for Dad's review.** That ends stage 7: the full stage 7 entry, with the ACCEPTANCE.md boxes.

- **Part 2c, the six graphs: built and reviewed (2026-10-03).** Dad's review and the changes are at the end of this entry.
- **Migration `20261010000000_graphs.sql`** (new; reads only, no money rule changed):
  - **`graph_ranges(account)`:** today, her first day, where each range starts (1M, 3M, 6M, 1Y, All), each fund's first purchase, and the GIC ladder's end (today + 24 months). Total worth and growth never start before her first day; a fund's price goes further back.
  - **`growth_by_option(account, from, to)`:** each day's time-weighted growth for savings, GICs and each fund, the dollars earned, and the money moved in or out (for the dots). The rule, now in SPEC "Graphs & dashboards":
    - growth is interest for savings and GICs (a penalty counts as a loss), and for a fund its change in value plus the dividends it paid;
    - money moved in or out is never growth (a deposit, a buy, a GIC bought from savings, a matured GIC moving back);
    - each day is measured against the end of the day before (interest and dividends post at the start of a day; trades settle at the close, after the day's move); on an option's first day, against the money that came in;
    - a range starts at 0%.
  - **`money_in_vs_earned(account)`:** each day since her first: net deposits, total worth, and the gap (what her money earned).
  - **`my_mix(account)`:** savings, GICs and each fund she holds, in whole percents adding to exactly 100 (largest remainder, ties in screen order).
  - **`gic_ladder(account)`:** her active GICs and any matured one waiting for her choice ("ready"), soonest first.
  - **`fund_chart(account, fund, from)`:** the fund's closes (each with its % change since the range's first close), her buys and sells (day, price, units, money), the fund's market-move notes, her growth in the range (the same measure as the growth graph) and what she holds now (Home's "since first purchase" figures).
  - **Glossary:** two new words, **Growth** and **Money earned** (in `docs/GLOSSARY.md` for review).
  - **Who can call them:** a kid sees only her own account; a parent needs the authenticator code; signed-out visitors can't.
  - **Changed from the plan:** the separate `market_notes(from, to)` became part of `fund_chart` (the notes are only shown there), and `graph_ranges` was added so the app never works out a range's start date itself.
- **Screen `src/kid/graphs/`** (the Graphs tab):
  - **`Graphs.tsx`:** six tabs at the top (three across on phones, six from 720 px; arrow keys, Home and End move between them). One graph at a time.

    | Graph | Ranges | $ / % | Drawn as |
    |---|---|---|---|
    | Total worth over time | 1M / 3M / 1Y / All (3M first) | $ | stacked areas, with dots on days money came in (filled) or went out (hollow) |
    | Growth by option | 1M / 3M / 1Y / All | ✓ (% first) | a line each, with the same dots on the line the money moved |
    | Money in vs money earned | All | $ | total worth over money in (a step line), with a sentence on what she's earned |
    | My mix today | Now | % | a donut, with each option's % and dollars |
    | GIC ladder | next 24 months | $ | a bar per GIC from today to its ready date (gold when ready now) |
    | Stock fund detail | 1M / 3M / 6M / since first buy | ✓ ($ first) | the unit price, ▲ her buys, ▼ her sells, ◆ big market days, her return, the trades and notes listed |

  - **Every graph has:** one sentence on what it shows; "Words to know" with each word beside its **?**; a key naming every colour with today's figure; a tooltip; **Show as a table** (newest day first; on narrow screens each row becomes a small card of "label: value" lines, so nothing scrolls sideways).
  - **Never colour alone:** names in the key and tooltips, line patterns (GICs dashed, TSX long-dashed), and the savings gold always has its dark outline (as a 2-tone line, an outlined area, or an outlined slice).
  - **Recharts** is loaded only when Graphs opens: its own 415 KB file (`Graphs-….js`); the other screens' file didn't grow.
  - **`graphData.ts`:** reshaping only (no money arithmetic or date working). Percents keep the database's two decimals ("+19.90%", not "+19.9%").
  - **`graphText.ts`:** all the words, in **`docs/MESSAGES.md` §10**.
- **Demo:** the Nasdaq-100 now jumps 3% about 15 market days before the end (and stays up), so a market-move note shows on the fund graph (Sep 14 in today's demo). Made-up prices, in the demo only.
- **Found and fixed while trying it in the browser:**
  - "+19.9%" now reads "+19.90%" (JSON drops the trailing zero).
  - A dotted Nasdaq-100 line looked fuzzy on a bumpy line; funds are solid now, with the TSX long-dashed.
  - Two **?** side by side didn't say which word each explained; each word now sits beside its **?**.
  - A screen reader read the mix key as "Savings49%"; there's a space now.
- **SPEC:** "Graphs & dashboards" records the growth rule.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **769 of 769**, after `supabase db reset`. That's 728 before plus 41 new in **`graphs_test.sql`**:
    - **A deposit isn't growth:** in a month with a deposit, a GIC, two fund buys, a dividend and a sale, savings grew 0.00%.
    - **The Dow, worked by hand:** +10%, a second buy (not growth), −10%, a $4.95 dividend, then a sale-day rise: 1.10 × 0.90 × 1.0111… × 1.0101… = **+1.11%**, while **−$15.05** was earned (the bigger second buy caught the drop). A range from Oct 7 starts at 0% and reads −10.00%, then −9.00%.
    - **GICs step up at maturity** (+$0.21, 0.21%), and moving the money to savings is a flow, not a loss. **Savings:** $0.89 of interest on $884.95 is +0.10%.
    - **The dots:** every flow in and out of savings and the Dow, on the right days.
    - **Money in vs earned:** known answers on four days, the last point equals `account_balances` (Home's total), and what she earned equals the growth graph's dollars added up.
    - **The mix:** 24.99%, 49.98% and 25.04% become 25, 50 and 25, adding to 100.
    - **The ladder:** a matured GIC shows as ready, then leaves once moved; two GICs soonest first, with $3.38 and $12.00 interest.
    - **The fund chart:** her three trades, closes with their %, the two market-move notes, her range growth (the growth graph's), what she holds, an unknown fund refused.
    - **Who may call:** kid B can't read kid A through any of the six; a parent needs the code; signed-out visitors can't.
    - `kid_home_test.sql`'s glossary count is now 54 (52 plus the two new words).
  - `npm test` (Vitest): **161 of 161** (15 new in `graphData.test.ts`: ranges, row shaping, the ladder bars, price and percent formats, and the wording).
  - `npm run test:e2e` (Playwright): **41 of 41**. New `graphs.spec.ts` (5 tests, as Robin, each against the database): total worth (the last point equals Home's total, the 1M and All ranges, the table and a money-in day); growth (each option's % and then $ against `growth_by_option`, and the table); money in vs earned, the mix (adds to 100) and the ladder; the Nasdaq-100 detail (her trades, the market-move note, % in the table, "since your first buy"); and the tabs from the keyboard. `layout.spec.ts` now checks all six graphs, the growth table open and a fund with its note, at all six sizes with normal and 130% text: no problems. The graphs tests only read, so they run first with the layout checks, before other tests change the demo.
  - `npm run timemachine`: **PASS, 14 of 14** (75 of 75 actions agreed; graph history matched every day). No money logic changed in 2c; it was run as planned.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes:** none can be ticked yet (they need the live app). Now visible locally: "The standard note appears on a day a fund moves more than 2%" shows on the fund graph.
- **For Dad to look at in the review:**
  1. **Two returns can point different ways.** In the hand-worked example, the Dow's growth is +1.11% while she lost $15.05: she put more in just before the drop. Time-weighted % (Dad's choice) measures the fund; dollars measure her timing. The fund graph shows both in one line ("Your Dow Jones in this time: −$15.05 (+1.11%)"). It's honest, and maybe a good talking point, but it could confuse. Options: keep it; show only the one matching the $ / % switch; or add a sentence when they differ.
  2. **Money in vs money earned starts at $0,** so a small gap (Robin's $21.64) is a thin sliver. Starting the scale higher would make the gap look bigger than it is, so I kept $0. Say if you'd rather zoom in.
  3. **The colour checker** (the chart skill's palette validator) passes the options for colour-blind separation, but flags the deep TSX teal as "reads grey" and too dark for its band. That's the colour you chose for lightness spread in 2b; the names, the long-dashed TSX line and the tables cover it. No change unless you want one.
  4. **Savings interest steps once a month** on the growth graph (it posts on the 1st), so savings isn't perfectly smooth. Showing daily accruals would make it smooth but would show interest that isn't hers yet.
- **Dad to do by hand:** nothing. To try it: `npm run demo`, then open **http://127.0.0.1:5173/Big-Bucks/** in Chrome, sign in as Robin or Sky, and tap **Graphs**. On **Funds**, pick **Nasdaq-100** to see a market-move note.
- **Dad's review of 2c (2026-10-03): approved, with these changes, all done:**
  1. **% and $ on the fund graph:** both kept, labelled apart: **The fund's change while you had it** (time-weighted %) and **Your money's change** (dollars). When they point opposite ways, one plain sentence explains it's timing (she had more money in on the down days, or the up days). "Since I bought" shows **Worth now**, **You paid** and **Your money's change**. The whole-fund line now reads "Over the whole time shown, the {fund} fund went up {percent}." Wording in MESSAGES §10.
  2. **Money in vs money earned:** the scale still starts at $0; **Money earned so far** and the amount (like **+$21.64**) now sit above the graph in big text, with a shorter sentence under it so the number isn't said twice.
  3. **TSX teal:** kept as `#074945` (Dad's choice).
  4. **Savings steps:** kept; the growth graph now says "Savings interest arrives on the 1st of each month, so the savings line steps up a little then." when she has savings.
  - **The made-up Nasdaq-100 jump is demo-only:** it's made in `scripts/local/demo.ts` at run time and written straight into the local database. No migration or seed file inserts any price (only the price job, stage 4, will write prices in production). The demo refuses to run unless the API is `http://127.0.0.1:54321`, the database is the local one (port 54322) and it says `is_local_dev = true`, a setting only the local seed file adds (`supabase db push` doesn't run seeds).
  - **Tests after the review:** Vitest has 16 graph tests (the labels, both "why" sentences, no sentence when they agree or one is zero, the whole-fund line and the new note). The Playwright graphs tests now check the big amount and its note, both fund labels against `fund_chart`, and "Since your first buy" showing what she paid. Final results are in the stage 7 entry above.

### Alberta time-zone fix, local only (2026-10-03)

- **Why:** Alberta stays on UTC−6 all year from November 1, 2026 (Official Time Act). The local Postgres still has the old rule and would turn Alberta to UTC−7 on Nov 1. Production's may do the same. Details are under stage 7 part 1 below.
- **Decisions Dad made:**
  1. The glossary and spec wording for the market close (below).
  2. The nightly run moves to **4:30 pm Alberta time, all year**. That's 90 minutes after the latest close (3:00 pm in winter).
  3. SPEC "Build decisions" now says: if Alberta's rule ever changes again, write a new migration to the pinned rule, then do a time machine run.
- **Built:**
  - **`20261006000000_alberta_time.sql`** (new; no committed migration was edited):
    - **The pinned rule:** `edmonton_local(moment)` and `edmonton_at(clock time)`. From 2026‑03‑08 09:00 UTC on, Alberta is UTC−6, worked out with plain arithmetic. Earlier moments use the server's history.
    - **Recreated functions:** `app_now`, `app_today`, `edmonton_start`, `fmt_moment`, `request_trade`, `send_rate_notices`, `run_daily`, `fund_return`, `reconcile_account` and `my_activity`, copied from their latest versions. Only the time-zone conversion changed.
    - **Closes stay in Toronto time:** 4:00 pm, or the early-close time. In Alberta a close is now **2:00 pm** (early: 11:00 am) from the second Sunday in March to the first Sunday in November, and **3:00 pm** (early: 12:00 pm) the rest of the year. Messages such as "settles Nov 2 at 3:00 pm" follow automatically.
    - **Glossary "Market close":** "The end of the stock market's day, at 4:00 pm in Toronto. In Alberta that's 2:00 pm from March to early November, and 3:00 pm the rest of the year. …"
    - **`check_time_rules()`:** the production check (see "Dad to do by hand"). It gives 20 known answers plus one information-only row about the server's own time-zone data. Only the database owner can run it.
  - **Browser:** the notices list no longer uses the phone's time-zone data. `albertaDate()` in `src/lib/format.ts` applies the same pinned rule.
  - **Time machine:**
    - **The reference model** now has its own Toronto clock-change rule and Alberta's UTC−6. Closes are the Toronto close converted, written separately from the database code.
    - **4:30 pm run:** the run happens at `NIGHTLY_RUN` = 4:30 pm. `jobs:local` and the demo now use 4:30 pm too.
    - **New scenario trades:** at 2:30 pm on the weekdays either side of Nov 7, 2027 and Mar 12, 2028.
    - **Early closes:** these settle at 12:00 pm in winter.
    - **Moved to 5:00 pm:** steps that must come after the nightly run.
  - **Docs:**
    - SPEC: nightly job, settlement, day-count and Build decisions (time and dates).
    - GLOSSARY.md.
    - BUILD-PLAN: stage 4's cron window, the new check step and the stage 7 wording.
    - ACCEPTANCE: two new boxes.
- **Tests:**
  - `supabase test db`: **634 of 634 passed**.
    - **New `alberta_time_test.sql`** (45):
      - the pinned rule either side of Nov 1, 2026 and the 2026 history;
      - the clock override across Nov 1;
      - closes on both sides of each Toronto clock change;
      - 2:30 pm settlement in summer and winter;
      - one trade per fund per Alberta day at midnight in winter;
      - activity dates at New Year;
      - `check_time_rules()`;
      - a guard that fails if any other function or view names `America/Edmonton`.
    - **Changed known answers:**
      - Winter noon is 18:00 UTC.
      - Winter closes are an hour later than before (3:00 pm, and 12:00 pm for early closes).
      - The early-close "after" request moved from 11:30 am to 12:30 pm.
      - Tests that run the nightly jobs now set the clock to 4:30 pm.
  - `npm test` (Vitest): **138 of 138 passed**. New tests cover the model's clock rules, its closes either side of each clock change, and `albertaDate()`.
  - `npm run test:e2e` (Playwright): **25 of 25 passed**.
  - `npm run timemachine`: **PASS, 14 of 14**. 75 of 75 actions agreed with the model, including the 4 new trades either side of the clock changes. 367 nightly reconciles found no problems. The report is regenerated in `docs/TIMEMACHINE-REPORT.md`.
  - `npm run lint` is clean and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:** none can be ticked yet (live). Two new boxes were added: settlement times in summer and winter, and `check_time_rules()` on production.
- **Known issues:**
  - The notices list still reads a timestamp from a table. Stage 7 part 2 should take its dates from the database, like Home does.
  - Toronto times still use the server's `America/Toronto` data. Its rules haven't changed since 2007, and `check_time_rules()` confirms them.
- **Dad to do by hand:**
  - Nothing now.
  - **At stage 4**, right after pushing migrations to production:
    1. In the Supabase Dashboard, open **SQL Editor**.
    2. Run `select * from public.check_time_rules();`.
    3. Every row should show ok = **true**, except the last, information-only row (ok is empty), which only says whether production's own time-zone data is up to date. Any **false** row means stop and tell Claude.

### Stage 7, part 1 — Kid Home and the GIC choice, local only (2026-10-03)

- **The plan Dad approved:** Stage 7 runs in two parts. Part 1 is Home, including the GIC choice flow and the full history page because Home links to both, and then a stop for Dad's review. Part 2 covers everything else.
- **New standing rule in CLAUDE.md** ("Screens and layout"):
  - Every screen, kid or parent, must work from 360 px phones to desktop, portrait and landscape, foldables included, with Android's large text on.
  - Nothing may be cut off or overlap.
  - Each stage tests at small phone, tablet and desktop sizes.
- **Decisions Dad made:**
  1. **Option colours:**
     - Savings is gold `#E0A400` and GICs are pink `#D6336C`. Gold is for fills and bars only, never text on white.
     - Every colour pair must meet contrast rules.
  2. **Funds on Home:** all three funds show, with "You don't own any yet" on the ones she doesn't hold.
  3. **Up and down days:**
     - ▲ or ▼ with words, in calm colours, never red.
     - A down day must be as clear as an up day.
     - The daily change gets a **?** saying markets go up and down and one day doesn't matter much.
  4. **The GIC choice screen** says plainly what happens if she doesn't choose by the date, in the maturity notice's own words.
  5. **After the review:** Home approved with no changes.
- **Built:**
  - **Migration `supabase/migrations/20261005000000_kid_home.sql`.** Read functions; a kid can only ask about her own account, and a parent needs the authenticator code.
    - **`fund_overview(account)`:** each fund's name and colour, her units, value, cost and gain, and the latest and previous closes.
      - **Daily change:** the fund's % change between its two latest closes up to today.
      - **Her mix:** whole percents, using the largest-remainder method, so they always add up to exactly 100.
      - **Sparkline:** the last 30 closes.
    - **`my_activity(account, limit, before)`:** her history, newest first, for Home and "See all".
      - **One line per event:** the two ledger rows of a move are grouped by their shared posting key.
      - **Requests included:** pending, declined (with Dad's reason) and expired requests are listed too.
      - **Dates and paging:** each line carries its Edmonton date (`on_day`), worked out by the database. Paging continues after a given line.
    - **`current_rates()`:** today's savings and GIC rates. A special wins inside its dates, and any announced change shows with its date.
    - **`mark_notices_read(ids)`:**
      - A kid marks only her own notices as read.
      - The first time she read one is kept.
      - Dad can't mark them, because his dashboard shows whether she has read them.
    - **The "Daily change" glossary text** is reworded as Dad asked. `docs/GLOSSARY.md` is updated to match.
  - **Home** (`src/kid/home/`):
    - **Order on the page:** total worth first, then the banner, then the savings, GICs and funds cards, then recent activity.
    - **Banner:** a "Your GIC grew!" card for a waiting GIC, plus the newest unread notice with **Got it**. GIC "ready" notices aren't repeated, because the waiting GIC has its own card.
    - **Savings card:** on hold and free to use (while a request is holding money), today's rate, and any announced change.
    - **GICs card:** each GIC with its locked rate, a progress bar, its ready date and what it earns by then. A matured one shows **Choose**.
    - **Funds card:** the mix bar and legend, and all three funds' last market day with ▲, ▼ or ● and a 30-day sparkline.
    - **Recent activity:** the last 5 lines and **See all**.
    - **"Updating…"** replaces every amount while the nightly check is fixing something.
    - **Layout:** one column on phones and two from 840 px, capped at 1100 px wide. Sizes are in rem so large text scales.
  - **GIC choice** (`/kid/gic/:id`):
    - She chooses **Keep it growing**, **Try a different length** or **Move it to savings**.
    - She sees the deadline and what happens without a choice.
    - A summary comes before **Yes, do it**, including what the new GIC will earn, worked out by the database's `gic_interest_cents`.
    - Then `choose_maturity` runs, and that GIC's maturity notice is marked read.
  - **History** (`/kid/history`): her whole history, 30 lines at a time, with **Show more**.
  - **Colours** (`src/lib/colours.ts`, with the tokens in `theme.css`):
    - Every text and shape pair is checked against WCAG 2.2 AA.
    - Gold and the existing Nasdaq-100 orange are too light to stand out on white (2.2 and 2.97 : 1), so every coloured shape gets a dark outline (`--bb-outline`).
    - GIC pink text uses `#B8255A`, because `#D6336C` falls just short on the page background.
    - Up `#15693D` and down `#6A4C9C` are equally strong, both about 6.7 : 1.
    - The total-worth panel's gradient fades to a deeper purple, so the gold tagline keeps its contrast.
  - **Display formats** (`src/lib/format.ts`):
    - Rates, dates and GIC terms match the database's own formats exactly: "2.5%", "Oct 7", "1-year".
    - The browser never converts times into dates; every date comes from the database.
  - **The ? on purple:** a light version (`<Explain light>`).
  - **Demo:**
    - The demo kids have read their notices from more than 3 days ago, so the banner looks realistic.
    - The second rate-cut note no longer repeats the engine's own tip.
  - **Tests:**
    - Test files are type-checked with Node's types (`tsconfig.test.json`); the app itself is not.
    - The end-to-end tests now run in two Playwright projects. The `layout` project runs first, while Robin's GIC is still waiting for her choice, and the rest run after it.
  - **Wording:** all new kid-facing wording is in **`docs/MESSAGES.md` §7**.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **589 of 589 passed**, in 15 files, after `supabase db reset`. That's the 547 earlier tests plus 42 new ones in `kid_home_test.sql`:
    - each fund's units, value, daily change, mix (57 / 32 / 11 from 56.47 / 32.40 / 11.13) and sparkline;
    - a kid with no funds still sees all three funds;
    - only closes up to today count;
    - history lines with their amounts, terms, rates, units and prices, and paging with nothing repeated or missed;
    - isolation: kid B and a parent without the code are refused;
    - rates with a special and an announced change;
    - marking notices read, own notices only;
    - grants;
    - the glossary text.
  - `npm test` (Vitest): **126 of 126 passed**. New: contrast for every colour pair, plus the stylesheet scan for gold text; display formats; history wording.
  - `npm run test:e2e` (Playwright): **25 of 25 passed**.
    - **New in `home.spec.ts`:**
      - Home matches the database to the cent;
      - **Got it** marks a notice read;
      - **See all**;
      - renewing Robin's GIC from start to finish, with the deadline wording, the summary and the database result.
    - **New in `layout.spec.ts`:** Home, history and the GIC choice are checked at 360×780, 412×915 (Galaxy A17), 673×841 (unfolded foldable), 800×1280 and 1280×800 (tablet), and 1440×900 (desktop), each with normal and 130% text.
      - It fails if the page scrolls sideways, anything sticks out or is cut off, side-by-side items overlap, or a button is under 44 px.
      - It saves 36 full-page screenshots to `test-results/layout/`.
  - `npm run timemachine`: **PASS, 14 of 14**. `npm run lint` is clean, and `npm run build` succeeds.
- **Next task, before part 2: the Alberta time-zone change.**
  - **What changed:** Alberta's Official Time Act (passed June 18, 2026) keeps the province on UTC−6 all year from **November 1, 2026**; clocks no longer go back. IANA time-zone data 2026c (July 8, 2026) changed `America/Edmonton` to match.
  - **Found by:** the new date tests. Node (tzdata 2026c) already shows Edmonton as UTC−6 in winter, but the local Postgres (17.11) still switches to UTC−7 on Nov 1, 2026. Production's Postgres may lag the same way.
  - **What would go wrong from Nov 1:**
    - `app_today()` and `app_now()` would start Edmonton's day an hour off.
    - The 4:00 pm Eastern market close is 3:00 pm Alberta time in winter, not 2:00 pm, which affects the "settles at the 2 pm close" wording and the nightly schedule (3:30 pm) for stage 4.
    - The time machine's independent model assumes the old clock changes.
    - The browser and the database could disagree about which day a time falls on.
  - **Already safe:** settlement times are worked out in Eastern time, so which close a trade settles at is still right. Home takes every date from the database.
  - **Recommended fix** (a short task of its own):
    1. Pin the app's own time rule in the database rather than trusting each server's time-zone data.
    2. Update the reference model and the clock tests, and add known-answer tests across Nov 1, 2026.
    3. Review every message that says "2 pm", and stage 4's cron window.
    4. Re-run the time machine.
- **Left for part 2:**
  1. **Graphs:** total worth over time (stacked area) and growth by option, with 1M / 3M / 1Y / All, a $ / % switch, dots for deposits and withdrawals, and the market-move notes. Recharts is added here.
  2. **Buy / Sell:**
     - from and to choices, always through savings;
     - the amount, with the available balance and cap room;
     - every spec warning: the early-break loss in dollars, a fund worth less than she paid, over the available balance, one trade per fund per day, and when it settles;
     - a confirmation summary.
  3. **Transparency:** "How was this calculated?" on interest, dividend and penalty lines (the working is already in each line's note), and "Something looks wrong?" on any line, starting a question thread.
  4. **The notices list:** reading marks them read.
  5. **Accessibility pass** across all kid screens.
  6. **Playwright tests:** a deposit request, buying a GIC, the early-break warning, a trade request and sending a question. The layout test gets extended to the new screens.
  7. **PROGRESS.md** with the full stage 7 entry and the ACCEPTANCE.md boxes.
- **Known issues and notes:**
  - **Full-page screenshots** show the fixed bottom tabs part-way down the page. That's how such captures work; on a device the tabs stay at the bottom.
  - **Fund names** for history lines are also listed in `activityText.ts` (`FUND_NAMES`). They match the `funds` table; if a fund is ever renamed, change both.
  - **The end-to-end tests reload the demo** (new PINs). Run `npm run demo` for a clean set afterwards.
- **Dad to do by hand:** nothing. Optional: review the new wording in **`docs/MESSAGES.md` §7**.

### Stage 6 — Logins, the installable app and the app shell, local only (2026-10-03)

- **Decisions Dad made:**
  1. **Build order is now screens first:** stages 6 → 7 → 8 run against the local database only, then 4 → 5, then the solo beta. Recorded in `docs/BUILD-PLAN.md` ("Build order") and the status above. Deploying, installing on the phone and creating real accounts all move to after stage 4.
  2. **Demo kids:** Robin is a regular account and Sky is a test account (`is_test`), like the time machine. So the parent dashboard shows both the liability total and the test-accounts list.
  3. **The end-to-end tests may reload the demo,** but Claude says so each time, because it signs you out and changes the demo PINs.
  4. **`npm run jobs:local`** was added: synthetic closes, then the nightly job and reconcile, for today.
  5. **The kid login remembers the last username on the device,** with a "Not you?" link to switch.
- **Built:**
  - **Migration `supabase/migrations/20261004000000_logins.sql`.** Four functions, all server only (service role). They're not callable from the app.
    - **`create_kid_account(user, username, display name, is_test)`:** creates her account and profile.
    - **`create_parent_profile(user, username, display name)`:** creates the parent's profile.
    - **`login_precheck(username)`:** says whether it's a kid, gives her hidden email, and reports any lock.
    - **`record_login_attempt(username, succeeded)`:** records the try and applies the lockout.
    - **The lockout:**
      - 5 wrong PINs in a row lock the username for 15 minutes.
      - A right PIN resets the count, and so does the end of a lock.
      - While locked, nothing is checked or recorded, even a right PIN.
      - Each lock raises one `lockout` alert. It fails the health check, so GitHub will email you once stage 4's check runs. A test account's alert is quiet.
      - Unknown usernames and the parent's username lock the same way. Usernames ignore capitals and spaces and are cut to 40 characters.
  - **`supabase/config.toml` (local settings):**
    - public sign-up is off;
    - authenticator-app MFA (TOTP) is on;
    - `kid-login` runs without a signed-in user;
    - the local sign-in rate limit is raised to 300 per 5 minutes, because every kid login shares the function's address.
    - The email provider must stay on: in Supabase, its "sign-up" switch also turns off email logins. Production gets the same settings in stage 4's runbook.
  - **Edge Function `supabase/functions/kid-login`:**
    1. Checks the username and lock (`login_precheck`).
    2. Tries the PIN as her Supabase password.
    3. Records the try (`record_login_attempt`).
    4. Returns a normal Supabase session.
    - A wrong PIN, an unknown username and the parent's username all get the same answer. An Auth outage isn't counted against her.
  - **The app** (one new dependency, `@supabase/supabase-js`):
    - **Kid login** (`src/pages/KidLogin.tsx`):
      - Asks for her username once, then shows a big PIN pad with 76 px keys. It submits by itself at the 6th digit.
      - Remembers her username and name on the device (never the PIN), so she sees "Hi, Robin!" and only enters her PIN. "Not you?" forgets it.
      - Kind messages; the wording is in `docs/MESSAGES.md` §6.
    - **Parent login:**
      - Email and password, then the authenticator code.
      - The first sign-in sets the authenticator up: a QR code, a typeable key, then a code to confirm.
    - **Route guards** (`src/App.tsx`):
      - Parent screens need a parent with the code done (aal2).
      - A kid session is always sent back to her Home, even from the parent login page.
      - A parent without the code is sent to the code step.
    - **Kid shell:**
      - Bottom tabs Home, Graphs and Buy / Sell, plus Wish List only when `feature:wishlist` is on for her. The demo turns it on for test accounts, so Sky sees it and Robin doesn't.
      - A notifications bell with the unread count, and a read-only notices list.
      - **Home** shows her total worth, with the **?** and "Updating…". The other screens are placeholders for stage 7.
    - **Shared pieces:**
      - **`<Explain term>`:** the **?** button and card, reading the glossary from the database.
      - **`<Updating>`:** the "Updating…" state.
      - **The "You're offline" screen:** shown whenever the phone is offline, and data is never cached.
      - **`formatCents()`:** in `src/lib/money.ts`, using whole-number maths only. It refuses fractions and unsafe numbers.
    - **Parent shell:** its own header and tabs. The Dashboard lists each kid's total worth, with test accounts marked. Settings is a placeholder for stage 8.
    - **PWA:** the manifest already had the name, theme colour #5B3FD1 and icons (maskable included). A test now checks it.
  - **Local-only scripts** (`scripts/local/`). All refuse anything but the local Supabase: the API must be `127.0.0.1:54321`, plus the time machine's database guard.
    - **`npm run demo`:**
      - Resets the local database.
      - Creates "Dad", Robin and Sky with real logins. The PINs and the password are random on every run.
      - Walks 92 days ending yesterday evening, with the time machine's price generator and clock. Every action goes through the real kid and parent functions, with `run_daily` and `reconcile` each day at 3:30 pm. It stops on any reconcile problem or alert.
      - Clears the clock override, sets up the parent's authenticator, writes `.env.local`, and prints the logins. They're also saved to `.demo-logins.local`, which is gitignored.
      - **The demo history includes:**
        - deposits approved, one declined with a reason, and a withdrawal approved after 24 hours;
        - a GIC renewed, then moved to savings;
        - a 1-month GIC that matured 2 days ago and is waiting for Robin's choice;
        - 6-month GICs;
        - buys in all three funds, a partial sale and a sell-all;
        - monthly interest, and dividends on Oct 1;
        - a savings-rate cut, plus another announced for next week;
        - a question Dad answered;
        - a pending deposit, and a pending withdrawal from last night with its 24-hour wait running.
    - **`npm run demo:code`:** prints the demo parent's current authenticator code.
    - **`npm run jobs:local`:** tonight's run by hand. It adds synthetic closes, then runs `run_daily` and reconcile, through today after 3:30 pm Edmonton time or through yesterday before then.
    - **`npm run setup-account`:** asks for the role, display name and username, then a hidden PIN typed twice (or email and password for a parent), and whether it's a test account. Nothing is written to the repo.
    - **`npm run env:local`:** points the app at the local Supabase.
    - The demo and `jobs:local` share the nightly step (`scripts/local/nightly.ts`). The time machine itself is unchanged.
- **Tests (all run locally on 2026-10-03):**
  - `npm run test:db` (pgTAP): **547 of 547 passed**, in 14 files, after `supabase db reset`. That's the 502 earlier tests plus 45 new ones in `logins_test.sql`:
    - who may call the four functions;
    - creating accounts, with duplicates and bad usernames refused;
    - the lookup;
    - the lockout to the minute: 4 failures don't lock; the 5th does; the right PIN is refused while locked and nothing is recorded; 15 minutes later it unlocks and the count starts again; a success resets the count;
    - the alert wording, and a quiet alert for a test kid;
    - unknown and parent usernames;
    - odd input.
  - **Mutation check:** I changed the lockout to 6 tries in the live local database. 12 tests failed. Then I rebuilt the database from empty.
  - `npm test` (Vitest): **58 of 58 passed**:
    - `formatCents` (22);
    - authenticator codes against the RFC 6238 test vectors (9);
    - the local-only guard and synthetic closes (10);
    - the 17 reference-model tests. The old placeholder-screen test went with the placeholder screen.
  - `npm run test:e2e` (Playwright, Pixel 7, production build against the local Supabase): **15 of 15 passed**, twice in a row:
    - **App:**
      - a signed-out visit starts at the kid login;
      - deep links work;
      - the offline screen appears and goes away;
      - the manifest is installable.
    - **Kids:**
      - Robin signs in and sees Home, the tabs, the bell and the **?**;
      - Sky sees the Wish List tab;
      - the remembered username, and "Not you?";
      - a wrong PIN gets a kind message;
      - **5 wrong PINs lock**, even for the right PIN;
      - **a kid can't reach `/parent`, `/parent/settings`, `/parent/mfa` or `/parent/login`**;
      - the PIN door refuses the parent's username;
      - signing out on one device leaves her other devices signed in.
    - **Parents:**
      - **a new parent's first-time authenticator setup** (a wrong code refused, then the dashboard);
      - the demo parent signs in with the code;
      - **a parent without the code is blocked on screen and in the database:** `liability_total` and `approve_request` are refused (403), and accounts and alerts come back empty.
  - `npm run timemachine`: **PASS, 14 of 14**.
  - `npm run lint` is clean, and `npm run build` succeeds.
  - **Safety:** `npm run demo` and `npm run jobs:local` pointed at a hosted Supabase address both refused before touching anything.
- **ACCEPTANCE.md boxes now testable:**
  - **Proven locally, and live once stage 4 sets up production:**
    - "Each girl logs in with her username and PIN".
    - "Five wrong PINs lock the login for 15 minutes and alert Dad". The alert is in `alerts` and fails `health_check()`. The email itself comes with stage 4's GitHub check.
    - "Dad's login requires the second factor".
  - **"Security tests pass…":** now also proven through real logins (the kid and no-code parent tests above).
- **Known issues and notes for later stages:**
  - **Stage 4 (production):**
    - **Auth settings, in the runbook:**
      - turn off "Allow new users to sign up";
      - keep the Email provider on;
      - turn on TOTP MFA;
      - deploy `kid-login` with `--no-verify-jwt`;
      - review the sign-in rate limit (300 is a local-only value).
    - **Then:** deploy to GitHub Pages with the production URL and anon key; widen `npm run setup-account`'s guard to production on purpose; install on your phone; create the real accounts.
  - **Stage 7:**
    - The notices list is read-only, so marking notices as read still needs its small kid function.
    - Home, Graphs and Buy / Sell are placeholders.
    - `useKidSummary` already loads total worth, "Updating…", the Wish List switch and the unread count.
  - **Stage 8:**
    - The dashboard placeholder lists each kid's total worth.
    - Lockout alerts (kind `lockout`) need to appear in the alert list with an Acknowledge button.
  - **The end-to-end tests add two throwaway logins:**
    - "Lockout Test", a test kid;
    - "New Parent", a parent with no data of its own.
    - Run `npm run demo` for a clean set.
  - **The database tests expect an empty database** (as in stage 3). After the demo, run `npm run db:reset` before `npm run test:db`.
  - **The parent and a kid share one sign-in per browser.** On one computer, use a normal Chrome window for a kid and an Incognito window for the parent. On the phones this won't matter: the kid uses Chrome and you use another browser, as planned.
  - **The guard's refusal message** says "the time machine only runs against the local database" even when it comes from the demo, because they share the guard.
- **After the first review (Dad's changes):**
  - **`npm run dev` listens on `127.0.0.1`**, port 5173, and `vite preview` on `127.0.0.1:4173` (`vite.config.ts`). On Dad's computer Chrome forces https for "localhost" (HSTS), so the app is opened at **http://127.0.0.1:5173/Big-Bucks/**. Playwright uses `127.0.0.1` too.
  - **The girls' devices** (now in the status at the top): a Samsung Galaxy A17 phone and Samsung Galaxy tablets.
    - **Stage 7 onwards:** each screen must be checked at phone size and at tablet size in both orientations.
    - **The Stage 6 shell:** it already stretches to any width. On a tablet, the bottom tabs span the full width and the cards fill the screen.
    - **Stage 7:** it should cap the content width (or use two columns) on tablets, and add tablet sizes to the Playwright projects.
  - **Sign-out now affects this device only.** The full test run found it: Supabase's sign-out ends every session by default, so a girl signing out on her tablet would also have been signed out on her phone. A new test covers it.
- **Dad to do by hand:** nothing required. Optional: review the new wording in **`docs/MESSAGES.md` §6**.
- **Try it in Chrome at phone size:**
  1. Make sure Docker Desktop is running. If the local Supabase isn't up, run `npm run db:start`.
  2. Run `npm run demo` if you need fresh logins. It prints them, and they're also saved in `.demo-logins.local`, which isn't committed.
  3. Run `npm run dev`, then open **http://127.0.0.1:5173/Big-Bucks/** in Chrome.
  4. Press **F12**, then **Ctrl+Shift+M** (device toolbar). In the **Dimensions** menu, choose **Pixel 7**, or add the Galaxy sizes with **Edit…**.
  5. **As a kid:** type `demo_robin`, tap **Next**, then tap her PIN. Try the **?** and the bell, then **Sign out**: next time it's "Hi, Robin!" with the PIN pad only.
  6. **As the test kid:** tap **Not you?** and sign in as `demo_sky`. She also has the **Wish List** tab.
  7. **As the parent:** open an Incognito window (**Ctrl+Shift+N**), turn on the device toolbar again, and go to **http://127.0.0.1:5173/Big-Bucks/parent/login**. Sign in with `parent@demo.example` and the demo password. For the code, run `npm run demo:code`.
  8. **Optional:** to try the first-time authenticator setup, run `npm run setup-account`, choose **parent**, then sign in with that email and scan the QR code with your phone.

### Stage 3 — Time machine and nightly reconciliation (2026-10-02)

- **Decisions Dad made:**
  1. **At the plan:**
     - Dividends are paid on the first trading day of each fund's own market. In Jan 2028 that's Jan 3 for the Dow and Nasdaq-100, and Jan 4 for the TSX.
     - `pg` (the standard Postgres client) is added as a dev dependency.
     - "Updating…" clears by itself once a later check finds the account clean. The alert stays open until Dad acknowledges it.
     - The time machine resets the local database.
  2. **After the first run:** a sale by dollar amount **rounds its units down** at 8 decimal places. She gets exactly what she asked for and keeps the sliver of a unit.
     - The spec didn't say how to round them. The independent model guessed "up" and disagreed with the database by 1 cent on 4 sales. That's exactly the kind of thing it's there to find.
     - The database already rounded down, so no migration was needed. The model now follows Dad's rule.
  3. **New rule in CLAUDE.md:** any change that touches money logic must also pass `npm run timemachine` before the stage is called done.
- **Built:**
  - **`supabase/migrations/20261003000000_reconcile.sql`:**
    - **`reconcile(date)`** (server only) re-checks every account from the raw ledger as of the end of that date. It records its run in `job_runs` (`reconcile`). Its checks:
      - Nothing is negative: savings, each GIC, each fund's units.
      - **Every ledger line is explained by its rule, with the right amount.** Each is worked out again here:
        - Deposits and withdrawals match approved requests.
        - Monthly interest = that month's accruals, rounded up.
        - GIC interest = principal × rate × term ÷ 12, rounded up, on the maturity date. A broken GIC posts none.
        - Dividends = units × close × yield ÷ 4, rounded up, on the right day.
        - Trades settle at their own close: buys get units rounded up at 8 places, and sales get proceeds rounded up.
        - Splits scale units by the split ratio.
        - GIC buys, breaks, moves to savings and renewals are balanced pairs carrying the right amount.
        - Penalties are flagged, because the engine never charges one.
      - **Total worth = deposits − withdrawals + interest + dividends + corrections − penalties + realised gains + unrealised gains.** Realised gains are worked out from each sale.
      - What the app shows matches a fresh count: `daily_balances` for that day, and for today also `account_balances`, `fund_positions` and `gic_positions`.
      - Held money ≤ savings; held units ≤ units; each pending request holds the right amount.
      - Every GIC has a purchase line for its principal, and today its balance matches its status. None is past maturity without maturing.
      - Every day's accrual exists and equals (end-of-day savings + waiting GIC money) × rate ÷ 365/366. Every finished month's interest was paid.
      - No posting key is used twice.
      - **Corrections:** a line reversed by a correction counts as never having happened in the accrual check. Otherwise a fix dated today would leave every day since the mistake flagged forever.
    - **Alerts:**
      - One alert (kind `mismatch`) per account per kind of problem, never repeated while it's open.
      - Test accounts' alerts are quiet (`is_quiet`).
      - Each message says what's wrong in plain words, with up to 3 examples in `details`.
    - **`figures_updating(account)`:** true while the latest check found a problem with that account, so the app shows "Updating…". A kid may ask only about herself, and an empty account id is refused.
    - **`acknowledge_alert(id)`:** parent with MFA only.
    - **`health_check()`** (server only) reports:
      - open alerts that aren't quiet;
      - any daily job not finished through yesterday (interest through the day before);
      - no reconcile for yesterday.
    - **Grants:** `reconcile` and `health_check` to the server; `figures_updating` to signed-in users; `acknowledge_alert` to signed-in users (the MFA check is inside). The helper functions get no grant.
  - **`scripts/timemachine/`** (`npm run timemachine`):
    - `db.ts`: the local connection. It **refuses** any address but `127.0.0.1:54322`, any hosted Supabase address, and any database whose `is_local_dev` isn't `true`. Each app call runs as the real role (kid, parent with MFA, or server) with the same sign-in claims Supabase Auth would give, so permissions are exercised too.
    - `prices.ts`: repeatable synthetic closes, whole-number arithmetic, on each market's real trading days. It includes:
      - the Nasdaq-100 falling about 25% from Feb 14 to Mar 6, 2028 (−4% on Feb 24), then recovering;
      - smaller drops for the Dow and TSX;
      - a 2-for-1 Nasdaq-100 split on Nov 15, 2027;
      - the Sep 14, 2027 Nasdaq-100 close arriving a day late.
    - `scenario.ts`: the scripted year, Jul 1, 2027 to Jul 1, 2028. Every step says why it's there; the full list is at the bottom of `docs/TIMEMACHINE-REPORT.md`.
    - `model/`: **the independent reference model**, in exact whole-number fractions (no floating point, no library).
      - It was written from SPEC.md and these decisions **before** I read the Stage 2 job code. It shares input data (closes, holidays, the script) but no logic.
      - It works out settlement times (holidays, early closes, real elapsed time across the clock changes), maturity dates, accruals, dividends and rounding itself.
      - It has its own Vitest known-answer tests from the spec.
    - `run.ts` walks the year:
      - Each day: the scripted actions, then at 3:30 pm the closes, `run_daily` and `reconcile`.
      - It compares everything with the model, injects the faults, writes the report, and resets the local database at the end. Add `-- --keep` to keep the simulated year in the database for inspection.
  - **`docs/TIMEMACHINE-REPORT.md`:** the plain-English summary of the latest run, regenerated each time.
  - **CI (Dad's request at commit time):** `.github/workflows/ci.yml` has a second job, `timemachine`.
    - It runs after the `test` job passes (lint, unit tests, build, pgTAP), on every push and pull request.
    - It starts a throwaway local Supabase in the runner and runs `npm run timemachine`.
    - It uploads `TIMEMACHINE-REPORT.md` as a run artifact, even when the run fails.
    - A money bug therefore fails CI, and deploy (which needs a green CI) won't go.
  - **Smaller changes:**
    - `tsconfig.scripts.json` type-checks the scripts (part of `npm run build`).
    - Vitest now also runs `scripts/**/*.test.ts`.
- **Tests (all run locally on 2026-10-02):**
  - `npm run test:db` (pgTAP): **502 of 502 passed**, in 13 files, after `supabase db reset`. That's the 450 earlier tests plus 52 new ones in `reconcile_test.sql`:
    - a clean month passes;
    - each kind of fault is caught;
    - test accounts are logged quietly and don't fail the health check;
    - "Updating…" turns on, then clears after a correction while the alert stays open;
    - acknowledging needs a parent with MFA;
    - no duplicate alerts;
    - the health check spots jobs falling behind;
    - who may call what.
  - `npm run timemachine`: **PASS, 14 of 14 checks**, in 92 seconds:
    - **Shown figures (nearest cent) every day:** 359 days × 2 kids. Savings, held, available, each GIC, each fund's units (to 8 places) and value, total worth, net deposits and cap room all match the model.
    - **Posted amounts (rounded up):** all 91 ledger events match the model exactly. That includes 24 savings interest, 7 GIC interest, 16 dividend, 13 buy, 5 sell, 3 renewal, 4 GIC-to-savings, 1 break and 2 split postings.
    - **Accruals and graphs:** 732 kid-days of accruals, each within one ten-billionth of a cent, with every 2028 day ÷366. 732 kid-days of graph history match.
    - **Actions:** all 71 were accepted or refused the same way by both, and all 9 planned outcomes happened:
      - refusals: a second same-day trade, a withdrawal under 24 hours old, a late approval, a GIC under $10, a deposit over the lowered cap;
      - two expiries, one of them across the November clock change;
      - the health check failing during the missed week and clear after the catch-up.
    - **Nightly checks:** 367 reconcile runs with no problems and no alerts. Only the late-close day had to wait.
    - **Deliberate faults**, each in a transaction that's undone (a throwaway copy):
      - an extra interest posting;
      - a trade with the wrong units;
      - a GIC with no purchase line.

      Each was caught, with "Updating…" on, and kid B's alert was quiet. The corrected fault cleared "Updating…" while its alert stayed open for Dad, and nothing was left behind afterwards.
    - **Final balances:**
      - Kid A: $1,296.41 from $1,270.00 put in. Savings interest $9.14, GIC interest $5.42, dividends $1.97, fund gains $9.88.
      - Kid B: $1,201.90 from $1,180.00 put in. Savings interest $8.59, GIC interest $0.13, dividends $5.70, fund gains $7.48.
  - **Safety guard:** `TIMEMACHINE_DB_URL` pointing at a hosted Supabase address, or at the wrong local port, is refused before connecting.
  - `npm test` (Vitest): **18 of 18 passed**: the placeholder test plus 17 reference-model tests. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds (type-checking the scripts too).
- **ACCEPTANCE.md boxes now testable:**
  - **Passing now:**
    - "The time machine runs a simulated year (rate changes, maturities, dividends, a crash, a missed week) with every balance correct".
    - "A quarterly dividend posts correctly", in the time machine.
  - **Ready for stage 4:** "30 nights in a row with zero reconciliation mismatches" (needs the nightly job in production).
- **Known issues and notes for later stages:**
  - **Stage 4:**
    - **Nightly order:** fetch prices → `run_daily(today)` → `reconcile(d)` for every date since the last reconcile, as the time machine does after the missed week.
    - The GitHub check calls `health_check()` with the service role key and fails when `ok` is false.
    - `run_daily` returning `waiting` or `failed` still needs its own alert (as noted in stage 2). Today it shows up only through `health_check`'s "behind" report the next morning.
  - **Stage 7:** the kid screens call `figures_updating(her account)` and show "Updating…" in place of her figures while it's true.
  - **Stage 8:**
    - The dashboard lists open `alerts`. Quiet ones go in a separate "test accounts" list. Each gets an Acknowledge button that calls `acknowledge_alert`.
    - **Corrections:** reconcile treats a correction with `reverses_id` as fully cancelling the line it reverses. If the engine ever posted a wrong line that interest was later accrued on, those accrual rows stay flagged even after the line is corrected, because accruals are append-only. Dad acknowledges the alert, but "Updating…" would stay on. If that ever happens, it needs a small follow-up: a way to mark a past accrual as corrected.
  - **Holds are checked only as they stand today:** requests change status, so a past day's holds can't be rebuilt.
  - **Fund cost (average cost) isn't compared with the model.** It isn't money owed: it only feeds "gain since first purchase". The model checks every amount that is money owed or shown as a balance.
  - **The time machine resets the local database at the start and the end**, so any local test data is wiped. Use `npm run timemachine -- --keep` to keep the simulated year for inspection, then `npm run db:reset` before running the database tests: the earlier tests expect an empty database.
  - **No new kid-facing wording:** "Updating…" itself is screen text for stage 7, and the alert messages are parent-only. So `docs/MESSAGES.md` is unchanged.
- **Dad to do by hand:** nothing for this stage. Optional: run `npm run timemachine` yourself (Docker Desktop must be running) and read `docs/TIMEMACHINE-REPORT.md`.

### Stage 2 — The money engine (2026-10-02)

- **Decisions Dad made at the plan:**
  1. A matured GIC waiting for her choice **earns the savings rate** until she chooses or the day-7 auto-move.
  2. A sell by dollar amount that needs more units than she has (the price fell) **sells all her units**, with a note.
  3. A withdrawal under $5 is allowed **only when it empties savings**.
  4. Requests expire **exactly 7 × 24 hours** after they're made.
  5. Dividend yields are **dated settings** (`dividend_yield:dow` …), so yield changes keep their history. The `funds.dividend_yield` column is gone.
  6. `.env.example` stays committable.
- **Built:** seven migrations, all applying cleanly to an empty database.
  - **`…070000_engine_schema.sql`:**
    - `transactions.effective_at`: when the money counts. `posted_at` stays the real time the row was written. They differ only for automatic postings: a trade written at 3:30 pm counts from the 2:00 pm close, and a catch-up run on Nov 10 for Nov 5 counts from Nov 5. So a late run gives exactly the on-time answer.
    - `interest_accruals.gic_waiting_cents`, for decision 1.
    - The `fund_splits` table.
    - `notes.auto_key` and `notifications.dedupe_key`, so automatic notes and notices are never written twice.
    - New job names and the `question` notice type.
    - Yields moved to settings.
    - The two standard market-move notes (rise and drop) as editable settings.
  - **`…080000_engine_core.sql`:**
    - Rounding (units to 8 places), GIC interest, and "interest earned so far" for the break warning.
    - Formatting ($1,234.56, 2.0%, "Nov 1").
    - `rate_on` (a special wins inside its dates) and `setting_on`.
    - Market days and closes from `market_holidays`, in Eastern time, so early closes are 11:00 am Edmonton.
    - Balance helpers and the notice writer.
  - **`…090000_kid_actions.sql`:** `request_deposit`, `request_withdrawal`, `buy_gic`, `break_gic`, `choose_maturity`, `request_trade` and `ask_question`. Each locks her account, checks the rules (minimums, available balance, the cap including pending deposits, one trade per fund per Edmonton day, every move through savings) and writes, in one transaction.
  - **`…100000_parent_actions.sql`:** `approve_request`, `decline_request`, `answer_question`, `add_rate` and `set_setting`, all aal2 only.
    - **`approve_request`:** withdrawals only after 24 hours, and nothing after the 7 days.
    - **`decline_request`:** a reason is required.
    - **`add_rate`:** the effective date defaults to 7 days out and can't be in the past. Specials have an end date. More than 3 decimal places is refused rather than silently rounded.
    - **`set_setting`:** an allowed-keys list. It always refuses `is_local_dev` and `clock_override`, and `launched_at` can be set only once.
  - **`…110000_daily_jobs.sql`:**
    - **The jobs, each idempotent:** `expire_requests`, `apply_split`, `settle_trades`, `mature_gics`, `auto_move_unclaimed_maturities`, `pay_quarterly_dividends`, `post_monthly_interest`, `write_market_move_notes`, `send_rate_notices` and `accrue_savings_interest`.
    - **`run_daily(date)`:** runs them in that order for every date not yet done, recording each in `job_runs`.
    - **A job that's waiting or fails stops the run at that date,** so nothing is processed out of order. The next run starts there. The market-move notes are the exception: they never hold anything up.
    - **A day's savings interest is accrued once that day is over,** in the next day's run. A 3:30 pm run can't know about an 8 pm GIC purchase.
  - **`…120000_reads.sql`:**
    - Views, run with the caller's permissions: `account_balances`, `fund_positions` and `gic_positions`.
    - Functions: `daily_balances(account, from, to)`, `fund_return(account, fund, from)` (Modified Dietz), `liability_total()` (parent or server only, test accounts excluded) and `next_settlement(fund)` for the Buy / Sell screen.
  - **`…130000_function_grants.sql`:** every function's permissions in one list. Postgres lets everyone run a new function by default, and Stage 1's per-schema default couldn't stop that, so this migration revokes everything and grants exactly:
    - kid actions and reads to signed-in users;
    - parent actions to signed-in users, with the aal2 check inside;
    - jobs to the service role only.
  - **`.gitignore`:** now also ignores `*.env`, `**/.env*`, and every `.txt` file outside `docs/`. `.env.example` stays allowed. Checked with sample files.
- **Tests (all run locally on 2026-10-02, after `supabase db reset` from empty):**
  - `npm run test:db` (pgTAP): **450 of 450 passed**, in 12 files. That's the 170 earlier tests plus 280 new ones:
    - `engine_interest_gic_test.sql` (51):
      - $250 at 2% for 30 days posts $0.42, with its working.
      - Old rate before a change, new rate from its effective date.
      - A day in 2028 accrues ÷366.
      - $100 at 5% for 1 year = $105.00, and $100 at 2.5% for 1 month = $0.21.
      - Locked rate after a cut.
      - Renewal carries principal + interest.
      - **Waiting GIC money earns the savings rate,** both when she renews and through the day-7 auto-move, with no gap and nothing counted twice.
      - A broken GIC pays $0 and returns the principal, and the warning shows $0.20.
      - Jan 31 + 1 month = Feb 28, 2027 and Feb 29, 2028.
    - `engine_trades_test.sql` (76):
      - Friday evening settles Monday. Good Friday. Exactly at the close waits.
      - **Early closes:**
        - NYSE, Nov 27, 2026: a 10:30 am request settles at the 11:00 am close; one at 11:30 am settles Mon Nov 30.
        - TSX, Christmas Eve: a 10:00 am request settles at 11:00 am; one at noon skips Dec 25 and 28 to Dec 29.
      - $100 at 420 = 0.23809524 units. Sale proceeds and dividends round up.
      - **Values shown round to the nearest cent:** the $100 buy shows $100.00 on her holding, total worth and graphs right after settling, and at a close of 430 it shows $102.38 while selling would pay $102.39.
      - One trade per fund per day. Held money isn't available.
      - A missing close waits and never uses another day's price.
      - A split keeps the value. Partial sells and average cost. The price-fall sell-all (decision 2).
      - Market-move notes over 2%.
    - `engine_requests_test.sql` (48):
      - The cap counts pending deposits.
      - Declines keep the reason.
      - Withdrawals can't be approved before 24 hours.
      - The $5 rule (decision 3).
      - Expiry to the minute, releasing the hold, with one notice each.
      - Dad can't approve after 7 days.
      - Questions and answers.
      - Lowering the cap takes nothing away.
    - `engine_rates_settings_test.sql` (41): rate and special notices on save, on the day and at the end; specials apply only between their dates; settings validation, including refusing `is_local_dev` and `clock_override`; cap-change notices.
    - `engine_jobs_test.sql` (26): the first run, a missed week caught up in one run, running again posts nothing, every job re-run for every date posts nothing, and a missing close holds the run without skipping ahead.
    - `engine_security_reads_test.sql` (38): kids can't call parent functions or jobs; a parent without MFA is refused; kid A can't touch kid B's GIC, ledger lines or balances; the views and functions return the right figures; the liability total leaves out test accounts; and the safety net covers every new view and function.
  - **Updated Stage 1 tests,** because the schema changed on purpose:
    - `schema_test`: `fund_splits` and the `question` notice type.
    - `reference_data_test`: yields are now settings, so there's 1 more test.
    - `rls_test`: the "account-scoped tables" check now looks at tables only, not views.
  - **Mutation check:** I broke three money rules in the live local database. The tests caught all three (16 failures), and then I rebuilt the database from empty:
    - GIC interest rounded to nearest instead of up;
    - early closes ignored;
    - waiting GIC money dropped from interest.
  - `npm test` (Vitest): 1 of 1 passed. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:**
  - **Passing now:** "All known-answer tests pass (interest, GIC maturity, broken GIC, trade units, rounding up)".
  - **Proven at the database level; the live check comes once the screens (stages 6–8) and the nightly jobs (stage 4) exist:**
    - A deposit request holds the money and Dad approves it.
    - A declined request shows the reason.
    - Expiry after 7 days releases the hold.
    - The cap blocks deposits with a clear message.
    - The 24-hour withdrawal wait.
    - Cashing out goes through savings.
    - Savings interest posts on the 1st, with its working.
    - A 1-month GIC matures right, and the money moves to savings after 7 days.
    - Breaking a GIC early.
    - Next-close settlement (Friday → Monday).
    - One trade per fund per day.
    - Partial sells.
    - The note for a move over 2%.
    - Quarterly dividends.
    - A rate change notice with the 7-day default.
    - Locked GIC rates.
    - A special switching back.
    - The cap-change notice.
    - A skipped night caught up with no duplicates.
    - A missing price makes trades wait.
    - A question and Dad's reply.
- **Known issues and notes for later stages:**
  - **How the ledger keeps fund cost:** a fund row's `amount_cents` is cost, not value. A buy adds what she paid, and a sale removes the average cost of the units sold. So the fund rows add up to the cost of the units she holds, and a sale's savings row (the proceeds) minus its fund row (the cost) is the realised gain.
    - **Stage 3 reconciliation invariant:** total worth = the sum of every ledger row + (fund value − fund cost).
    - Renewals move money GIC → GIC with no savings rows. That's two balanced rows linked by `renewed_from_id`.
  - **Two kinds of rounding (Dad's change after the first review):**
    - Money actually posted rounds up to the cent: sale proceeds, interest and dividends.
    - Values only shown round to the nearest cent: fund holding values, total worth, the graphs and the liability total (`fund_positions`, `account_balances`, `daily_balances`, `fund_value_at`). So a $100 buy shows $100.00 right after settling, not $100.01.
    - **Stage 3:** reconcile must use the same nearest-cent fund value as the screens, so a selling price that's a fraction of a cent higher isn't reported as a mismatch.
  - **Stage 3:** the time machine should call `run_daily`, which the clock override already drives.
    - A missing TSX close leaves that day's market-move notes "retrying", so each run starts from that date again. That's harmless, but the reconcile report shouldn't flag it.
  - **Stage 4:**
    - `fund_splits` and `fund_prices` have no write function yet. The price job needs one, run by the service role and added to the grants list.
    - Alert when `run_daily` returns `waiting` or `failed`. Its result lists the date, job and reason.
    - The first `run_daily` starts from the earliest account's opening date.
  - **Every later stage:** add each new function to a grants list like `…130000_function_grants.sql`. The safety-net tests fail otherwise.
  - **Stage 7:** marking notices as read needs a small kid function, which isn't built yet. `next_settlement(fund)` gives the "settles at Monday's 2 pm close" time.
  - **Stage 8:** "recent auto-approved moves" are the requests of type `move`.
  - **All kid-facing wording is a draft for you to review:** **`docs/MESSAGES.md`** lists every message the girls can see from the money engine, grouped by where it appears:
    - notices;
    - errors on Buy / Sell and requests;
    - "How was this calculated?" lines;
    - notes on history lines;
    - market-move notes.

    Changing parts are shown as `{placeholders}`. Like `docs/GLOSSARY.md`, it's a review copy, regenerated from the migrations after each change. Later stages add their messages to it.
- **Dad to do by hand:**
  1. Review the wording in **`docs/MESSAGES.md`**. **Your wording edits will come back as a new migration** that replaces the affected functions. The Stage 2 migrations stay as they are once committed, because other copies of the database will have run them. After that migration, `docs/MESSAGES.md` is regenerated so the two always match.

### Stage 1 — Database and security (2026-10-02)

- **Built:** six migrations in `supabase/migrations/`, all applying cleanly to an empty database.
  - **`20261002010000_core_tables.sql`:**
    - **Tables:** every table in the Data model plus the Build decisions additions (22 tables with `settings`), with enums, foreign keys, NOT NULL and check constraints. Money is `bigint` cents, units `numeric(20,8)`, accruals `numeric`. Rates and yields are percent per year (`5.000` = 5%).
    - **Signed ledger:** + adds to a vehicle, − takes away. Checks pin the sign per type: a deposit > 0, a withdrawal < 0, a `split_adjust` moves $0, a correction needs a note, and only a correction may set `reverses_id`.
    - **GIC maturity date:** a check enforces the rule (start + term months, moved back to the month's end).
    - **Requests:** checks enforce "every move goes through savings".
    - **Clock:** timestamps default to `app_now()` and dates to `app_today()`, so the time machine moves them.
  - **`…_append_only.sql`:** `transactions`, `rates` and `interest_accruals` reject UPDATE, DELETE and TRUNCATE for every role, the owner included. `interest_accruals` wasn't in the spec's list; it's protected because it's the working behind every interest line.
  - **`…_helpers.sql`:**
    - **`my_account_id()`:** the signed-in kid's account.
    - **`is_parent()`:** true only for a parent signed in **with MFA (aal2)**. A parent with a password alone sees only their own profile.
    - **`feature_enabled(feature, account_id)`:** `off` / `test` / `everyone`, using the newest `feature:<name>` row effective today. A missing or unknown value counts as off, and a kid may ask only about her own account.
  - **`…_rls.sql`:** RLS on every table, with read policies only. Write grants are revoked from `anon`, `authenticated` and `service_role`, and default privileges are changed so **future tables and functions start with no grants** (each later stage must grant on purpose).
    - Kids read only their own rows. They read the shared reference tables, notes with audience `kids`, and every setting except `is_local_dev` and `clock_override`.
    - Parent-only: `wishlist_parent_marks`, `alerts`, `login_attempts` and `job_runs`.
  - **`…_reference_data.sql`:** in a migration, not `seed.sql`, so production gets it too.
    - **Funds:** dow/DIA 1.8%, nasdaq100/QQQ 0.6% and tsx/XIC 2.8%, with colours #2F80ED blue, #F76B15 orange and #0B6E69 teal (TSX was red at first; changed because red reads as "losing money"). The teal differs from the other two in both hue and lightness.
    - **Rates:** the starting rates, effective 2026-01-01.
    - **Settings:** cap 100000 cents and inflation 2.0.
    - **Glossary:** 52 kid-friendly terms. **This wording is a draft for you to review.**
  - **`…_market_holidays.sql`:**
    - **NYSE 2026–2028:** from the official page, all confirmed. Nasdaq follows the same calendar.
    - **TSX 2026:** confirmed.
    - **TSX 2027 and 2028:** the TSX publishes only 2025–2026, so **both** years are calculated from the usual rules and marked `confirmed = false`. You asked for this treatment for 2028; 2027 turned out to be in the same position.
    - **Early closes:** included too (`kind = early_close`, `closes_at` 1:00 pm Eastern), because a trade can't settle at 2:00 pm Edmonton on those days.
    - Source URLs are in the migration's header comment.
  - **Spec details settled in the plan:**
    - `wishlist_items.parent_got_it` is replaced by `wishlist_parent_marks`.
    - Kids don't insert `requests` directly; Build decisions overrides the Data model here.
    - Added the `expired` request status, `requests.held_units` / `sell_all` / `gic_id`, `funds.market`, and `gic_holdings.renewed_from_id` / `rate_id`.
- **Tests (all run locally on 2026-10-02, after `supabase db reset` from empty):**
  - `npm run test:db` (pgTAP): **169 of 169 passed**, in 6 files:
    - `clock_test.sql`: 26 tests.
    - `schema_test.sql`: 44 tests. Tables, money types, no floats, ledger signs, posting-key duplicates refused, GIC maturity dates including Jan 31 → Feb 28 / Feb 29, and request shapes.
    - `append_only_test.sql`: 17 tests.
    - `helpers_test.sql`: 20 tests.
    - `rls_test.sql`: 45 tests.
      - Kid A sees none of kid B's rows in any table, and kid B, a test account, sees none of kid A's.
      - Kids, the parent, anonymous callers and the service role are each refused INSERT, UPDATE, DELETE and TRUNCATE on every table.
      - Kids can't see the parent-only tables.
      - The parent with MFA reads every row of every table.
      - **Safety-net checks on every table and function:** RLS is on, there are no write grants (including column grants), anonymous callers can't read or execute anything, every SECURITY DEFINER function has a fixed `search_path`, and every view runs with the caller's permissions.
    - `reference_data_test.sql`: 17 tests.
  - **Mutation check:** I injected a leaky policy, a stray write grant and a table with RLS off into a throwaway copy of the security test. It caught all three (7 failures).
  - `npm test` (Vitest): 1 of 1 passed. `npm run test:e2e` (Playwright): 2 of 2 passed. `npm run lint` is clean, and `npm run build` succeeds.
- **ACCEPTANCE.md boxes now testable:**
  - **"Security tests pass: one girl can't see or change the other's data, and no one can edit history":** testable at the database level, and passing. It's fully proven once stage 6 adds real logins.
  - **"Cashing out of a GIC or fund requires moving it to savings first":** partly. The schema refuses withdrawals from anything but savings, and refuses moves that skip savings. The screens come in stage 7.
- **Known issues and notes for later stages:**
  - **Stage 2:**
    - Every new function needs explicit `grant execute` (kids: kid functions only). Every new view needs `security_invoker = true`. The safety-net tests fail otherwise.
    - The parent's settings function must still refuse `is_local_dev` and `clock_override` (from stage 0).
    - `funds.dividend_yield` is an ordinary column, not dated history. If you want yield changes to keep their history like rates do, decide that in stage 2.
  - **Stage 4: the holiday warning must treat unconfirmed years as missing.** The parent-dashboard warning ("60 days before the table runs out") must count a market's year as covered only when its rows have `confirmed = true`. TSX 2027 and 2028 are unconfirmed now, so the warning should remind you to check them against https://www.tsx.com/en/trading/calendars-and-trading-hours/calendar once the TSX publishes them. Confirming a year means adding the published dates and marking them confirmed, in a new migration. Add a pgTAP test that an unconfirmed year triggers the warning.
  - **Stage 5:** the append-only triggers stop TRUNCATE for every role, so `prelaunch_reset()` will have to disable them briefly as the database owner, inside its own transaction.
  - **Stage 6:** public sign-up is still on in `supabase/config.toml` (`enable_signup = true`). Turn it off when logins are built.
- **Dad to do by hand:**
  1. Review the glossary wording in **`docs/GLOSSARY.md`**, a readable export of all 52 terms from the database. **Your wording edits will come back as a new migration** that updates the glossary. The Stage 1 migration stays as it is, because it's committed and other copies of the database have already run it. After that migration, `docs/GLOSSARY.md` is regenerated from the database so the two always match.
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
  - **CI on GitHub:** run #1 passed on 2026-10-02 for commit `fde86ea`, every step green: https://github.com/JarrettWD/Big-Bucks/actions/runs/37092337236
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
