# Big Bucks — Runbook

Step-by-step jobs for Dad: setting up production (Stage 4), and what to do when something goes wrong. Menu names are as of 2026-10; if Supabase or GitHub has moved one, the setting has the same name.

## Never do these

- **Never run `supabase db reset --linked`.** It wipes the production database completely: every girl's money history. Only ever run `supabase db reset` without `--linked` (that's your own computer).
- **Never run `supabase db push --include-seed`.** The seed is for your computer only. (On a production database that has been marked, below, it refuses anyway.)
- **Never point `npm run timemachine`, `npm run demo` or `npm run jobs:local` at production.** They already refuse anything but your own computer, and refuse a database marked as production.
- **Never paste a key or password into a chat, an issue, a commit or a SQL query.** Keys go only into Supabase's secret settings, GitHub's secret settings and your password manager. The setup script asks for the service role key itself and never saves it.

## Production setup (Stage 4)

Do these in order. ✋ means you do it by hand. Claude runs nothing on production without your OK for that step.

Before you start, have your password manager open. You'll make and keep:
- the database password (step 1);
- two long random strings, `HEALTH_CHECK_KEY` and (later) `NIGHTLY_KEY`. Let the password manager generate each: at least 40 characters, letters and numbers only.

### 1. ✋ Create the project

1. Supabase Dashboard → **New project**.
2. **Name** `big-bucks`. **Database password**: generate a strong one and save it in your password manager. **Region**: **Canada (Central)**. **Plan**: **Free**.
3. Click **Create new project** and wait until it says it's ready.
4. Note the **project ref**: **Project Settings** → **General** → **Project ID** (20 lowercase letters). Its address is `https://<project ref>.supabase.co`.

### 2. ✋ Sign-in settings

