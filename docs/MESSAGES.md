# Big Bucks — Kid-facing messages (draft for review)

Every message the girls can see from the money engine, exported from the database functions. The sources are the stage 2 migrations `supabase/migrations/20261002070000_engine_schema.sql` to `…20261002120000_reads.sql`.

**To suggest changes:** edit the wording here and tell Claude Code. Your edits come back to the database as a new migration; the existing migrations aren't changed. This file is a review copy and is regenerated from the migrations after each change.

**How to read it:** parts in `{braces}` are filled in when the message is shown. Money looks like $1,234.56, rates like 2.0%, dates like Nov 1, units like 0.23809524, terms like "1-month", "1-year" or "2-year", and fund names are Dow Jones, Nasdaq-100 and TSX. Messages only Dad sees (on the parent screens) and technical errors aren't listed.

## 1. Notices (the bell and the Home banner)

Each notice has a title and a body.

**Dad's own words (stage 8, the Approvals screen):** when Dad approves, declines or answers, his note, reason or answer goes into the notice exactly as he typed it. The only change is that an approval note gets a full stop added if it has none. Before he confirms, the Approvals screen shows him the whole notice under "{Name} will see:", word for word as it will appear. Stage 8 doesn't change any of the wording below.

### Deposits and withdrawals

- **Deposit approved**
  - Title: Your {amount} deposit is in!
  - Body: Dad approved it, so it's in your savings now. {Dad's note, if he wrote one}
- **Withdrawal approved**
  - Title: Your {amount} withdrawal is approved
  - Body: Dad approved taking it out of your savings. {Dad's note, if he wrote one}
- **Request declined**
  - Title: Dad said not this time
  - Body: Your request to {put in / take out} {amount} wasn't approved. Dad said: "{Dad's reason}"
- **Request expired (deposit)**
  - Title: Your request ran out of time
  - Body: Your request to put in {amount} waited {days} days without an answer, so it was cancelled. You can ask again any time.
- **Request expired (withdrawal)**
  - Title: Your request ran out of time
  - Body: Your request to take out {amount} waited {days} days without an answer, so it was cancelled. The money is free to use again, and you can ask again any time.

### Fund trades

- **Buy done**
  - Title: Your {fund} buy is done
  - Body: You bought {units} units at {price} each for {amount}.
- **Sale done**
  - Title: Your {fund} sale is done
  - Body: You sold {units} units at {price} each, and {proceeds} went into your savings.
- **The market was closed** (Dad recorded an unscheduled closure; pre-launch audit)
  - Title: The market was closed
  - Body: The {New York / Toronto} Stock Exchange was closed on {date}, so your {fund} {buy / sale} will happen at the next close, on {date}.
- **The market closed early** (Dad recorded an unexpected early close; second audit; only for trades asked for after the early close)
  - Title: The market closed early
  - Body: The {New York / Toronto} Stock Exchange closed early on {date}, before your {fund} {buy / sale} could happen. It will happen at the next close, on {date}.
- **Dad reset her PIN** (second audit)
  - Title: Dad reset your PIN
  - Body: Next time you sign in, type the code Dad gives you instead of your PIN. Then you'll choose a new PIN.

### GICs

- **GIC matured**
  - Title: Your GIC is ready!
  - Body: Your {term} GIC finished and earned {interest}, so you now have {total}. Choose what happens next by {last day to choose}: renew it, pick a new term, or move it to savings. Until you choose, it earns the savings rate.
- **No choice in her 7 days** (her last day to choose is later if the nightly run was late: pre-launch audit)
  - Title: Your GIC money is in savings
  - Body: You didn't choose by {last day to choose}, so your {amount} moved to savings, where it's safe and still earning interest.

### Rates

