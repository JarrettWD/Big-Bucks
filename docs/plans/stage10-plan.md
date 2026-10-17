# Stage 10 plan — Personalisation and badges

Status: **built and tested locally (2026-10-16); not in production yet.** Approved by Dad 2026-10-16 with the recommended answers: A1 (30 days without selling), B (yes, $10.00), C (interest only), D (yes), E (top hat and bow, for now), F (Dashboard alert only), G (retroactive), H (the 8 colours as listed).

**One change from Dad (replaces the savepoint design in section 1):** no event checks inside any money function. The GIC buy and renewal, deposit approval and every other money function stay byte-for-byte unchanged. Instead, after a money call succeeds, the app makes a **separate call**: `kid_check_my_badges()` after her own GIC purchase or renewal, and `parent_check_badges(account)` after Dad approves a deposit or changes a feature switch. Each can award badges only for that one account, is idempotent, and does nothing in a preview or with the switch off. If it fails, the money is untouched and the nightly check catches the badge. The migration diff must show no change to any money function (proof in PROGRESS).

Other conditions: tests first; the time machine run locally and shown to Dad; MESSAGES wording reviewed by Dad before any switch goes on; the 16-animal × accessory screenshot sheet; production steps in the plan's order with dry runs, never 7:00–11:45 am or from 4:00 pm until the nightly run is done.

Everything is behind two switches: `feature:personalisation` (theme colour, animal, accessories) and `feature:badges` (badges and their notices). "Done" means `supabase test db`, `npm test`, Playwright and `npm run timemachine` all pass, and both switches are on for test accounts only.

## 0. What's already there (found while planning)

- `accounts` already has `theme_colour`, `avatar_animal` and `avatar_accessory` (empty today). Kids can read only their own `accounts` row (RLS), so her sister can't see her look.
- `badges` already exists (account, badge, unlocked accessory, earned time) with `unique (account_id, badge)`, RLS "her own rows or the parent", and the pre-launch reset already clears it. The backup, Download zip and restore drill already include it, because they find every table by themselves.
- `notifications.type` already has `badge`. The What's new wording for both features is already in the database (MESSAGES §11).
- Onboarding already lists a `personalise` step when `feature:personalisation` is on, but the screen for it was never built (`Welcome.tsx` says "joins at stage 10"). This stage builds it. Until then, switching that feature on would leave a new kid stuck, so it must stay off until this stage ships.
- `goals.reached_at` exists but nothing sets it. This stage sets it.
- **Fluent Emoji has a moose** (`assets/Moose` in microsoft/fluentui-emoji, MIT). So no hand-drawn moose is needed; it matches the other animals exactly.

## 1. Nightly safety (the part that touches the money path)

Badges never write to the ledger, rates, settings, GICs, requests or accruals. They only *read* them. Even so, they run inside the nightly path, so:

- **Badge checks run after the money jobs and reconcile.** The nightly Edge Function's order becomes: closes → splits → `run_daily` → `reconcile_through` → `nightly_status` → **`check_badges_through(target)`**. It's a separate RPC call, so a separate transaction: the money jobs and reconcile have already committed before it starts.
- **A badge failure can't block, delay or roll back money.**
  - It is *not* added to `run_daily`'s job list, so it can't hold up later days or the interest chain.
  - `nightly_status` (which decides whether tonight's work is done) and `jobs_behind` (the health check) don't look at it. I'll confirm both in the code and with a test.
  - The Edge Function wraps the call in its own try/catch: if it throws, the nightly response is still OK and includes `badges: failed`.
  - It records its own `job_runs` row (`job = 'badges'`, a new enum value in its own migration file).
  - It skips any account whose figures are "Updating…" (an open reconcile mismatch), and checks it again once it's clean.
  - **The event checks** are separate calls the app makes after a money call has succeeded (Dad's change, above). The money functions don't call them and aren't changed.
- **Each badge at most once:** the existing `unique (account_id, badge)`, plus `badges.award_key` (for example `badge:first_gic:<account>`) with its own unique constraint, the same idea as `posting_key`. Awarding uses `insert … on conflict do nothing`, so a retry, a catch-up night or an event check and the nightly check racing each other give one badge and one notice.
- **Badges are append-only:** a guard trigger refuses UPDATE and DELETE for every role, like the ledger. Only the pre-launch reset clears them (it already lifts guards inside its own transaction). Badges are never taken away, even if a GIC is later broken or a fund sold.
- **Previews:** every badge check does nothing while `in_preview()` is true. So a Buy / Sell preview or Dad's decision preview never shows a badge notice, and nothing here reaches outside the database anyway.
- **If the badge check fails:** one `badge_check_failed` alert on Dad's Dashboard (quiet for test accounts). **Decision F** below: should it also turn the health check red?
- **Time machine:** I'll add the badge step to its nightly (after reconcile) and add known answers for when each badge appears in the simulated year (the crash gives "Cool in a drop", the maturities give "Kept it to the end", and so on). Money is compared to the cent as always and must not change. I'll run it locally in the background and show you the result before committing.

## 2. Exact badge definitions

All amounts in integer cents; all days are Alberta days from `app_today()`. Only **final** daily closes count (never weekly backfill).

| Badge | Earned when | Not earned when | Checked |
|---|---|---|---|
| **First GIC** 🎉 | Her first GIC purchase posts (a new GIC from savings, or renewing a matured one, which is her choice). | Money reaching a GIC any other way (there is none today). | At purchase, and nightly |
| **Kept it to the end** 🎓 | A GIC of hers matures (status `matured`) on its maturity date. Any term counts, 1 month included. | It was broken early. | Nightly, after `mature_gics` |
| **Cool in a drop** 😎 | See A below. | See A below. | Nightly |
| **GIC ladder** 🪜 | She holds at least 3 active GICs at the same moment, with at least 3 **different** maturity dates, each at least $10.00 (decision B). | 3 GICs maturing the same day; a GIC broken before the third was bought; rungs under $10. | At purchase, and nightly |
| **First dollar of interest** 💰 | Her total interest paid reaches $1.00: savings interest, GIC interest and late-interest lines added together (cumulative, decision C). | Dividends, corrections and fund gains don't count. | Nightly |
| **Goal reached** 👑 | See D below. | See D below. | When Dad approves a deposit, and nightly |

### A. "Held through a 10% drop" (my recommendation, A1)

- **Measured on the fund's price, not her purchase price.** Her purchase price changes with every buy (average cost) and is hard to explain; "the fund fell 10% from its high" is what the news says and what her graph shows.
- **The high** = the highest final close of that fund on any day she held units, since she last went from 0 units to some.
- **The drop** starts on the first final close at least 10% below that high, while she holds at least $10.00 of the fund at that close (decision B).
- **She held through it** if, for the 30 days from the day the drop started, she sold none of that fund: no partial sell, no sell all, and no sell request waiting. Buying more is fine (that's not panicking). The badge comes on day 30, with the date the drop started.
- **A partial sell breaks it** for that drop. The next 10% drop (from a new high) is a new chance.
- **Why 30 days:** a kid-sized wait, it matches her 1M view, and the scary days of a drop usually happen inside it. Waiting for a full recovery (A2) could take years, which is too late to feel like a reward.
- **A2, the alternative:** award when the close gets back to the old high without her selling. Truer to "held through", but it may never come in the beta, or for a long time.

### B. Minimum amounts (my recommendation: yes, $10.00)

Without a floor, three $1 GICs make a ladder and $1 of a fund earns "Cool in a drop". A $10.00 floor per GIC rung and for the fund holding keeps the badges about real decisions. No floor for First GIC or Kept it to the end (any GIC is a real choice).

### C. First dollar of interest

Cumulative, interest lines only (savings interest posted on the 1st, GIC interest at maturity, and late-interest lines). Dividends are left out because they're a different lesson (owning a company's profits); corrections are left out because they're Dad's fixes, not earnings.

### D. Goal reached

- She has an active goal, and her total worth reaches its price.
- **She can't win it by moving the target:** the price that counts is the higher of the price when she made it her goal and the price now. Lowering the price doesn't help; raising it makes it harder.
- **It must be reached after she set it:** if her worth was already above the price on the day she made it her goal, it doesn't count.
- A rise in her funds counts too (that's her investment growing).
- Sets `goals.reached_at`. The goal stays her goal (she still decides "I got this").
- One crown in total (each badge at most once), not one per goal.

## 3. History: retroactive or from now on?

**My recommendation: retroactive, from her whole history.** Each rule is written as "has she done this, as of this date?", reading the ledger and closes, so the first check after a switch goes on finds what she already did. Each badge records `earned_on` (the day she made the decision) and `awarded_at` (when the app gave it). A badge from before the switch says "You earned this on Oct 15. Badges just arrived!"

- **Why:** the decisions were real and she made them. "From now on" would mean her first GIC never counts because it came too early.
- **When the switch goes on,** after Dad saves a switch, the Settings screen calls `parent_check_badges` for the accounts it affects, so he sees the result at once instead of the next evening.
- **test_kid now:** she gets **First GIC** (party hat) the moment `feature:badges` goes on, because she opened a 1-month GIC on Oct 15. Nothing else yet: her GIC matures Nov 15, her interest is below $1, she has no goal, and her funds haven't dropped 10%.
- **The girls at launch:** the pre-launch reset clears all history and badges, so they start from zero. Badges then reward only what they do in the real app.

## 4. Theme colours

Eight colours, each with white text on it at least 4.5 : 1 (WCAG AA for normal text; I keep 4.5 : 1 for large text too, so Android's large-text setting never makes it worse), and at least 3 : 1 against the page background (for her avatar circle and buttons). I left out blues and oranges close to the Dow and Nasdaq colours, so a themed header is never mistaken for a fund.

| Name | Colour | White text | On the page |
|---|---|---|---|
| Big Bucks purple (default) | #5B3FD1 | 6.83 | 6.33 |
| Grape | #8E24AA | 7.04 | 6.52 |
| Magenta | #B0127A | 6.53 | 6.06 |
| Blueberry | #3949AB | 7.73 | 7.17 |
| Navy | #0D47A1 | 8.63 | 8.00 |
| Teal | #00695C | 6.61 | 6.13 |
| Forest | #1B5E20 | 7.87 | 7.29 |
| Cocoa | #795548 | 6.55 | 6.07 |

- **Where her colour shows:** the header, the active tab, her main buttons, the avatar circle and links. Dad's screens stay purple, except "View as", which shows her colour.
- **Fixed, never themed:** savings, GIC and the three fund colours, gains and losses, warnings and error red, all graphs.
- **A Vitest test** computes every ratio from the list, so a colour that fails can never be added.

## 5. Avatars and accessories

**16 animals,** all from Fluent Emoji's "Color" SVGs (they scale crisply at any size and with large text): fox, panda, koala, bunny, cat, puppy, owl, penguin, unicorn, tiger, frog, hedgehog, bear, hamster, lion and **moose** (the lion replaced the otter at build time: Fluent's otter is lying down, so hats didn't sit on it).

**Six accessories,** one per badge:

| Badge | Accessory | Source |
|---|---|---|
| First GIC | Party hat | Drawn by me in the same Fluent "Color" style (there's no party hat emoji) |
| Kept it to the end | Graduation cap | Fluent `Graduation cap` |
| Cool in a drop | Sunglasses | Fluent `Sunglasses` |
| GIC ladder | Top hat | Fluent `Top hat` (decision E) |
| First dollar of interest | Bow | Fluent `Ribbon` (decision E) |
| Goal reached | Crown | Fluent `Crown` |

- **Files:** `public/avatars/animals/*.svg` and `public/avatars/accessories/*.svg`, only the files we use, minified once (svgo through `npx`, not added to the project). Microsoft's `LICENSE` and an `ATTRIBUTION.md` (source, licence, which files, the party hat being ours) sit in `public/avatars/`. The About screen gets one line of credit. About 600–800 KB in total, cached by the app for offline use.
- **Avatars and accessories are app files, not database rows.** The database stores only her choice as a short key (`fox`, `crown`), checked against the allowed list in the function that saves it.
- **Overlay:** each animal has a small table of where its head top is (x, y, size), so a hat or sunglasses sits right on every animal. One accessory at a time, or none.
- **Where her avatar shows:** Home (top, next to her total worth), her Badges screen, her questions to Dad (her side and Dad's Approvals and question cards), and Dad's Dashboard kid cards. With personalisation off, those places show what they show today.
- **Saving her look:** one kid function `kid_set_look(theme, animal, accessory)`: her own account only, `feature:personalisation` on, each value from the allowed list, and the accessory only if she has its badge. Kids still can't write to `accounts` directly.
- **The picker ("Make it yours")**, opened by tapping her avatar on Home, and as onboarding step 2: colours as big swatches, animals as a grid, accessories below. An accessory she hasn't earned shows softly with one line on how to earn it ("Keep a GIC until it finishes"), never a count or a nag. With `feature:badges` off, the accessories row is hidden.

## 6. Her Badges screen

- Opened from Home ("Your badges", next to her avatar).
- **Earned badges:** big and colourful, her avatar wearing that badge's accessory, the date, and one line about the decision.
- **Still to discover:** the other badges, softly, each with one line on the good decision behind it. No "3 of 6", no progress bars, nothing timed.
- **"GIC ladder ?"** gets a glossary explanation: "A ladder is a few GICs that finish on different days, so some of your money frees up every so often, while the rest keeps earning."

## 7. Notices (in-app only, type `badge`)

Each notice is the title plus one or two lines. The accessory line is added only when personalisation is on for her.

- **First GIC** · 🎉 Badge: First GIC! · You locked money in a GIC to grow. That's planning ahead! · *Your animal can wear a party hat now.*
- **Kept it to the end** · 🎓 Badge: Kept it to the end! · You waited until your GIC finished, so you got all its interest. Patience pays! · *Your animal can wear a graduation cap now.*
- **Cool in a drop** · 😎 Badge: Cool in a drop! · {Fund} fell more than 10%, and you stayed calm and kept it. That's hard, and you did it. · *Your animal can wear sunglasses now.*
- **GIC ladder** · 🪜 Badge: GIC ladder! · You have 3 GICs that finish on different days, so some money frees up sooner. Smart thinking! · *Your animal can wear a top hat now.*
- **First dollar of interest** · 💰 Badge: Your first dollar of interest! · Your money has earned $1.00 just by sitting and growing. · *Your animal can wear a bow now.*
- **Goal reached** · 👑 Badge: Goal reached! · You have enough for {goal name}. You kept your eye on the prize! · *Your animal can wear a crown now.*
- **Earned before badges arrived** (retroactive): the same title, then "You earned this on {date}. Badges just arrived!"

These go into MESSAGES.md for your review before anything is switched on.

## 8. Dad's side and "View as"

- **"View as"** shows her colour, her avatar and accessory, her Badges screen and her notices exactly as she sees them, read-only (new `parent_view` reads `kid_look` and `kid_badges`). No buttons in it change her look.
- **Dashboard:** each kid card shows her avatar and her badges (small icons with dates). Dad can't change her look or take a badge away.

## 9. Data, RLS and backups

- **New migrations** (two files, because a new enum value has to be committed before it's used):
  - `…_stage10_enums.sql`: `job_name` adds `badges`, `alert_kind` adds `badge_check_failed`.
  - `…_stage10_badges.sql`:
    - `badge_kinds` (key, accessory key, order): reference data, readable by everyone signed in, like `funds`;
    - `badges` adds `award_key` (unique), `earned_on`, `related_gic_id`, `related_goal_id`, `related_fund`, and a guard trigger (append-only);
    - `accounts.theme_colour` checked against the 8 colours; `avatar_animal` and `avatar_accessory` checked against the allowed keys;
    - the badge rules (one function each), `check_badges(account)`, `check_badges_through(date)`, `kid_set_look`, `kid_badges`, `kid_look`, the `parent_view` reads, the event hooks in the GIC purchase and renewal, deposit approval and the switch change;
    - `prelaunch_reset` also clears `avatar_accessory` (her badges are gone, so her crown must go too). Her colour and animal are kept; onboarding asks again anyway.
- **RLS:** `badges` and `accounts` stay "her own rows or the parent". Her sister can't see her look or badges; that isn't intended to change. Tests prove it both ways.
- **Kid grants:** EXECUTE on `kid_set_look`, `kid_badges`, `kid_look` only. The award functions are server-only (no kid or parent EXECUTE).
- **Backups and Download zip:** `badge_kinds` and the new columns are picked up automatically (every table). Because `badges` becomes append-only, the backup's "an append-only table shrank" check now covers it; the reset's existing one-time exception already lists it. I don't expect any change to the backup repo's scripts; if the build shows one is needed, I'll stop and show you first, as in Stage 9.
- **Restore drill:** I'll run it locally on a backup with badges and looks set, then once on a real production backup after the switches go on.

## 10. Tests

- **pgTAP `badges_test.sql`**, known answers for each rule, with cases that must award and must not:
  - First GIC: awarded at purchase; a renewal counts; a preview doesn't; feature off doesn't (then switching on does, dated the purchase day).
  - Kept it to the end: maturity awards; a broken GIC doesn't; a GIC maturing tonight while the check failed is caught next night.
  - Cool in a drop: a 10% drop held 30 days awards; 9.9% doesn't; a partial sell on day 12 doesn't; a waiting sell request doesn't; buying more during it still awards; under $10 doesn't; weekly backfill closes are ignored; a second drop after a broken one can award.
  - GIC ladder: 3 different dates awards; 3 same-date GICs don't; one under $10 doesn't; 2 active + 1 broken doesn't.
  - First dollar: $0.99 doesn't, $1.00 does (across savings and GIC interest); dividends and corrections don't count.
  - Goal reached: reaching it awards and sets `reached_at`; already above when set doesn't; lowering the price doesn't help; an ended goal doesn't.
  - Once only: running twice, catch-up nights, and an event check plus the nightly check give one badge and one notice.
  - Safety: a forced badge failure leaves `run_daily`, `reconcile_through` and `nightly_status` unchanged and the GIC purchase committed; `jobs_behind` and the health check ignore `badges`.
  - Security: her sister can't read her badges or look; kids can't insert or change badges; `kid_set_look` refuses a locked accessory, a colour off the list, an unknown animal and the switch being off; append-only guards; grants.
- **Vitest:** contrast for every colour, every animal and accessory file exists and has its anchor, the notice wording, the picker's locked and unlocked states.
- **Playwright:** the picker, Badges screen, Home with an avatar, and a question with her avatar, each at small phone, tablet and desktop, portrait and landscape, with normal and large text. Plus one screenshot sheet of all 16 animals wearing each accessory, for you to check every hat sits right.
- **Time machine:** badges added to the simulated year with known days; money to the cent unchanged. Run locally (it touches the nightly path) and the result shown to you.

## 11. What you test on the phone as test_kid (after the switches go on)

1. **Settings → Features:** switch **Make it yours** to "Test accounts only", then **Badges** to "Test accounts only".
2. Sign in as test_kid. Two What's new screens appear ("Make it yours", then "Badges"). Tap **Got it** on each.
3. **Home:** tap the avatar circle. Pick each colour in turn: the header, tabs and buttons change; savings, GIC and fund colours don't. Pick an animal. Tap **Looks great!**
4. Turn Android's large text on (Settings → Display → Font size and style → biggest) and check Home, the picker and Badges: nothing cut off. Rotate to landscape. Then put the text size back.
5. **The bell:** a notice "🎉 Badge: First GIC!" saying you earned it on Oct 15. **Home → Your badges:** First GIC shows with the party hat; the other five are "Still to discover".
6. **The picker:** the party hat is now selectable; the others are soft, with how to earn them. Put the party hat on; Home shows it.
7. **GIC ladder, safely on test data:** Buy / Sell → move **$10.00** savings → **3-month GIC**, then **$10.00** → **6-month GIC**. With the 1-month GIC from Oct 15, that's 3 rungs on 3 different dates: the top hat arrives right after the second purchase, with its notice. (Test money only; you can leave them or break them later. A break never takes a badge away.)
8. **Goal reached:** on the wish you added Oct 16 (day 7 is about Oct 23), set the price a little above her total worth, for example her total + $5, then **Make it my goal**. Request a **$10.00** deposit and approve it on your phone: the crown arrives at approval.
9. **Ask Dad a question** ("Something looks wrong?" on any line): her avatar shows next to it; on your phone it shows on the Approvals card.
10. **Your phone → View as test_kid:** same colour, avatar, hat, Badges screen and notices, and nothing in it can be changed. Your Dashboard card shows her avatar and badges.
11. **Coming by themselves:** **Kept it to the end** on the evening of Nov 15 (the 1-month GIC), and **First dollar of interest** once her interest adds up to $1.00 (likely with Dec 1's interest). **Cool in a drop** needs a real 10% fall, so it's proven by the tests and the time machine, not on the phone.

## 12. Production steps (after the local run passes and you OK each step)

Never between 7:00 and 11:45 am (the morning backup and health check) or from about 4:00 pm until that evening's nightly run is finished (it can run later than 5:00 pm if closes are late). As in Stage 9, the safe window is about 6:00–9:00 pm, once the evening's run shows done.

1. **Check tonight's run is finished:** Dashboard shows the nightly done; the outbox has nothing waiting.
2. **Backup by hand** (big-bucks-backups → Actions → Backup → Run workflow): green.
3. **Dry run:** `supabase db push --dry-run` lists only the two Stage 10 migrations.
4. **Push the migrations:** `supabase db push`, then a second dry run says "Remote database is up to date."
5. **Deploy the nightly function:** `supabase functions deploy nightly` (it now calls the badge check after reconcile). If this step came first by mistake, the call would simply fail inside its try/catch; no money is affected either way.
6. **Deploy the app** to GitHub Pages (push to `main`, CI green, Deploy run green).
7. **Backup by hand:** green; `counts.json` lists `badge_kinds` (6 rows) and `badges` (0 rows).
8. **The switches:** Make it yours, then Badges, each "Test accounts only". Then the phone test above.
9. **Backup by hand again,** then the **restore drill** on it (`npm run restore:drill -- <folder>`): every table and balance must match.
10. **The next evening:** check `job_runs` has a `badges` row marked ok after `reconcile`, and that every money job is ok as before.

## 13. Decisions for you

- **A. "Held through a drop":** A1, 10% below the high while she held, 30 days without selling (my recommendation); or A2, held until the price is back to the old high.
- **B. $10.00 minimum** per ladder rung and for the fund holding: yes (my recommendation) or no.
- **C. First dollar = interest only** (savings + GIC + late interest), cumulative: yes (my recommendation), or include dividends.
- **D. Goal reached:** the price when set or higher, and reached after she set it: yes (my recommendation).
- **E. The two extra accessories:** top hat for the ladder and a bow for the first dollar (my picks), or others you'd like.
- **F. A badge check that fails:** a Dashboard alert that does **not** turn the health check red (my recommendation: it's never money, so no email), or treated like any other failed job (red, and GitHub emails you).
- **G. Retroactive badges:** yes, from her whole history (my recommendation), or only from the day the switch goes on.
- **H. The eight colours** above: OK as they are, or swap any.