1. **Authentication** → **Sign In / Providers**:
   1. **Allow new users to sign up**: off.
   2. **Email**: on. Open it and turn on **Secure password change** → **Save**. (Kids can't change theirs at all; the database refuses it. This covers your own login.)
2. **Authentication** → **Multi-Factor**: **TOTP (App Authenticator)** on → **Save**.
3. **Authentication** → **URL Configuration** → **Site URL**: `https://jarrettwd.github.io/Big-Bucks/` → **Save**.

### 3. ✋ Max rows: 20,000

**Project Settings** → **Data API** → **Max rows** → type **20000** → **Save**. The default 1,000 would cut off the graphs' longer ranges (Growth by option already passes 1,000 rows for one year with three options).

### 4. ✋ Two Edge Function secrets

**Edge Functions** → **Secrets** → **Add new secret**, once for each:

1. `ALPHAVANTAGE_API_KEY`: your Alpha Vantage key.
2. `HEALTH_CHECK_KEY`: the first long random string from your password manager.

(`NIGHTLY_KEY` comes in step 7: the database makes it.)

### 5. Link, push, deploy

1. ✋ In a terminal in the project folder, run this once and sign in in the browser it opens:

```bash
npx supabase login
```

2. Then tell Claude the project ref. With your OK, Claude runs these three and shows you the output of each:
   1. `npx supabase link --project-ref <project ref>` (asks for the database password: you type it);
   2. `npx supabase db push` (all the migrations, never the seed);
   3. `npx supabase functions deploy kid-login nightly health`.

### 6. ✋ Mark production and check it (SQL Editor)

In the Supabase Dashboard, **SQL Editor** → **New query**. Paste each line, click **Run**, and check the answer.

1. **Mark production, right after the first push:** `select public.mark_production();` It answers "Marked as production: the time machine is off for good." Running it again is harmless.
2. **Check the time rules:** `select * from public.check_time_rules();` Every row must show `ok = true`, except the one information-only row (ok empty). The row "Marked as production …" must say `yes`. Any `ok = false` row means stop and ask before going further.
3. **Check the login key and the login guard exist** (the first push is the first time hosted Supabase runs them):
   1. `select count(*) from vault.secrets where name = 'kid_login_key';` must answer `1`.
   2. `select tgname from pg_trigger where tgname = 'protect_kid_login';` must answer one row.

   If either is missing, stop and ask.
4. **Check the nightly timer:** `select jobname, schedule from cron.job;` must answer one row: `big-bucks-nightly`, `0,30 22,23,0,1,2,3,4 * * *` (every 30 minutes from 4:00 to 10:30 pm Alberta time; the run itself starts at 4:30 pm).

### 7. ✋ The nightly function's address and key

1. In the SQL Editor, with your project ref in place of the placeholder:

```sql
select public.set_nightly_vault('https://YOUR-PROJECT-REF.supabase.co/functions/v1/nightly');
```

2. It answers a long key, shown only this once. Copy it into your password manager as `NIGHTLY_KEY`. (The database keeps its own copy in Vault. Running this again makes a new key; then update both places below.)
3. **Edge Functions** → **Secrets** → **Add new secret**: `NIGHTLY_KEY`, the same key.

Until both are in place, the timer does nothing (it says "not set up").

### 8. ✋ GitHub

1. On GitHub, the Big-Bucks repo → **Settings** → **Secrets and variables** → **Actions**.
2. **Secrets** tab → **New repository secret**, once for each:
   1. `HEALTH_CHECK_KEY`: the same string as in step 4.
   2. `NIGHTLY_KEY`: the key from step 7 (the backfill uses it).
3. **Variables** tab → **New repository variable**, once for each:
   1. `VITE_SUPABASE_URL`: `https://<project ref>.supabase.co`.
   2. `VITE_SUPABASE_ANON_KEY`: Supabase Dashboard → **Project Settings** → **API Keys** → the **anon** (or **publishable**) key. Never the service role or secret key: the deploy refuses one.
4. Your picture (top right) → **Settings** → **Notifications** → **Actions**: **Email** on, **Only notify for failed workflows** on.

### 9. ✋ Load the price history

1. Repo → **Actions** → **Backfill prices** → **Run workflow** → **Run workflow**.
2. It takes 1 to 2 minutes and about 6 Alpha Vantage calls. The TSX fund goes first: if its symbol (`XIC.TRT`) doesn't work, the run stops after one call and says so. Then stop and ask.
3. When it's green, check in the SQL Editor: `select fund_id, source, count(*), min(price_date), max(price_date) from public.fund_prices group by 1, 2 order by 1, 2;` Each fund should have about 100 `daily` rows and about 80 `weekly_backfill` rows back to two years ago.

Running it again is harmless: it only fills gaps and never changes a stored close.

### 10. Deploy, accounts and your phone

1. ✋ Repo → **Actions** → **Deploy to GitHub Pages** → **Run workflow**.
2. Your parent account and one **test** kid, with the production setup script. In a terminal in the project folder:

```bash
npm run setup-account:prod -- --production
```

   It asks for the project ref twice, then the service role key (**Project Settings** → **API Keys** → **service_role** or **secret**; paste it, it stays hidden and is never saved), then the same questions as the local script. Run it once for `parent`, once for a test `kid`. The girls' real accounts wait for the Stage 12 audit; the script asks you to type "real" before making a real kid.
3. ✋ On your phone, open `https://jarrettwd.github.io/Big-Bucks/` in Chrome → menu (⋮) → **Add to Home screen** → **Install**.
4. ✋ Sign in as yourself: the first sign-in sets up the authenticator app.

### 11. ✋ Check the alerts reach you

1. Repo → **Actions** → **Health check** → **Run workflow** → tick **Send test alert** → **Run workflow**.
2. It fails on purpose ("Test alert from Big Bucks…"). Within a few minutes GitHub emails you about the failed run. If no email comes, check step 8.4.
3. In the app, the parent **Dashboard** shows "Test alert from the daily health check…". Tap **Acknowledge**.
4. Run the workflow once more without the tick: it must be green. (If it's red, the message says why. Right after setup, "the … job has only finished through …" is normal until the first nightly run; check again the next morning.)

### 12. ✋ Which address the login sees

After the kid-login function is deployed, sign in as the test kid once, then in the SQL Editor run `select client, attempted_at from public.login_attempts order by id desc limit 3;`. Sign in again from your phone on mobile data (not Wi-Fi): the `client` value must change. If it stays the same, the device lockout can't tell devices apart; stop and ask.

### 13. ✋ A caller can't choose his own device address

The forged-header test (third audit). On your computer, in a terminal in the project folder, run this twice, with your project's address and its anon key (**Project Settings** → **API Keys**) in place of the two placeholders, and a username that isn't a kid's:

```bash
curl -s -X POST "https://YOUR-PROJECT.supabase.co/functions/v1/kid-login" -H "apikey: YOUR-ANON-KEY" -H "Authorization: Bearer YOUR-ANON-KEY" -H "Content-Type: application/json" -H "cf-connecting-ip: 203.0.113.77" -H "x-real-ip: 203.0.113.78" -H "X-Forwarded-For: 203.0.113.79" -d '{"username":"nobody_here","pin":"000000"}'
```

Then change the three numbers ending `.77`, `.78` and `.79` to `.87`, `.88` and `.89` and run it once more. In the SQL Editor: `select client from public.login_attempts where username = 'nobody_here' order by id;`. All three rows must show the **same** `client` (your computer's real address). If the last one differs, the platform passes a made-up address through, and a stranger could dodge the per-device lock (the 20-a-day lock still holds): stop and ask before going further. Then clean up with `delete from public.login_attempts where username = 'nobody_here';`.

### 14. ✋ The first few nights

The next few evenings after 4:30 pm Alberta time, in the SQL Editor:

1. `select fund_id, max(price_date) from public.fund_prices group by 1;` shows today's date for each fund (on a day its market traded).
2. `select call_date, kind, symbol, ok, note from public.price_calls order by id desc limit 10;` shows how the price calls went.
3. The parent Dashboard shows no alerts, and the next morning's **Health check** run is green.

Stage 4 is done when production has a few nights of real closes for DIA, QQQ and XIC.

## How the nightly run works

- From 4:00 to 10:30 pm Alberta time, every 30 minutes, the database's timer (pg_cron) wakes up. Before 4:30 pm it does nothing. From 4:30 pm, until tonight's work is finished, it calls the **nightly** Edge Function, which:
  1. fetches each fund's missing closes (one Alpha Vantage call per fund covers every missing day; at most 20 calls a day);
  2. once a week, checks each fund for splits;
  3. runs the daily jobs through today, catching up any missed days;
  4. reconciles every day not yet checked.
- A close is never guessed. If one isn't published yet, the next wake-up tries again. Trades and dividends for that fund wait; savings interest and GICs carry on.
- At 9:00 pm, a close that still hasn't come raises an alert (one per fund and day), which the next morning's health check reports.
- Every morning at 8:00 am Alberta time, **Health check** asks production how it is. Any open alert, a job falling behind, or a database past about 400 MB fails the run, and GitHub emails you. It's also the keep-alive: a Free project with no activity for a week pauses.

## A close is missing

The Dashboard shows "There's still no Dow Jones close for …", and the morning's Health check failed.

1. Wait for the next evening first: the provider is sometimes late, and the run tries every 30 minutes until 10:30 pm, then again from 4:30 pm the next day. When the close arrives, its alert settles by itself.
2. If it's still missing, look at the calls in the SQL Editor: `select call_date, kind, symbol, ok, note from public.price_calls order by id desc limit 20;`
   - **"Today's 20 price calls are used up"**: wait for the next day.
   - **"Our standard API rate limit…" or "Thank you for using Alpha Vantage"**: the free key's limit; it carries on the next day.
   - **"Invalid API call"**: the key or the symbol is wrong. Check `ALPHAVANTAGE_API_KEY` (**Edge Functions** → **Secrets**), then stop and ask.
   - **No rows at all for today**: the timer isn't calling the function. Check step 6.4 and step 7, then stop and ask.
3. **The market really was closed that day** (a day of mourning, an outage): the screen for recording a closure isn't built yet (later in Stage 4). Stop and ask.
4. Never type a close in yourself from memory or another site's rounded number. A wrong close is fixed only with the exchange's real number, through the fix-a-close screen (later in Stage 4).

## The project paused

GitHub emails you that **Health check** failed with "Production didn't answer. It may be paused". The app doesn't load data either.

1. Supabase Dashboard → open the project. A paused project shows **Restore project**: click it and wait until it's ready (a few minutes).
2. Repo → **Actions** → **Health check** → **Run workflow**: it must be green (or list only jobs catching up).
3. Nothing is lost: the next evening's run catches up every missed day in order, with interest for each day. Missed closes come in too, as long as the pause was shorter than about 4 months.

Restore it soon: Supabase may not let a Free project be restored after a long pause (90 days, as of 2026-10). If it happens again without a reason, stop and ask: the health check is the keep-alive, so it may have stopped running (GitHub turns off a repo's schedules after 60 days without commits; Stage 5 moves it to the backup repo, which gets a commit every day).

## The database is getting big

The Dashboard shows "The database is … MB of the free plan's 500 MB", and the morning's Health check failed.

1. In the SQL Editor, see what's big:

```sql
select n.nspname || '.' || c.relname as tbl, pg_size_pretty(pg_total_relation_size(c.oid)) as size
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'r' order by pg_total_relation_size(c.oid) desc limit 10;
```

2. If the top one is `cron.job_run_details` (the timer's own log), clear its old rows: `delete from cron.job_run_details where end_time < now() - interval '30 days';` That's the only thing you may delete. **Never delete anything in `public`**: that's the girls' money history.
3. On the Dashboard, **Acknowledge** the alert. If the database is still over 400 MB, the alert comes back the next morning: stop and ask (the choice between cleaning up and a paid plan is yours).

## A girl forgot her PIN

**In the app (normal way):**

1. Sign in as yourself (with the authenticator code).
2. **Settings** → **Logins** → **Reset {name}'s PIN** → read the note → **Reset {name}'s PIN** again.
3. A 6-digit code appears, shown only this once. Give it to her (it works for 7 days).
4. On her device she types her username, then the code where her PIN goes. She chooses a new PIN and types it again. Done.

Her old PIN stops working straight away, she is signed out on every device (straight away, even a device that was in the middle of something), and any lockout from her wrong guesses is lifted. She gets a notice. If the code is lost or runs out (Settings → Logins says so), reset again.

**With the setup script, on your computer's local copy:** `npm run setup-account` → `pin` sets a PIN in the **local** database (the demo and testing). It refuses anything but your own computer.

```bash
npm run setup-account
```

Type `pin`, her username, then her new PIN twice. Like a reset in the app, it signs her out everywhere and lifts any lockout.

**With the setup script, on production (only if the app can't be used):** `npm run setup-account:prod -- --production` → `pin`. It isn't logged in the parent log and sends her no notice, so prefer the app.

## The login key was lost

Each girl's Supabase password is worked out from her PIN with a key kept in Supabase Vault. If that key is ever lost (for example after restoring a backup into a new Supabase project, where Vault can't read the old key), no girl can sign in until her PIN is reset.

1. In the Supabase Dashboard, **SQL Editor** → **New query**, run `select public.new_kid_login_key();`. It answers that a new key is in place.
2. Reset each girl's PIN (above, "In the app").

(The nightly function's key is in Vault too: after a restore into a new project, redo production setup step 7.)

## Commit emails (each computer you commit from, once)

The repo is public, so commits must use your GitHub noreply address. CI fails on any other, and two hooks check before anything leaves your computer.

1. Find your noreply address: on GitHub, your picture → **Settings** → **Emails**. It looks like `<id>+<username>@users.noreply.github.com`.
2. In a terminal in the project folder, run (with your address in place of the example):

```bash
git config user.email "12345678+example-user@users.noreply.github.com"
```

3. Turn on the checks that run before every commit and every push:

```bash
git config core.hooksPath .githooks
```

Both are already set on this computer (2026-10-08).
