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
