# Big Bucks — Kid-facing messages (draft for review)

Every message the girls can see from the money engine, exported from the database functions. The sources are the stage 2 migrations `supabase/migrations/20261002070000_engine_schema.sql` to `…20261002120000_reads.sql`.

**To suggest changes:** edit the wording here and tell Claude Code. Your edits come back to the database as a new migration; the existing migrations aren't changed. This file is a review copy and is regenerated from the migrations after each change.

**How to read it:** parts in `{braces}` are filled in when the message is shown. Money looks like $1,234.56, rates like 2.0%, dates like Nov 1, units like 0.23809524, terms like "1-month", "1-year" or "2-year", and fund names are Dow Jones, Nasdaq-100 and TSX. Messages only Dad sees (on the parent screens) and technical errors aren't listed.

## 1. Notices (the bell and the Home banner)

Each notice has a title and a body.

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
  - Body: Your request to put in {amount} waited 7 days without an answer, so it was cancelled. You can ask again any time.
- **Request expired (withdrawal)**
  - Title: Your request ran out of time
  - Body: Your request to take out {amount} waited 7 days without an answer, so it was cancelled. The money is free to use again, and you can ask again any time.

### Fund trades

- **Buy done**
  - Title: Your {fund} buy is done
  - Body: You bought {units} units at {price} each for {amount}.
- **Sale done**
  - Title: Your {fund} sale is done
  - Body: You sold {units} units at {price} each, and {proceeds} went into your savings.

### GICs

- **GIC matured**
  - Title: Your GIC is ready!
  - Body: Your {term} GIC finished and earned {interest}, so you now have {total}. Choose what happens next by {last day to choose}: renew it, pick a new term, or move it to savings. Until you choose, it earns the savings rate.
- **No choice after 7 days**
  - Title: Your GIC money is in savings
  - Body: You didn't choose within 7 days, so your {amount} moved to savings, where it's safe and still earning interest.

### Rates

- **Rate change, when Dad saves it**
  - Title: {Savings rate / {term} GIC rate} {drops from {old} to {new} / goes up from {old} to {new} / is {new}} {on {date} / today}
    - Example: Savings rate drops from 2.0% to 1.5% on Nov 1
  - Body: {Dad's note} plus one tip:
    - Savings rate dropping later: Tip: GICs bought before then keep today's rates.
    - GIC rate dropping later: Tip: a GIC bought before then keeps today's rate.
    - Any other GIC rate change: GICs you already have keep their locked-in rate.
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

### Deposit limit

- **Cap change**
  - Title: The deposit limit {goes up / goes down} from {old cap} to {new cap} {on {date} / today}
  - Body: {Dad's note} This is the most you can put in, minus what you take out. Interest and gains don't count.
  - Added when it goes down: If you've already put in more than that, nothing is taken away. You just can't add more for now.

### Questions

- **Dad answered**
  - Title: Dad answered your question
  - Body: {Dad's answer}

## 2. Errors on Buy / Sell and requests

Shown when she tries something the house rules don't allow. Nothing happens, and nothing is held.

### Any action

- Only a kid's account can do this.

### Deposits

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
- Your {fund} units are worth about {value}, so you can sell up to that (or choose "sell all").

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
- **Dividend:** {units} units × {last close of the quarter} × {yield} ÷ 4 = {exact}, rounded up to {amount}
  - Example: 0.23809524 units × $430.00 × 1.8% ÷ 4 = $0.4607, rounded up to $0.47
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
- **Moved automatically after 7 days:** Moved to savings automatically: no choice was made within 7 days.
- **Fund buy:** Bought {units} units of {fund} at {price} each.
- **Split:** {new}-for-{old} split: your {units before} units became {units after}. Each unit is worth less, so your holding is worth the same.

## 5. Market-move notes (on the Graphs tab)

Shown on a day a fund's close moves more than 2%. Dad can change these with the settings screen (stage 8), as well as here.

- **Big drop:** Big drop today. This happens a few times a year. Long-term, markets have recovered.
- **Big jump:** Big jump today. Markets go up and down, and one great day doesn't mean the next will be.

## 6. Screens: signing in, offline and "Updating…" (stage 6)

These come from the app's screens (`src/`), not the database, so wording edits here are a code change rather than a migration.

### Kid login

- **First time on a device:** Your username · Next
- **After that (her username is remembered on the device):** Hi, {her name}! · Enter your PIN · Not you?
- **Wrong PIN:** That PIN didn't match. Try again.
- **Wrong PIN, 2 or 1 tries left:** That PIN didn't match. {2 more tries / 1 more try} before a 15-minute break.
- **Locked (5 wrong PINs in a row):** Too many tries in a row, so this login is taking a short break. Try again in {minutes} minutes, or ask Dad for help.
- **No connection to the server:** Big Bucks couldn't reach the bank. Check your internet and try again.
- **Anything else going wrong:** Something went wrong on our side. Please try again in a minute.
- **A login with no Big Bucks profile:** This login isn't set up for Big Bucks yet. Ask Dad.

(An unknown username gets the same "That PIN didn't match" answer as a wrong PIN, on purpose, so the login screen never reveals which usernames exist.)

### Offline

- **You're offline** · Big Bucks needs the internet to show your money. It'll come back as soon as you're connected.

### "Updating…" (instead of her figures, while the nightly check has found something to fix)

- **Updating…** · Your numbers are being double-checked. They'll be back soon.

### The **?** explanations

The text comes from the glossary (`docs/GLOSSARY.md`); the button reads "What does "{term}" mean?" for screen readers, and the card closes with **Got it**.

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
| Correction | A correction (with its note) | +/−{amount} |
| Penalty | A penalty (with its note) | −{amount} |
| Waiting | Asked to put money in · Asked to take money out (Waiting for Dad) · Buying {fund} · Selling {fund} (Waiting for the market close) | {amount}, or All of it |
| Declined | Dad said not this time (money in / money out) · Dad says: "{reason}" | {amount} |
| Expired | A request ran out of time · Nobody answered within 7 days, so it was cancelled. You can ask again any time. | {amount} |

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
    - Fund sale: You can sell up to {most she can sell}, or all of it. (Her units' value rounded down to the cent, the same limit the database uses. Home and the warnings show the value rounded to the nearest cent, so they can be a cent higher.)
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
