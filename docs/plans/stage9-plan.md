# Stage 9 plan — Wish List and goals

Status: **approved by Dad 2026-10-16** (A1, B1 and C1, with four conditions: see PROGRESS, Stage 9). Built and tested locally; not in production yet.

Everything is behind `feature:wishlist`. "Done" means `supabase test db`, `npm test` and the Playwright tests pass, and the switch is on for test accounts only.

## 1. What this stage doesn't touch

- **No money moves.** Nothing writes to `transactions`, `interest_accruals`, `gic_holdings`, `requests`, `rates` or `settings` (the only settings change is Dad flipping the switch on the existing Settings screen).
- **No nightly or morning job changes.** `run_daily`, `nightly_kick`, `morning_kick`, reconcile and the outbox stay exactly as they are. Nothing in this stage reaches outside the database, so `in_preview()` doesn't come up.
- **Reads only.** Progress and the projected date *read* her total worth (the existing derived functions) and today's savings rate. They post nothing and round nothing that gets posted.
- **So no local time machine run is needed.** CI still runs it on every push. If any step ends up touching money logic, I'll stop, tell you, and run it.
- **What does change outside the screens:** the pre-launch reset clears one more table (decision A), and the backup and Download zip pick that table up. I'll prove both with tests and a local restore drill.

## 2. Decisions for you

### A. Where photos live (the big one)

**The conflict:** BUILD-PLAN says "Photos are stored in Supabase Storage". SPEC's Build decisions (Stage 5) say "Storage isn't used; the backup fails if it ever holds anything". That rule is real code: `guards.ts` in the backup repo fails the backup if `storage.objects` has any rows. So the first photo saved to Storage would turn every backup red.

**Option A1 — photos in the database (my recommendation).** A new table `wishlist_photos` (item id, picture type, the picture bytes, when added), one photo per item.
- **Backups:** nothing in the backup code changes. The snapshot, `counts.json` and the checksums already find every table by themselves (`listTables` in `snapshot.ts`). The Storage guard stays as it is and keeps protecting us.
- **Download zip:** included automatically (`parent_backup_export()` already exports every table), as text in the CSV and JSON.
- **prelaunch_reset:** a new migration adds `wishlist_photos` to the list of tables it clears, next to the items and marks. Its "the backup must match" check covers the new table the same way.
- **Restore:** the restore drill already compares every table's rows and checksum, so photos come back to the byte and are checked. Nothing new to restore by hand.
- **RLS:** the same rule as the items: her own rows, or the parent.
- **Size:** each photo is shrunk on the phone to at most 800 px on its long side, then saved as a JPEG. The database refuses anything over 150 KB, and each kid can have at most 30 photos. Worst case about 9 MB for both girls, far below the 400 MB alert.
- **Cost:** the backup repo grows by about the size of each new photo. Rows are written in a stable order, so git stores only what changed. Before you approve the production push, I'll check this locally with 30 fake photos.

**Option A2 — Supabase Storage, as BUILD-PLAN says.** A private bucket with Storage policies.
- **Backups:** the backup would need to download each photo through the Storage API. That needs a new key the backup workflow can hold, which it doesn't have today (it never holds the service role key, by design). The Storage guard would need to allow this one bucket, and check-incoming.sh would need to let picture files through. You'd copy all of that to big-bucks-backups by hand (Guard 1).
- **Download zip:** the download-backup function would have to fetch every photo from Storage and add it to the zip.
- **prelaunch_reset:** it runs as SQL in the SQL Editor, and SQL can't delete Storage files (Supabase blocks deleting `storage.objects` rows directly). The photos would have to be cleared some other way, with a separate step for you.
- **Restore:** the drill would need a new step to upload the photos into the throwaway Supabase and compare them.
- **Writes:** uploading straight to Storage is a direct write from the app, which breaks "the app never writes to tables directly". To keep that rule, uploads would go through a new Edge Function.

**Why A1:** it keeps every Stage 5 safeguard as it is, and it keeps "the app only writes through Postgres functions". It also means the backup, Download zip, reset and restore each have one less thing that can go wrong, and none of it needs new keys. A2 is several new moving parts in the safety-critical backup path for a feature that isn't money. If you pick A1, I'll update BUILD-PLAN and SPEC so they agree ("photos are stored in the database").

### B. How many goals at once

- **B1 — one goal at a time (my recommendation).** Making a new goal asks "Switch your goal to X?" and the old one goes back to her wish list.
- **B2 — up to three goals.**

**Why B1:** every goal's progress is worked out from her *whole* total worth. With three goals, $200 would show 40% toward the bike *and* 40% toward the game, as if she could have both. One goal keeps the bar honest and the lesson simple. Her other items still show "x% of the way there", but only her goal gets the bar on Home.
**Backups, Download zip, reset, restore:** no difference between B1 and B2. Goals live in the existing `goals` table, which is already backed up, exported, cleared by the reset and checked by the drill. A new migration adds `ended_at` to it, so a switched or dropped goal is kept rather than deleted.

### C. What the projected date is based on