- **Rate change, when Dad saves it**
  - Title: {Savings rate / {term} GIC rate} {drops from {old} to {new} / goes up from {old} to {new} / is {new}} {on {date} / today}
    - Example: Savings rate drops from 2.0% to 1.5% on Nov 1
  - Body: {Dad's note} plus one tip:
    - Savings rate dropping later: Tip: GICs bought before then keep today's rates.
    - GIC rate dropping later: Tip: a GIC bought before then keeps today's rate.
    - Any other GIC rate change: GICs you already have keep their locked-in rate.
- **Rate change hidden behind a running special** (pre-launch audit: nothing changes for her until the special ends)
  - Title: {Savings rate / {term} GIC rate} after the special: {new}
  - Body: {Dad's note} The special at {special rate} keeps going until {end date}. After that, the rate will be {new}. (GICs: plus "GICs you already have keep their locked-in rate.")
- **Special, when Dad saves it**
  - Title: Special: {savings / {term} GICs} at {rate} from {start date} to {end date}
    - Example: Special: 1-year GICs at 6.0% from Nov 1 to Nov 7
  - Body: {Dad's note} After {end date} the rate goes back to {regular rate}. A GIC bought during the special keeps {rate} until it matures. (The last sentence is for GIC specials only.)
- **Rate change, on the day it starts**
  - Title: The new {savings / {term} GIC} rate is now {rate}
  - Body: It applies from today.
- **Special, on its first day**
  - Title: The {savings / {term} GIC} special at {rate} starts today
  - Body: It ends after {end date}.
- **Special, the day after it ends**
  - Title: The {savings / {term} GIC} special has ended
  - Body, GICs: {term} GICs are back to {regular rate}. GICs bought during the special keep {special rate}.
  - Body, savings: Savings is back to {regular rate}.

### Dividend rates (stage 8)

Sent like a rate change. A cut needs 7 days' notice; a raise can start right away.

- **Dividend rate change, when Dad saves it** (only when the number changes)
  - Title: The {Dow Jones / Nasdaq-100 / TSX} fund's dividend rate {drops from {old} to {new} / goes up from {old} to {new}} {on {date} / today}
    - Example: The Dow Jones fund's dividend rate drops from 1.8% to 1.0% on Oct 12
  - Body: {Dad's note} Dividends go into your savings on the first market day of January, April, July and October, using the rate on that day.
- **Dividend rate change, on the day it starts** (not sent when it started the day Dad saved it)
  - Title: The {fund} fund's new dividend rate is now {rate}
  - Body: It applies from today.

### A planned change is cancelled (stage 8)

Sent once, only to the kids who were told about the change: a rate change or special, a deposit limit change, or a dividend rate change. Nothing is sent for a change she was never told about (request expiry before its day, inflation, feature switches).

- **Rate change cancelled**
  - Title: The {savings rate / {term} GIC rate} change on {date} is cancelled
  - Special: The {savings / {term} GIC} special from {start} to {end} is cancelled
- **Deposit limit change cancelled**
  - Title: The deposit limit change on {date} is cancelled
- **Dividend rate change cancelled**
  - Title: The {fund} fund's dividend rate change on {date} is cancelled
- Body, all of them: {Dad's note} then either "The {savings rate / 1-year GIC rate / deposit limit / TSX fund's dividend rate} stays at {value}." or, when another change still happens that day, "On {date} the {…} will be {value}."
  - Example: Changed my mind. On Oct 13 the savings rate will be 2.25%.

### Time to answer a request (stage 8)

{days} is how long Dad had for that request: the rule in force on the day she asked (7 days to start; Dad can set 3 to 30). Each request keeps the time it had when she asked.

- **Dad changes how long he has to answer** (sent on the day the change takes effect: right away if it starts today, otherwise by that night's run; never repeated)
  - Title: Dad now has up to {days} days to answer your requests
  - Body: If he hasn't said yes or no to a deposit or withdrawal by then, it's cancelled and you can ask again. Requests you've already made keep the time they had.

### Deposit limit

A lower limit needs 7 days' notice (stage 8); a higher one can start right away.

- **Cap change**
  - Title: The deposit limit {goes up / goes down} from {old cap} to {new cap} {on {date} / today}
  - Body: {Dad's note} This is the most you can put in, minus what you take out. Interest and gains don't count.
  - Added when it goes down: If you've already put in more than that, nothing is taken away. You just can't add more for now.

### A mistake fixed (stage 8)

Sent right away when Dad adds to or takes from her savings to fix a mistake. The title is the same as her history line, so she can find it. {Dad's note} is exactly as he typed it; he sees this whole notice before he confirms. {line} is the history line it fixes, in her history's words (for example "Savings interest" or "Dad said not this time (money in)").

- **Title, fixing a line:** A correction · fixes {line} on {date}
- **Title, about a question with no line** (a question about a request): A correction · about your question from {date}
- **Body, money added:** Dad added {amount} to your savings. Dad said: "{Dad's note}"
- **Body, money taken out:** Dad took {amount} out of your savings. Dad said: "{Dad's note}"
  - Example: A correction · fixes Savings interest on Oct 1 · Dad added $1.24 to your savings. Dad said: "September interest was short"

### Questions

- **Dad answered**
  - Title: Dad answered your question
  - Body: {Dad's answer}

## 2. Errors on Buy / Sell and requests

Shown when she tries something the house rules don't allow. Nothing happens, and nothing is held.

### Any action

- Only a kid's account can do this.
- **The agreement isn't fully signed** (pre-launch audit, 2026-10-08; withdrawals, fund trades, buying or breaking a GIC, finishing onboarding):
  - Not signed yet: Sign your Big Bucks agreement with Dad first.
  - A new version (only new deposits wait; everything else keeps working under the version they both signed: Dad, 2026-10-08):
    - She hasn't signed it yet: Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed.
    - She has, Dad hasn't yet: You signed the new agreement! New deposits wait until Dad signs it too.
  - Her first agreement, before Dad signs, a second deposit: Your first deposit is already waiting for Dad.
  - **Her Home banner** while a new version waits: "Dad changed the house rules. Read your new agreement and sign it with Dad. New deposits wait until you have both signed. Everything else works like before." · **Read it**; after she signs: "You signed the new agreement! New deposits wait until Dad signs it too."
  - Dad hasn't countersigned: Dad hasn't signed your agreement yet. As soon as he does, this will work.
- **Dad, approving for a girl who never signed:** {name} hasn't signed her Big Bucks agreement yet, so nothing can be approved.
- **Dad, approving before he has countersigned:** {name} signed her agreement and is waiting for you to sign it too. Sign it first (it's at the top of Approvals), then approve this.
- **Dad's Settings → Logins** (PIN reset): "Reset {name}'s PIN" → "{name}'s PIN stops working now, and she's signed out on every device. You'll get a one-time code to give her: at her next sign-in she types it, then chooses a new PIN. She gets a notice." → "Give {name} this code: 123 456. It works for 7 days, and it's shown only this once. If it's lost, reset her PIN again." While waiting: "Waiting for her to choose a new PIN (her code works until {date})." A code that ran out: "Her code ran out before she used it, so she can't sign in. Reset her PIN again."

### Deposits

- **Before she has signed her agreement** (stage 8 B4): Before you can put money in, sign your Big Bucks agreement with Dad.

- The smallest deposit is $5.00.
- That's over your deposit limit. You can put in up to {room left} more.
- You've reached the deposit limit of {cap} for now. Money your savings earns doesn't count toward it.

### Withdrawals

- Choose how much to take out.
- You have {available} available to take out.
- The smallest withdrawal is $5.00, unless you're taking out everything that's left.

### Buying a GIC

- A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.
- The smallest GIC is $10.00.
- You have {available} available.
- There is no rate for a {term} GIC yet.

### Breaking a GIC early

- That GIC isn't yours.
- This GIC has already {matured / been broken}.
- This GIC reaches its maturity date today, so you won't lose any interest. It will be ready to choose soon.

### Choosing what happens to a matured GIC

- That GIC isn't yours.
- This GIC hasn't matured yet.
- This GIC was broken early, so there's nothing to choose.
- You already chose what happens to this GIC.
- The 7 days to choose are over, so this money is moving to savings.
- Choose renew, a new term, or savings.
- A GIC can be for 1, 3, 6 or 9 months, or 1 or 2 years.
- There is no rate for a {term} GIC yet.

### Buying or selling a fund

- There's no fund called "{fund}".
- Choose buy or sell.
- "Sell all" is only for selling.
- Choose an amount or "sell all", not both.
- The smallest trade is $10.00.
- You've already traded the {fund} fund today. You can trade it again tomorrow.
- You have {available} available.
- You don't have any {fund} units to sell.
- There's no price for the {fund} fund yet, so it can't be sold by amount.
- Your {fund} units are worth about {value}, so you can sell up to that (or choose "sell all"). ({value} is the value she's shown, to the nearest cent. Typing exactly that value sells all of it instead of refusing.)

### "Something looks wrong?"

- Write your question first.
- That's a long question! Please keep it under 2,000 letters.
- That line isn't in your history.

### Graphs

- You can only see your own account.
- Choose a date range of up to about 10 years.

## 3. "How was this calculated?" (the working on each line)

- **Savings interest, on the 1st**
  - Same balance and rate all month: {Month}: {balance} × {rate} ÷ {365 or 366} = {daily interest} a day, for {days} days = {total}, rounded up to {amount}
    - Example: September: $250.00 × 2.0% ÷ 365 = $0.0137 a day, for 30 days = $0.4110, rounded up to $0.42
  - Balance or rate changed during the month: {Month}: {days} days of interest added up to {total}, rounded up to {amount}
- **GIC interest, at maturity:** {principal} × {rate} × {term months}/12 = {exact interest}, rounded up to {amount}
  - Example: $100.00 × 2.5% × 1/12 = $0.2083, rounded up to $0.21
  - When no rounding is needed: $100.00 × 5.0% × 12/12 = $5.00
- **Dividend** (pro-rata from 2026-10-08: only for the days she held the units; the yield is the one on the payment day):
  - The same units all quarter: {units} units × {last close of the quarter} × {yield} ÷ 4 = {exact}, rounded up to {amount}
    - Example: 0.23809524 units × $430.00 × 1.8% ÷ 4 = $0.4607, rounded up to $0.47
  - The same units on every day she had any: You owned {units} units for {days} of the quarter's {quarter days} days: {units} × {close} × {yield} ÷ 4 × {days}/{quarter days} = {exact}, rounded up to {amount}
    - Example: You owned 0.23809524 units for 74 of the quarter's 92 days: 0.23809524 × $430.00 × 1.8% ÷ 4 × 74/92 = $0.3706, rounded up to $0.38
  - Her units changed during the quarter: Your units changed during the quarter: on average about {average units} over its {quarter days} days. {average units} × {close} × {yield} ÷ 4 = {exact}, rounded up to {amount}
- **Interest for money that reached savings late** (a close or dividend that came after that day's interest was worked out; pre-launch audit): Interest for the {n} days your {sale's money / dividend} waited to reach your savings ({from} to {to}): {amount waited} at the savings rate = {exact}, rounded up to {amount}
  - Example: Interest for the 2 days your sale's money waited to reach your savings (Nov 17 to Nov 18): $510.00 at the savings rate = $0.0559, rounded up to $0.06.
- **Fund sale:** {units} units × {price} = {exact}, rounded up to {proceeds}
  - Example: 0.47619048 units × $215.00 = $102.3810, rounded up to $102.39
  - Added when the price fell before the close: The price fell, so {amount} needed more units than you had: you sold all of them.

(Anywhere a line says "rounded up to", that part is left out when the exact amount is already whole cents.)

## 4. Notes on her history lines

- **Buying a GIC:** Bought a {term} GIC at {rate}.
- **Breaking a GIC early:** Broke a {term} GIC early: your {principal} came back, and the {interest earned so far} of interest earned so far was given up.
- **Moving a matured GIC to savings:** Moved your matured GIC to savings.
- **Renewing or a new term:**
  - On the old GIC: Moved into a new {term} GIC at {rate}.
  - On the new GIC: A new {term} GIC at {rate}, from your matured GIC ({principal} + {interest} interest).
- **Moved automatically after her 7 days:** Moved to savings automatically: no choice was made by {last day to choose}.
- **Fund buy:** Bought {units} units of {fund} at {price} each.
- **Split:** {new}-for-{old} split: your {units before} units became {units after}. Each unit is worth less, so your holding is worth the same.

## 5. Market-move notes (on the Graphs tab)

Shown on a day a fund's close moves more than 2%. Dad can change the standard wording below from **Settings → Market-move notes** (used for new notes from the day he picks), and reword any note already written; each change is logged. Edits made in the app aren't copied back here.

- **Big drop:** Big drop today. This happens a few times a year. Long-term, markets have recovered.
- **Big jump:** Big jump today. Markets go up and down, and one great day doesn't mean the next will be.

## 6. Screens: signing in, offline and "Updating…" (stage 6)

These come from the app's screens (`src/`), not the database, so wording edits here are a code change rather than a migration.

### Kid login

- **First time on a device:** Your username · Next
- **After that (her username is remembered on the device):** Hi, {her name}! · Enter your PIN · Not you?
- **Wrong PIN:** That PIN didn't match. Try again.
- **Wrong PIN, 2 or 1 tries left:** That PIN didn't match. {2 more tries / 1 more try} before a break.
- **Locked (5 wrong PINs in a row on her device, or 20 in a day from any devices):** Too many tries in a row, so this login is taking a break. Try again in {N minutes, up to 90; then N hours}, or ask Dad for help. (A lock lasts 15 minutes; a second within a day, an hour; a third, 24 hours.)
- **Dad reset her PIN** (she typed his code): Dad reset your PIN. Choose a new 6-digit PIN. · Your new PIN · Type your new PIN again
  - The two don't match: Those didn't match. Choose your new PIN again.
  - Her new PIN is Dad's code: Choose a new PIN that isn't Dad's code.
  - Her new PIN was saved but signing in failed just then: Your new PIN is saved! Big Bucks couldn't sign you in just now. Try again in a minute with your new PIN.
- **Signed out by a PIN reset** (any action from a device whose session was ended): You were signed out. Please sign in again.
- **No connection to the server:** Big Bucks couldn't reach the bank. Check your internet and try again.
- **Anything else going wrong:** Something went wrong on our side. Please try again in a minute.
- **A login with no Big Bucks profile:** This login isn't set up for Big Bucks yet. Ask Dad.

(An unknown username gets the same "That PIN didn't match" answer as a wrong PIN, on purpose, so the login screen never reveals which usernames exist.)

### Offline

- **You're offline** · Big Bucks needs the internet to show your money. It'll come back as soon as you're connected.

### "Updating…" (instead of her figures, while the nightly check has found something to fix)

- **Updating…** · Your numbers are being double-checked. They'll be back soon.

### The **?** explanations

The text comes from the glossary (`docs/GLOSSARY.md`; Dad can reword any explanation from **Settings → The ? explanations**); the button reads "What does "{term}" mean?" for screen readers, and the card closes with **Got it**.

### Placeholders until stage 7

- Home: Your savings, GICs and funds will show up here soon.
- Graphs, Buy / Sell and Wish List: Coming soon.
- Notices with none: Nothing new. You're all caught up!

## 7. Home and the GIC choice (stage 7)

From the app's screens (`src/kid/home/`, `src/kid/GicChoice.tsx`, `src/kid/History.tsx`), so edits are a code change. Notices themselves (titles and bodies) come from §1.

### Home

- **Total worth** · Watch your bucks grow.
- **"Your GIC grew!" card:** Your {term} GIC earned {interest}, so you now have {total}. Choose what happens next by {last day to choose}. · **Choose what's next**
- **Notices:** the newest unread notice, with **Got it**; under it, "1 more new notice" or "{n} more new notices". GIC "ready" notices aren't repeated here, because a waiting GIC has its own card.
- **Savings:** On hold · Free to use (only while a request is holding money) · Earning {rate} a year · Changing to {new rate} on {date} (when a change is announced)
- **GICs:** No GICs right now. A GIC locks your money away for a while and pays more interest than savings.
  - Each GIC: {amount} · {term} at {rate} · Ready {date} · {n} days to go · Earns {interest} by then
  - Matured and waiting: Ready now! · **Choose**
- **Stock funds:** Your mix · {fund} {n}% · Last market day, {date} (with the **?** for "Daily change")
  - Each fund: Yours: {value}, or You don't own any yet
  - The daily change: ▲ Up {n}% · ▼ Down {n}% · ● No change. Both directions are shown equally clearly, in calm colours, never red.
- **Recent activity** · See all · Nothing here yet. Your story starts with your first deposit!
- **"Updating…"** in place of any amount: Updating… Your numbers are being double-checked. They'll be back soon.
- **If Home can't load:** Big Bucks couldn't load your money just now. Please try again in a minute. · Try again

### History lines (Home's recent activity and "See all")

| Line | Words | Amount shown |
|---|---|---|
| Deposit | Money in | +{amount} |
| Withdrawal | Money out | −{amount} |
| Savings interest | Savings interest | +{amount} |
| GIC interest | Interest from your {term} GIC | +{amount} |
| Dividend | Dividend from {fund} | +{amount} |
| GIC bought | Bought a {term} GIC at {rate} | {amount} |
| GIC renewed | Renewed: a new {term} GIC at {rate} | {amount} |
| GIC to savings | GIC moved to savings (or "…automatically" after 7 days) | {amount} |
| GIC broken early | Broke a GIC early | {amount} |
| Fund bought / sold | Bought {fund} · Sold {fund} | {amount} |
| Split | {fund} split its units · Same value, more units. | |
| Correction | A correction · fixes {line} on {date} (or: A correction · about your question from {date}), with Dad's note | +/−{amount} |
| Penalty | A penalty (its note opens under "How was this calculated?", §9) | −{amount} |
| Waiting | Asked to put money in · Asked to take money out (Waiting for Dad) · Buying {fund} · Selling {fund} (Waiting for the market close) | {amount}, or All of it |
| Declined | Dad said not this time (money in / money out) · Dad says: "{reason}" | {amount} |
| Expired | A request ran out of time · Nobody answered in time, so it was cancelled. You can ask again any time. | {amount} |

- **"See all" page:** Your history · Show more · Back to Home

### The GIC choice

- 🎉 **Your GIC grew!** Your {term} GIC finished and earned {interest}. You now have {total}.
- **Choose by {date}.** If you don't choose by then, your {total} moves to savings, where it's safe and still earning interest. Until you choose, it earns the savings rate ({rate} a year).
- **What would you like to do?**
  - **Keep it growing:** Another {term} GIC at {rate}. (adds "(special rate!)" during a special)
  - **Try a different length:** Pick a shorter or longer GIC. Then **How long?** with each term and its rate, and "Special!" on a special.
  - **Move it to savings:** Use it any time. Savings pays {rate} a year.
- **Before anything happens:**
  - Put {total} into a {term} GIC at {rate}? · It will earn {interest} of interest. · It's ready in {term}. Then you choose again. · Taking it out early means losing that interest.
  - Move {total} to savings? · You can use it any time. · It earns {rate} a year in savings.
  - **Yes, do it** · **Go back**
- **Done:** 🎉 Done! Your {total} is growing in a new {term} GIC. Great patience! · or: Your {total} is in savings. · **Back to Home**
- **Nothing to choose** · There's nothing to choose for this GIC right now.

### Glossary change

- **Daily change** (new wording, in the migration `20261005000000_kid_home.sql`): How much a fund went up or down since the market's last day, as a percent. Markets go up and down all the time, and one day doesn't matter much. What counts is how it does over months and years.

## 8. Buy / Sell (stage 7)

From the app's screen (`src/kid/trade/`: wording in `tradeText.ts` and `moves.ts`), so edits are a code change. The **problems** she can hit (over the limit, too small, already traded today, and so on) are the database's own messages in §2, shown word for word. The screen checks them as she types, after she pauses, using `move_preview`. Times like "Monday's 3:00 pm close (Nov 2)" are worked out by the database.

### The form

- **Buy / Sell** toggle
  - Buy: Put money into savings, a GIC or a fund.
  - Sell: Take money out of a GIC, a fund or savings.
- **From** and **To** lists. Every move goes through savings:
  - Buy: 💵 Cash from Dad → 🐷 Savings; or 🐷 Savings → 🔒 A new GIC, 📈 Dow Jones, 📈 Nasdaq-100 or 📈 TSX
  - Sell: 🔒 One of your GICs (🔒 Your GIC when she has just one; she picks which on cards below), 📈 {fund} (funds she has units of), or 🐷 Savings → 🐷 Savings; 🐷 Savings → 💵 Cash to you
  - A fund already traded today: {fund} (traded today, again tomorrow)
  - Nothing to sell: You don't have any GICs or funds to sell right now.
- **How much?**
  - Under the box:
    - Deposit: You can put in up to {deposit room} more.
    - Fund sale: Your {fund} is worth about {value}. (The same value as Home, to the nearest cent. Typing it sells all of her units.)
    - Anything else: {available} free to use.
    - Each has a **?**: Deposit cap, Unit price or Available.
  - Fund sale: **Sell all of it** (the box then reads "All of it").
- **Breaking a GIC** (no amount box): **Which GIC?** with a card for each of her GICs, tapped to choose:
  - {amount} · {term} GIC at {rate} · Ready {date} (a GIC that matures today: Ready today)
  - Under the cards: A GIC comes out all at once. (**?** Breaking a GIC early)
- **Buying a GIC: How long?** Each term with its rate, "earns {interest}" on her amount once it's checked, and "Special!" on a special.
- **Notes instead of the amount box:**
  - You've already traded the {fund} fund today. You can trade it again tomorrow. One trade per fund each day helps you think it through.
  - This GIC is ready today, so you won't lose any interest. It will be ready to choose soon.
- **Next.** For a GIC before a term is picked, the button reads "Pick how long first". While checking: Checking…
- **If the check can't reach the bank:** Big Bucks couldn't check that just now. Please try again.

### Typing an amount

Shown under the box; nothing is checked with the bank until the amount makes sense.

- **Negative:** Amounts can't be less than zero. Type how much, like 25.
- **Letters or other characters:** Use numbers only, like 25 or 12.50.
- **A comma for cents ("12,50"):** Use a dot for cents, like 12.50.
- **More than 2 decimals:** Money only goes down to cents, so use at most 2 numbers after the dot, like 12.50.
- **Zero:** Type an amount bigger than $0.
- **8 digits or more:** That's a really big number! Check it and try again.

"$25", "25", "12.5" and "1,000" are all fine.

### Warnings (⚠️ cautions, 💡 good to know)

- ⚠️ **Breaking a GIC early:**
  - Moving money out of this GIC before it's ready means you lose all {interest earned so far} of interest earned so far. If you wait until {maturity date}, it earns {interest at maturity}.
  - If it hasn't earned anything yet: This GIC hasn't earned any interest yet. If you wait until {maturity date}, it earns {interest at maturity}.
- ⚠️ **Selling a fund worth less than she paid:** Your {fund} is worth {value} right now, but you paid {cost}. Selling now makes a loss of {loss} final. Markets go up and down, and nobody knows what comes next. (**?** Loss)
- 💡 **Deposit:** Dad needs to say yes first. Give him the cash, and it lands in your savings when he approves.
- 💡 **Withdrawal:** Withdrawals wait at least 24 hours, so you can sleep on it. Dad can say yes from {Oct 6 at 9:00 am}. Until then, this money is on hold.
- 💡 **Fund buy:** Your buy happens at {Monday's 3:00 pm close (Nov 2)}, at that day's price. It could be higher or lower than today's, so you'll see how many units you got after the close. (**?** Market close)
- 💡 **Fund sale, by amount:** Your sale happens at {close}. You'll get {amount}, as long as your units are still worth that much at the close. If they're worth less, you'll sell all of them.
- 💡 **Fund sale, all of it:** Your sale happens at {close}. You'll get whatever your units are worth at that day's price.
- 💡 **Fund sale, typing the value she's shown:** That's what all of your {fund} is worth, so this sells all of it. (Then the "all of it" note above, and the summary asks "Sell all of your {fund}?".)

The close reads "today's 2:00 pm close", "tomorrow's 2:00 pm close", "yesterday's …", or "{weekday}'s {time} close ({date})".

### The summary before anything happens

Each summary ends with **Yes, do it** and **Go back**.

- **Deposit:** Ask Dad to put in {amount}?
  - It goes into your savings once Dad says yes.
- **Withdrawal:** Ask to take {amount} out of your savings?
  - Dad can say yes from {time}.
  - Until then, this money is on hold.
- **GIC:** Put {amount} into a {term} GIC at {rate}?
  - It earns {interest} of interest by {date}.
  - It's locked for {term}. Taking it out early means losing the interest.
- **Break a GIC:** Take your {term} GIC out early?
  - Your {amount} goes back into savings.
  - You give up the {interest} of interest it has earned so far. (If it hasn't earned any yet: You give up the {interest at maturity} it would earn by {date}.)
- **Fund buy:** Buy {amount} of {fund}?
  - It happens at {close}.
  - Until then, the money is on hold in your savings.
- **Fund sale:** Sell {amount} of your {fund}? (or: Sell all of your {fund}?)
  - It happens at {close}.
  - The money goes into your savings.
  - If it's down: It's worth {loss} less than you paid.

### Done

Each ends with **Back to Home** and **Make another move**.

- **Deposit:** Asked! Dad will see your request. Your {amount} lands in savings when he says yes.
- **Withdrawal:** Asked! Dad can say yes from {time}. Until then, the money stays on hold.
- **GIC:** 🎉 Done! Your {amount} is growing in a {term} GIC. It's ready on {date}.
- **Break a GIC:** Done. Your {amount} is in savings.
- **Fund buy:** Done! Your {fund} buy happens at {close}.
- **Fund sale:** Done! Your {fund} sale happens at {close}. The money goes into your savings.

### Waiting (her requests that haven't happened yet; read-only)

Each line ends with "· asked {date}". With nothing waiting: Nothing waiting right now.

- Asked to put in {amount} · Waiting for Dad
- Asked to take out {amount} · Dad can say yes from {time} (after the 24 hours: Waiting for Dad)
- Buying {fund}: {amount} · Happens at {close}
- Selling {fund}: {amount} or all of it · Happens at {close}

### "Updating…" and errors

- **Updating…** Your numbers are being double-checked. They'll be back soon. You can make moves again once they're back.
- **If Buy / Sell can't load:** Big Bucks couldn't load your money just now. Please try again in a minute. · Try again

## 9. Notices, "How was this calculated?" and "Something looks wrong?" (stage 7)

From the app's screens (`src/kid/notices/`, `src/kid/home/ActivityList.tsx`, `src/kid/History.tsx`), so edits are a code change. Notice titles and bodies are §1; the working itself is §3 and §4, written by the database when the line was posted.

### The notices list (the bell)

- **Notices** · each notice: {title} · **New** (if she hadn't seen it) · {body} · {date}
- A "Dad answered your question" notice also has **See your questions**, which goes to her questions on the history page.
- Opening the list marks what's on it as read. The **New** tags stay until she leaves the list.
- **Nothing yet:** Nothing new. You're all caught up!
- **Show more** (after 50) · **Back to Home**
- **If it can't load:** Big Bucks couldn't load your notices just now. Please try again in a minute.

### A history line, opened (tap any line on Home or "See all")

- **How was this calculated?** followed by the line's working, on savings interest, GIC interest, dividends, fund buys and sales, a GIC broken early, and a penalty. Example: "$100.21 × 2.5% × 1/12 = $0.2088, rounded up to $0.21".
- Her questions about that line:
  - **You asked** ({date}): {her question}
  - **Dad answered** ({date}): {Dad's answer}, or: Waiting for Dad's answer.
- **Something looks wrong?**
  - What looks wrong? Dad will see this line with your question. (a box to type in)
  - **Send to Dad** · **Cancel**
  - **Nothing typed:** Write your question first.
  - **Sent:** Sent! Dad will answer here, and you'll get a notice when he does.
  - **A line that's a request** (waiting, declined or expired) has no ledger entry to attach yet, so the question is saved starting with: About "{line}, {amount}" on {date}: …
  - Other problems are the database's own words (§2, "Something looks wrong?").

### Your questions (on the "See all" page)

- **Your questions** · every question, newest first, with Dad's answer or "Waiting for Dad's answer."
- **None yet:** No questions yet. If a line ever looks wrong, tap it and choose "Something looks wrong?".

## 10. Graphs (stage 7)

From the app's screens (`src/kid/graphs/graphText.ts`), so edits are a code change. The market-move notes themselves are §5; the database's own errors are §2, "Graphs". The two new **?** words, **Growth** and **Money earned**, are in the glossary.

### Every graph

- **Graphs** · tabs: **Total worth** · **Growth** · **Money in** · **Mix** · **GICs** · **Funds**
- **Words to know:** each word with its **?** beside it.
- **Time range:** **1M** · **3M** · **6M** · **1Y** · **All** · **Since I bought** (screen readers hear "1 month", "3 months", "6 months", "1 year", "All of it", "Since your first buy")
- **Show in:** **$** · **%** (screen readers hear "Dollars" and "Percent"). Only on Growth and Funds.
- **Show as a table** · **Hide the table** (newest day first)
- **Loading:** Loading the graph…
- **If it can't load:** Big Bucks couldn't load this graph just now. Please try again in a minute. · **Try again**
- **Nothing yet:** Nothing to show yet. Once you have money in Big Bucks, it'll show up here.
- **While the nightly check is fixing something:** the "Updating…" message (§6) instead of the graph.

### Total worth over time

- How your savings, GICs and funds add up to your total worth.
- **Words to know:** Total worth
- The key: each option, with what it's worth today.
- **Money in** (a filled dot) · **Money out** (a hollow dot) · A dot marks a day you put money in or took it out, so new money isn't mistaken for growth.
- **Tooltip and table:** each option, **Total**, and on a day money moved: You put in {amount} / You took out {amount}.

### Growth by option

- How much each option grew by itself. Money you put in or take out doesn't count, only what it earned.
- **Words to know:** Growth · Risk
- The key: each option with its growth, like **+1.11%** (or in dollars, **+$4.50**).
- The same dots as Total worth, on the line where the money moved. **Tooltip:** {option} · You put in {amount}
- **When she has savings:** Savings interest arrives on the 1st of each month, so the savings line steps up a little then.
- Savings grows slow and steady, GICs grow in a step when they're ready, and funds bounce up and down.

### Money in vs money earned

- Money in is everything you've put in, minus what you've taken out. The gap up to your total worth is what your money earned.
- **Words to know:** Net deposits · Money earned
- Above the graph, big: **Money earned so far** · **{amount}** (like +$21.64, or −$13.95)
- Under it:
  - **When she's earned money:** That's what your money has made for you. 🎉
  - **When she's behind:** Right now your total worth is less than you put in. Funds go up and down, so that can change.
  - **When it's level:** Your total worth is the same as the money you put in.
- **For screen readers, on the graph:** So far, your money has earned {amount}. 🎉 / Right now your total worth is {amount} less than you put in. Funds go up and down, so that can change. / Your total worth is the same as the money you put in.
- The key: **Total worth** {amount} · **Money in** {amount}. **Table:** Day · Money in · Total worth · Earned

### My mix today

- Where your money is today.
- **Words to know:** Diversification
- The key: {option} **{percent}%** · {amount} (whole percents that add up to exactly 100)
- Spreading your money out is called diversification: one bad day doesn't hurt as much.
- **With everything in one place:** All your money is in {option} right now.
- **Table:** Option · Worth · Share

### GIC ladder

- When each of your GICs is ready, so you can see when your money unlocks.
- **Words to know:** GIC ladder · Maturity
- Each GIC: {amount} · {term} at {rate} · a bar from today to its ready date · Ready {date}: {what she'll get}, or Ready now: {amount}
- Under the bars: Today · 1 year · 2 years
- **None:** You don't have any GICs right now. You can buy one on Buy / Sell.
- **Table:** GIC · Started · Ready (or Now) · You'll get

### Stock fund detail

- The price of one unit of a fund, with your buys and sells marked.
- **Words to know:** Unit price · Volatility · Rate of return
- **Which fund?** Dow Jones · Nasdaq-100 · TSX
- **Her figures, labelled apart:**
  - **1M, 3M, 6M:** **The fund's change while you had it** {growth %} · **Your money's change** {dollars} · or: You didn't own any {fund} in this time.
  - **When they point opposite ways** (one plain sentence under them):
    - Fund up, money down: These point different ways because of timing: you had more money in the {fund} on its down days than on its up days. When you buy matters, not just what you buy.
    - Fund down, money up: These point different ways because of timing: you had more money in the {fund} on its up days than on its down days. When you buy matters, not just what you buy.
  - **Since I bought:** **Worth now** {value} · **You paid** {cost} · **Your money's change** {gain} ({percent}) · or: You don't own any {fund} right now.
- **The whole fund:** Over the whole time shown, the {fund} fund went up {percent}. / …went down {percent}. / …didn't change.
- The marks: ▲ **You bought** · ▼ **You sold** · ◆ **Big market days**
- Her trades: {date} · You bought {amount} at {price} / You sold {amount} at {price}
- **Big market days:** {date} · {the market-move note}
- Buying low and selling high is hard to time. Nobody knows tomorrow's price.
- **Table:** Day · Unit price · Change · You

## 11. Onboarding, the account agreement and What's new (stage 8 B4, draft for Dad's review)

**Status:** built in B4. Onboarding happens once, with Dad beside her (about 30 minutes). Steps for a feature that's switched off for her are skipped: the Wish List step if `wishlist` is off, and "Make it yours" if `personalisation` is off.

**Onboarding comes first** (Dad's B4 review, 2026-10-07): until it's finished, the rest of the app is locked. It unlocks as soon as she and Dad have both signed and her first deposit is in, so her first decision can open Buy / Sell. The bottom tabs and the bell stay visible but greyed out, and can't be opened. Tapping one shows, at the top of her step for a few seconds (in the page, so it never covers anything):

- Finish setting up first, then all of Big Bucks is yours!

Typing another app address brings her back to her step. If she leaves partway, she comes back to the step she was on (and the tour card), on any device. Dad's "View as" isn't locked.

**Numbers are never typed into the wording.** Each `{placeholder}` below is filled in from the database at the moment the screen is shown, so a change Dad makes in Settings shows up here by itself.

| Placeholder | Where it comes from | Today |
|---|---|---|
| `{cap}` | Setting `deposit_cap_cents`, in force today | $1,000.00 |
| `{expiry_days}` | Setting `request_expiry_days`, in force today | 7 |
| `{savings_rate}` | Today's savings rate (`current_rates`) | 2.0% |
| `{gic_lowest}`, `{gic_highest}` | Today's lowest and highest GIC rates (`current_rates`; lowest and highest rather than by term, so an inverted month still reads right) | 2.5%, 6.0% |
| `{cut_notice_days}` | The database's notice rule for a cut to a rate, dividend rate or the deposit limit | 7 |
| `{withdraw_wait_hours}` | The database's cooling-off rule for withdrawals | 24 |
| `{min_savings}`, `{min_invest}` | The database's minimums (savings; a GIC or a fund) | $5.00, $10.00 |
| `{gic_choice_days}` | The database's rule for choosing what happens to a matured GIC | 7 |
| `{goal_wait_days}` | The database's rule for how long a wish waits before it can become a goal | 7 |
| `{name}` | Her name | |

The last five are fixed rules in the database today, not Settings numbers. The screens will read them from the same place the rules are checked, never from a copy.

A **?** after a word opens its explanation (GLOSSARY.md).

### Welcome

- **Title:** Welcome to Big Bucks, {name}!
- **Under it:** Watch your bucks grow.
- **Body:** This is your very own bank and investing account. The money is real: Dad keeps the cash, and Big Bucks keeps track of every cent.
- **What we'll do together** (a numbered list; switched-off steps are left out and the rest renumbered):
  1. A quick look around
  2. Make it yours
  3. Your first wish
  4. Your Big Bucks agreement
  5. Your first decision
- **Button** (the only one): Let's get started

### 1. A quick look around (the tour; she can skip it)

One card at a time, and every card is part of onboarding (there is no skip). **Buttons:** Next · Back. The last card says **Done** instead of Next.

1. **Home 🏠**
   - Home shows everything you have. Your total worth **?** is at the top.
   - Under it are your three ways to grow money: savings, GICs and stock funds.
   - When something needs you, like a GIC that's finished, a banner tells you.
2. **Three ways to grow your money**
   - Each one has a good side and a catch: getting your money back quickly, or giving it time to grow more.
   - 🐷 **Savings** **?**: safe, and ready whenever you need it. It earns {savings_rate} a year in interest **?**, paid on the 1st of every month. New money always lands here first.
   - 🔒 **GICs** **?**: you promise to leave your money alone for a while, from 1 month to 2 years (the term **?**). In return you earn more: right now from {gic_lowest} to {gic_highest} a year. Your rate is locked in **?** the day you buy.
   - 📈 **Stock funds** **?**: a tiny piece of lots of companies, in three funds: Dow Jones, Nasdaq-100 and TSX. Over many years they have usually grown the most, but they go up and down, and they can be worth less than you put in.
3. **Graphs 📊**
   - Graphs show how your money has grown, and how each option did.
   - Tap any **?** to learn what a word means.
4. **Buy / Sell 🔁**
   - This is where you move your money.
   - Putting money in or taking it out waits for Dad, because real cash changes hands.
   - Moving money between your options happens by itself. Stock funds buy and sell at the next market close **?**.
5. **Wish List ⭐** (only if the Wish List is on)
   - Add things you'd love to have, and see how close you are.
   - Mom and Dad can see your wish list.
6. **The bell 🔔**
   - Notices from Dad and from Big Bucks land here, like a new rate or a request that's done.
   - A number on the bell means something new to read.

### 2. Make it yours (only if "Make it yours" is on)

- **Title:** Make it yours
- **Pick your colour** (her theme colours)
- **Pick your animal** (the avatars)
- **Under them:** You can change these any time.
- **Button:** Looks great!

### 3. Your first wish (only if the Wish List is on)

- **Title:** What would you love to save up for?
- **Fields:** What is it? · About how much? (you can skip this) · How much do you want it? (1 to 5 stars)
- **Under them:** Mom and Dad can see your wish list.
- **Buttons:** Add it · Skip for now
- **Added:** Added to your Wish List! If you still want it in {goal_wait_days} days, you can make it a savings goal.

### 4. Your Big Bucks agreement

- **Title:** Your Big Bucks agreement
- **Intro:** These are the house rules. Read them with Dad, and ask about anything that doesn't make sense. When you both agree, you each sign. A copy stays in your history.
- **The rules:**
  1. 💵 **The money is real.** Dad keeps the cash, and Big Bucks keeps track of every cent he owes you.
  2. 🐷 **New money goes into savings first.** You can put in up to {cap} altogether. Taking money out gives you room again. Interest and growth don't count, so your money can grow past {cap}.
  3. 🎁 **Birthday money and allowance can go in too.** Ask for a deposit the usual way, and it has to fit under your deposit cap.
  4. 🙋 **Dad says yes first** when money goes in or out, because real cash changes hands. Dad has up to {expiry_days} days to answer. If he hasn't answered by then, the request is cancelled and you can ask again.
  5. 😴 **Sleep on it.** When you ask to take money out, Dad waits at least {withdraw_wait_hours} hours before he can say yes, so you have time to think it over.
  6. ✋ **Money on hold.** While a request is waiting, its money is on hold **?**, so you can't use the same money twice.
  7. 🔢 **The smallest amounts** are {min_savings} for savings, and {min_invest} for a GIC or a stock fund.
  8. 🔒 **A GIC is a promise.** You leave the money for the whole term. If you break the promise early, you get your money back but you lose all its interest. When a GIC finishes, you have {gic_choice_days} days to choose what's next, or it moves to your savings.
  9. 📉 **Stock funds go up and down, and losses are real.** If a fund is worth less when you sell, you get less. A big drop can turn $100 into $80, and sometimes less, for a while. Markets have usually come back, but it can take a long time.
  10. 📈 **One trade per fund each day.** You can buy or sell each fund once a day. Buys and sells happen at the next market close.
  11. 📣 **Rates can change**, like at a real bank. If a rate or your deposit cap is going down, Big Bucks tells you at least {cut_notice_days} days before. Good news, like a higher rate, can start right away. A GIC you already have keeps its rate.
  12. ⚖️ **Fair for both of you.** You and your sister get the same rates and the same rules.
  13. 🔍 **Ask any time.** If something ever looks wrong, tap "Something looks wrong?" and Dad will answer. If there's a mistake, Dad fixes it openly, with a note you can read, and rounding always goes your way.
  14. 🔑 **Your PIN is yours.** Don't share it, not even with your sister. If you think someone knows it, tell Dad.
  15. 👀 **Mom and Dad can see your account.** They can look at your Big Bucks screens any time, just like your wish list.
     - If the Wish List is off for her, the sentence ends at "any time."
- **Dad's promises:** Dad keeps your cash safe, answers your requests, and fixes any mistake openly, with a note, rounding in your favour.
- **Her signature:**
  - I've read these rules with Dad, and I agree. — {name}
  - **Button:** Sign my agreement
- **After she signs:**
  - You signed it! Now it's Dad's turn.
  - Dad signs on his own phone. You'll get a notice when he does.
- **Notice when Dad signs** (to the bell):
  - Title: Your agreement is signed!
  - Body: Dad signed it too. You can read it any time in your history.
- **History line:** Your Big Bucks agreement · signed {her date}, Dad signed {Dad's date}
  - From the second version on: Your Big Bucks agreement (version {n}) · signed {her date}, Dad signed {Dad's date}
  - Opened, it shows the rules exactly as they were when she signed, numbers included, with both dates. Under them: Numbers like your deposit cap can change after you sign. When one does, you get a notice in the bell.

### When the house rules change (a new version to sign)

Only when a rule itself changes: a new rule, or a rule reworded. A number changing (the cap, how long Dad has to answer, a rate) doesn't need a new signature; she gets that change's usual notice. Every earlier version stays in her history, exactly as signed.

- **Notice** (to the bell):
  - Title: Your Big Bucks agreement has changed
  - Body: Dad changed the house rules. Read the new version with Dad, and sign it when you both agree. Your old agreement stays in your history.
- **Home banner:** Your Big Bucks agreement has changed. · **Read it**
- **The new version:**
  - Title: Your Big Bucks agreement (version {n})
  - Intro: Some house rules have changed. Read them with Dad, and ask about anything that doesn't make sense. When you both agree, you each sign.
  - Each rule that's new is marked **New**, and each rule that's reworded is marked **Changed**.
  - Her signature, the "Now it's Dad's turn" step and Dad's notice are the same as for the first version.

### 5. Your first decision

Starts once her first deposit is in her savings.

- **Before her first deposit** (asked for right here, because Buy / Sell is locked until onboarding is done; it's a normal deposit request with the usual rules):
  - Your first decision starts with your first deposit.
  - Ask Dad to put some money in. It goes into your savings once he says yes.
  - How much would you like to put in? (an amount box) · You're asking Dad to put in {amount}. · **Ask Dad**
  - Nothing typed: Type how much first. Other problems are the amount box's own words (§8) or the database's (§2).
- **While Dad hasn't said yes yet:**
  - You asked to put in {amount}. Waiting for Dad.
  - When he says yes, your first decision is next. · **Check again**
- **If Dad said no** (above the amount box, so she asks again right there):
  - Dad said not this time.
  - Dad says: "{Dad's reason}"
  - You can ask again.
- **If it ran out of time:** Your request ran out of time. · You can ask again.
- **Her deposit is in, but Dad hasn't signed yet:** 🎉 Your first {amount} is in your savings! · Dad hasn't signed your agreement yet. Once he does, your first decision is next. · **Check again**
- **Choosing a GIC or a stock fund** goes straight to Buy / Sell to do it (the app is hers now). Keeping it in savings shows the "Nice thinking!" screen.
- **If she leaves her first decision once the app is open,** Home shows: 👋 Let's finish setting up your Big Bucks. · **Keep going**
- **Title:** 🎉 Your first {amount} is in your savings!
- **Body:** Now for your first big decision: what should your money do? There's no wrong answer.
- **The choices** (each opens Buy / Sell, ready to go). Only choices she can afford with her free savings are offered:
  - 🐷 **Keep it in savings.** Safe and ready any time, earning {savings_rate} a year. Waiting is a real choice too. (Always offered.)
  - 🔒 **Put some in a GIC.** Earn more ({gic_lowest} to {gic_highest} a year right now) by promising to leave it alone. (Only with at least {min_invest} free.)
  - 📈 **Try a stock fund.** It could grow the most over time, but it can also go down. (Only with at least {min_invest} free.)
  - With at least {min_invest} free: Lots of people split their money between options. You can change your mind later (except that a GIC is a promise).
  - With less than {min_invest} free, instead of the GIC and fund choices: Once you have {min_invest}, you can try a GIC or a fund.
- **When she's chosen** (or chosen to keep it in savings):
  - You made your first money decision. Nice thinking!
  - You're all set. Welcome to Big Bucks!
  - **Button:** Go to Home

### What's new

Shown once, the first time she opens the app after Dad switches a feature on for her. One screen with a title, two or three short lines, and **Show me** (opens the feature) or **Got it**. The same title arrives in the bell as a notice (type `whats_new`), so she can find it again.

- **Wish List**
  - Title: New: your Wish List ⭐
  - Add things you'd love to have, give each one stars, and see how close you are to affording it.
  - If you still want something after {goal_wait_days} days, you can make it a savings goal.
  - Mom and Dad can see your wish list.
- **Make it yours**
  - Title: New: make Big Bucks yours 🎨
  - Pick your own colour and a cute animal.
  - You can change them any time.
- **Badges**
  - Title: New: badges 🏅
  - You earn a badge for smart money choices, like keeping a GIC until it finishes or staying calm when a fund drops.
  - Each badge unlocks something fun for your animal to wear.
- **Any later feature:** Title: New: {feature} · then its own two or three lines, drafted here before the feature is switched on.

### Added while building the screens (B4, new: not in Dad's reviewed draft)

- **In Dad's "View as" only, on her Home until she's set up:** 👋 Let's set up your Big Bucks with Dad. (before she signs) · 👋 Let's finish setting up your Big Bucks. (after). She never sees these: she's on her welcome screens.
- **The tour's cards:** a count above each title, for example "2 / 5".
- **After she signs, once Dad has signed too:** ✍️ Dad has signed it too.
- **The first decision, after choosing a GIC or a fund:** the same "You made your first money decision. Nice thinking!" and "You're all set. Welcome to Big Bucks!", with **Go to Buy / Sell** instead of Go to Home (she makes the move there).
- **History line before Dad signs:** Your Big Bucks agreement · signed {her date}, waiting for Dad to sign
- **Her "See all" page:** a **Your Big Bucks agreement** section. With nothing signed: You haven't signed your Big Bucks agreement yet.
- **What's new buttons:** **Show me** (only when the feature has a screen to open) · **Got it**

### Dad's answers (2026-10-05)

1. **Gifts and allowance:** yes, within the deposit cap, through a normal deposit request (rule 3).
2. **The signed copy is frozen**, and a changed number comes by notice. A new or reworded rule means a new version to sign; the old one stays in her history (see "When the house rules change").
3. **Dad signs on his own phone**, with the authenticator code, logged like every parent action.
4. **Fixed rules are read from the database** like the settings, so the wording can never disagree with a rule.
5. **The crash example** is now Dad's wording (rule 9).