- **C1 — her whole total worth growing at today's regular savings rate, adding nothing, shown only within 5 years (my recommendation).**
- **C2 — each part at its own rate:** savings at the savings rate, GICs at their locked rates until they mature, funds at some expected stock return.
- **C3 — savings balance only, ignoring GICs and funds.**

**Why C1:**
- The funds have no "rate". Any growth number for them would be a guess, and a projection built on one could read like a promise (C2).
- Ignoring her GICs and funds would make good decisions look like they slow her down (C3).
- C1 is simple and can only guess low: GICs pay more than savings, and specials are left out because they end.
- The 5-year limit matters at 2%. $100 growing to $450 on interest alone would take about 75 years. So beyond 5 years she sees the real lesson instead of a silly date.

The database works it out from the regular savings rate in force today, compounding monthly like the real interest, rounded to a month.

**Wording (draft, for MESSAGES):**
- Within 5 years: "If your money keeps growing like your savings does now, and you add nothing, you could have enough around **March 2028**. That's a guess, not a promise. Adding money gets you there sooner."
- Beyond 5 years: "Interest alone would take more than 5 years. Adding money, like birthday or allowance money, is the fastest way there."
- She already has enough: "You have enough for this! Talk to Mom and Dad about it." (This doesn't move any money.)
- No price yet: "Add a rough price to see how close you are."

**Backups, Download zip, reset, restore:** nothing changes. The projection is worked out every time it's shown and never stored.

## 3. What gets built

### Database (new migrations only; no committed migration is edited)

1. `20261027000000_wishlist.sql`
   - The `wishlist_photos` table (if A1), with RLS.
   - `goals.ended_at`. `wishlist_items.photo_url` is dropped: nothing ever wrote to it, and production has no wish list rows yet.
   - **Kid functions** (each one checks she is a kid, her own item, and that `feature_enabled('wishlist', her account)`; otherwise refused with kind words):
     - `wish_add(name, price_cents, link, stars)`
     - `wish_update(item, …)`: changing the **name** restarts the 7 days (so "thing" can't become a new impulse on day 8); changing the price, stars or link doesn't.
     - `wish_set_photo` / `wish_remove_photo`
     - `wish_reorder(ids in order)`: must list exactly her current items.
     - `wish_done(item, 'got_it' | 'removed')`: moves it to Done.
     - `wish_make_goal(item)`: refused before day 7, with "You can make this a goal on Fri Oct 23". Needs a price.
     - `wish_stop_goal()`: the goal goes back to a normal item.
   - **Kid read:** `kid_wishlist()` gives her items in order, with % of the way there and the projected-date words, plus the Done list. It never reads the marks table.
   - **Parent functions** (parent with MFA, each writing one `parent_actions` row in the same transaction): `parent_wishlist_mark(item, got_it true/false, optional note)` and the read `parent_wishlists()`. A new migration widens the `parent_actions` action list with `wishlist_mark`.
   - **The 7-day rule** uses Alberta dates from `app_today()`. An item added Oct 16 can become a goal from Oct 23.
   - **Limits, enforced by the database:**
     - name 1–60 letters;
     - price optional, $1.00 to $100,000.00, integer cents;
     - stars 1–5;
     - at most 50 items on her list and 30 photos.
   - **Percent** is worked out in the database and rounded *down*, so "100%" only shows when she really has enough.
2. A small migration that replaces `private.prelaunch_tables()` to add `public.wishlist_photos` (if A1).

### Links (any URL she pastes)

- **Stored only if it starts with `http://` or `https://`**, at most 500 characters, with no spaces or hidden characters. `javascript:`, `data:` and anything else is refused.
- **Shown as text only:** just the site's name (for example "amazon.ca"), never a preview or a picture from the site. The app never fetches the link. A look-alike foreign address shows its `xn--` form, so it can't pass as a real shop.
- **Opens outside Big Bucks.** An **Open link ↗** button opens Chrome in a new tab (`target="_blank" rel="noopener noreferrer"`), under a line saying "This opens outside Big Bucks."

### Photos (if A1)

- **Taking one:** the phone's picker (camera or gallery). The app shrinks it and saves it as a new JPEG. This also **removes the photo's hidden details, including where it was taken**.
- **Limits:** the database accepts only a JPEG of at most 150 KB and checks the file's first bytes. A photo the phone can't open (some HEIC pictures) says: "That photo didn't work. Try another one or a screenshot."
- **When an item is removed or received**, it moves to Done with its photo. She can remove a photo any time. Photos go only with the pre-launch reset, or if she removes them.

### Screens

- **Wish List tab** (`src/kid/wishlist/`): the "Mom and Dad can see your wish list" line at the top, her items with stars, rough price, a % bar and the projected words.
  - Reordering with **Move up / Move down** buttons, not dragging. Dragging is fiddly on Android and with large text.
  - **Add / Edit** form.
  - From day 7, **"Still want this?"**: Yes, make it my goal · Not now.
  - **I got this** / **Remove**, then a **Done** list underneath.
- **Home:** a goal card when she has a goal: the name, a progress bar, "You're 40% of the way there" and the projected words.
- **Onboarding step 3, "Your first wish"**, using the wording already in MESSAGES §11. It shows only when the switch is on for her (the database's step list already allows for it).
- **Parent: Wish lists** (new screen in the parent menu): each kid's list and Done list, with photo, link and a **Got it** toggle with an optional note ("Got it — Mom, for her birthday").
  - Kids whose switch is off show "The Wish List is off for {name}".
  - "View as" stays exactly what she sees, so it never shows the marker.
- **Layout:** every screen checked at small phone (360 px), tablet and desktop, portrait and landscape, with large text, using the existing `layoutCheck`.

### Tests

- **pgTAP `wishlist_test.sql`:**
  - **The 7-day rule:** refused on days 0–6, allowed on day 7 (clock override), restarted by a name change, unaffected by a price change. A goal needs a price. Only one goal at a time.
  - **RLS:** a kid sees only her own items, photos and goals. The other kid sees nothing of hers.
  - **The marks are invisible to kids:** a kid can't select `wishlist_parent_marks` or reach it through any kid function (each kid function's output is checked for the marker, with an item marked).
  - **No direct writes:** kids can't insert, update or delete any wish table directly.
  - **The feature switch:** every kid function is refused while the switch is off for her, and works for a test account when it's on for test accounts only.
  - **The parent rules:** the mark needs MFA and writes one `parent_actions` row.
  - **The limits:** links, photo type and size, item and photo counts, and percent rounded down.
  - **The projection** gives known answers at the 2% rate, including the 5-year cut-off.
  - **The reset:** `prelaunch_reset` clears items, photos, marks and goals, and keeps the accounts.
- **Vitest:** the link display (site name, `xn--`, refusing `javascript:`) and the photo shrinker's size and type.
- **Playwright `wishlist.spec.ts`:**
  - The test kid adds an item with a photo and link, reorders, moves the time-machine clock forward 7 days, and makes it her goal.
  - The goal shows on Home. She removes another item, and it's in Done.
  - The parent marks Got it, and the kid's screen still shows nothing different.
  - Run at phone, tablet and desktop sizes.
- **Backups:** a local backup and `npm run restore:drill` with photos in place, to show they come back to the byte. The 30-photo repo-growth check from decision A.

### Docs

- **MESSAGES:** new Wish List and goal wording.
- **SPEC and BUILD-PLAN:** the photo decision.
- **PROGRESS:** the stage close-out.
- **ACCEPTANCE:** tick "Wish list items can be added and reordered, and become goals only after 7 days" once proven on production with the test kid.

## 4. Production steps, in order (each only after your OK)

1. Everything passes locally (`supabase test db`, `npm test`, Playwright). I commit and push, and CI goes green.
2. **Dry run:** `supabase db push --dry-run`. I show you the list of migrations it would apply (it should be the two or three new Stage 9 files only).
3. **You approve, then the real run:** `supabase db push`.
4. **Deploy the app:** GitHub → Actions → **Deploy to GitHub Pages** → **Run workflow** on `main` (deploy is still by hand).
5. **Switch it on for the test kid:** in the app as Dad: Settings → Feature switches → **Wish List** → **Test accounts only** → start today → **Preview** → **Save** (authenticator code).
6. **Next morning:** check the Backup run is green, with `public.wishlist_photos` in its `counts.json`.

## 5. What you test on the phone as test_kid (after step 5)

1. Sign in as the test kid. A **Wish List** tab appears (the real girls don't have it). A "What's new: your Wish List ⭐" screen shows once.
2. The top of the tab says "Mom and Dad can see your wish list."
3. **Add** an item with a name, a rough price, 4 stars, a link pasted from Chrome, and a photo from the camera. Check that:
   - it shows "You're x% of the way there";
   - the projected words show;
   - the link shows only the site's name.
4. Tap **Open link ↗**. It opens in Chrome, outside Big Bucks. Come back to Big Bucks.
5. Add two more items (one with no price: it says "Add a rough price…"). Use **Move up / Move down** to reorder, then close and reopen the app: the order is kept.
6. Try to make the first item a goal today. It says which day you can (7 days from today).
7. **Remove** one item and mark another **I got this**. Both are in the **Done** list.
8. **As Dad:** open **Wish lists**, mark an item **Got it** with a note. Check that **View as** test kid doesn't show the marker. Back as the test kid, nothing looks different.
9. **On day 7** (about Oct 23 if you add it Oct 16): "Still want this?" → **Yes, make it my goal**. Home shows the goal card with its bar and words.
10. Repeat steps 2–3 and 9 on the tablet in portrait and landscape, and with Android's large text on.
11. **The next morning:** the Backup is green.

## 6. Anything you do by hand

- Production steps 3–5 (after my dry run), and the step 6 check.
- **Nothing in big-bucks-backups changes if you pick A1.** If you pick A2, you'd also copy the backup changes over by hand, give the workflow a new key, and take a separate step at the pre-launch reset.
