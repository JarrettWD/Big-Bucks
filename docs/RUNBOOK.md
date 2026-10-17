# Big Bucks — Runbook

Step-by-step jobs for Dad: setting up production (Stage 4) and the backups (Stage 5), and what to do when something goes wrong. Menu names are as of 2026-10; if Supabase or GitHub has moved one, the setting has the same name.

## Never do these

- **Never run `supabase db reset --linked`.** It wipes the production database completely: every girl's money history. Only ever run `supabase db reset` without `--linked` (that's your own computer).
- **Never run `supabase db push --include-seed`.** The seed is for your computer only. (On a production database that has been marked, below, it refuses anyway.)
- **Never point `npm run timemachine`, `npm run demo` or `npm run jobs:local` at production.** They already refuse anything but your own computer, and refuse a database marked as production.
- **Never make the big-bucks-backups repo public.** It holds the girls' names, the ledger and the logins.
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

   It asks for the project ref twice, then the service role key (**Project Settings** → **API Keys** → **service_role** or **secret**: **copy it, then just press Enter** at the prompt and the script reads it from the clipboard, never shows it, and clears the clipboard; pasting also works), then the same questions as the local script. For your password, the same works: copy it from your password manager and press Enter (then it isn't asked twice). Run it once for `parent`, once for a test `kid`. The girls' real accounts wait for the Stage 12 audit; the script asks you to type "real" before making a real kid.
3. ✋ On your phone, open `https://jarrettwd.github.io/Big-Bucks/` in Chrome → menu (⋮) → **Add to Home screen** → **Install**.
4. ✋ Sign in as yourself: the first sign-in sets up the authenticator app.

### 11. ✋ Check the alerts reach you

1. The **big-bucks-backups** repo (since Stage 5; it was the Big-Bucks repo before) → **Actions** → **Health check** → **Run workflow** → tick **Send test alert** → **Run workflow**.
2. It fails on purpose ("Test alert from Big Bucks…"). Within a few minutes GitHub emails you about the failed run. If no email comes, check step 8.4.
3. In the app, the parent **Dashboard** shows "Test alert from the daily health check…". Tap **Acknowledge**.
4. Run the workflow once more without the tick: it must be green. (If it's red, the message says why. Right after setup, "the … job has only finished through …" is normal until the first nightly run; check again the next morning.)

### 12. ✋ Which address the login sees

After the kid-login function is deployed, sign in as the test kid once, then in the SQL Editor run `select client, attempted_at from public.login_attempts order by id desc limit 3;`. Sign in again from your phone on mobile data (not Wi-Fi): the `client` value must change. If it stays the same, the device lockout can't tell devices apart; stop and ask.

### 13. ✋ A caller can't choose his own device address

The forged-header test (third audit). On your computer, in a terminal in the project folder, run this twice, with your project's address and its anon key (**Project Settings** → **API Keys**) in place of the two placeholders, and a username that isn't a kid's:

```bash
curl -s -X POST "https://YOUR-PROJECT.supabase.co/functions/v1/kid-login" -H "apikey: YOUR-ANON-KEY" -H "Authorization: Bearer YOUR-ANON-KEY" -H "Content-Type: application/json" -H "x-real-ip: 203.0.113.78" -H "X-Forwarded-For: 203.0.113.79" -d '{"username":"nobody_here","pin":"000000"}'
```

Then change the two numbers ending `.78` and `.79` to `.88` and `.89` and run it once more. Each answer should be `{"error":"wrong",…}`, with `tries_left` going down by one each time. (Don't add a `cf-connecting-ip` header: Supabase's front door, Cloudflare, refuses any request that fakes it, with "error code: 1000", which is good, but then the call never reaches the login. Checked on production 2026-10-10.) In PowerShell, type `curl.exe`, not `curl`. In the SQL Editor: `select client from public.login_attempts where username = 'nobody_here' order by id;`. All three rows must show the **same** `client` (your computer's real address). If the last one differs, the platform passes a made-up address through, and a stranger could dodge the per-device lock (the 20-a-day lock still holds): stop and ask before going further. Then clean up with `delete from public.login_attempts where username = 'nobody_here';`.

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
  4. reconciles every day not yet checked;
  5. last, in its own call, checks badges (stage 10). It never touches money, and its failure never stops or changes steps 1 to 4.
- A close is never guessed. If one isn't published yet, the next wake-up tries again. Trades and dividends for that fund wait; savings interest and GICs carry on.
- At 9:00 pm, a close that still hasn't come raises an alert (one per fund and day), which the next morning's health check reports.
- Every morning, once the backup is in (about 7:15 am Alberta time, see "The daily backup"), **Health check** (in the private big-bucks-backups repo) asks production how it is. Any open alert, a job falling behind, or a database past about 400 MB fails the run, and GitHub emails you. It's also the keep-alive: a Free project with no activity for a week pauses.

## A badge alert ("Badges couldn't be checked for …")

- **No money is affected.** Badges only read the history; the money jobs and reconcile finished before the badge check started. This alert is on the Dashboard only and never turns the health check red.
- The next evening's run tries again by itself. When it works, the alert settles and the badge arrives, dated the day she earned it.
- If it's still there after two evenings, **stop and ask** (copy the alert's words). Don't change anything in the SQL Editor.

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
2. The **big-bucks-backups** repo → **Actions** → **Health check** → **Run workflow**: it must be green (or list only jobs catching up).
3. Nothing is lost: the next evening's run catches up every missed day in order, with interest for each day. Missed closes come in too, as long as the pause was shorter than about 4 months.

Restore it soon: Supabase may not let a Free project be restored after a long pause (90 days, as of 2026-10). If it happens again without a reason, stop and ask: the health check is the keep-alive, so it may have stopped running (it runs in the private big-bucks-backups repo, whose daily backup commit keeps its schedule switched on: check that repo's **Actions** tab).

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

(After a restore into a new project, `select * from public.after_restore();` makes the new key for you and says what's left: the PIN resets, and production setup step 7 for the nightly function's key, which is in Vault too. See "Rebuilding production from a backup".)

## Backup setup (Stage 5)

Do these in order, once Claude's Part A is approved. ✋ means you do it by hand. Claude runs nothing on production without your OK for that step. Have your password manager open.

### 1. ✋ Create the private backup repo

1. On GitHub, **+** (top right) → **New repository**.
2. **Owner**: you. **Repository name**: `big-bucks-backups`. Choose **Private**.
3. Leave **Add a README file** unticked (Claude pushes the first files), then **Create repository**.

It must stay private for good: it will hold the girls' names, the ledger and the logins. Two-factor sign-in on your GitHub account (on since 2026-10-10) protects it.

### 2. Push the database change and two functions

With your OK, Claude runs these and shows you the output of each:

1. `npx supabase db push --dry-run`: it must list only `20261023000000_backups.sql`;
2. `npx supabase db push`;
3. `npx supabase functions deploy download-backup health`.

### 3. ✋ The backup login's password (SQL Editor)

1. Supabase Dashboard → **SQL Editor** → **New query**.
2. Run `select public.set_backup_login();`.
3. It answers with a long password, shown only this once. Save it in your password manager as "Big Bucks backup_reader".

This login can read every table and change nothing (it can only record its own backup). Running this again makes a new password; then redo step 4 and the secret in step 5.

### 4. ✋ The connection string

1. Supabase Dashboard → **Connect** (the button at the top) → **Connection String**.
2. **Type**: URI. **Method**: **Session pooler**. Copy the string. It looks like `postgresql://postgres.<project ref>:[YOUR-PASSWORD]@aws-1-ca-central-1.pooler.supabase.com:5432/postgres`.
3. In your password manager (never in a chat, a file or a note), make the backup's string from it:
   1. change `postgres.` at the start to `backup_reader.`;
   2. replace `[YOUR-PASSWORD]`, brackets included, with the password from step 3.
4. Save it there as "Big Bucks SUPABASE_DB_URL".

The backup refuses any string that isn't `backup_reader` through the session pooler.

5. ✋ **Supabase's certificate** (public, not a secret): Supabase Dashboard → **Database** → **Settings** → **SSL Configuration** → **Download certificate**. Your browser saves it in **Downloads** (a name like `prod-ca-2021.crt`). Tell Claude when it's there: in step 6 Claude checks it and puts it in the backup repo as `supabase-ca.crt`. Every backup connection then checks the database's certificate and name against it (`verify-full`), so nothing can pose as the database. (If the menu has moved, the setting is still called **SSL Configuration**.)

### 5. ✋ The backup repo's secrets and variables

1. The `big-bucks-backups` repo → **Settings** → **Secrets and variables** → **Actions**.
2. **Secrets** tab → **New repository secret**, once for each:
   1. `SUPABASE_DB_URL`: the string from step 4.
   2. `HEALTH_CHECK_KEY`: the same key as the Big-Bucks repo's (from your password manager).
3. **Variables** tab → **New repository variable**, once for each:
   1. `SUPABASE_URL`: `https://<project ref>.supabase.co`, the same as Big-Bucks' `VITE_SUPABASE_URL`.
   2. `SUPABASE_ANON_KEY`: the anon key, the same as Big-Bucks' `VITE_SUPABASE_ANON_KEY`.

### 6. The workflows go in

With your OK, Claude clones the empty repo to `C:\BigBucksBackup\big-bucks-backups`, copies in everything from `ops/backup-repo/` (the two workflows, the scripts, `.gitattributes`, the README) and Supabase's certificate from step 4 as `supabase-ca.crt` (also kept in Big-Bucks under `ops/backup-repo/`), commits as you, and pushes. GitHub emails a schedule's failures to whoever last changed its workflow file, so it must be committed as you.

### 7. ✋ The first backup

1. The `big-bucks-backups` repo → **Actions** → **Backup** → **Run workflow** → **Run workflow**.
2. It takes about 2 minutes. When it's green, **Code** shows a commit like "Backup 2026-10-15: 34 tables, … rows, … ledger rows", and a `backup` folder.
3. If it's red, the message says why. "password authentication failed" or "Tenant or user not found" means the connection string (step 4); "certificate verify failed" or "self-signed certificate" means the certificate (step 4.5). Check it; if it still fails, stop and ask. Don't switch the login to `postgres`.

### 8. ✋ The health check from its new home

1. The `big-bucks-backups` repo → **Actions** → **Health check** → **Run workflow** → tick **Send test alert** → **Run workflow**. It fails on purpose, GitHub emails you, and the Dashboard shows the test alert: **Acknowledge** it.
2. Run it again without the tick: it must be green.
3. With your OK, Claude then removes `health-check.yml` from the Big-Bucks repo, so it runs in one place only. (Done 2026-10-10.)

### 9. ✋ The copy on your computer (OneDrive)

1. **Two copies, on purpose.** The script lives in the big-bucks-backups repo, at `scripts\sync-backup.ps1`, so your clone (`C:\BigBucksBackup\big-bucks-backups`, made in step 6) always has the newest one. That copy only waits for your review. Task Scheduler runs the **installed** copy, `C:\BigBucksBackup\sync-backup.ps1`, which changes only when you install a new one. So nothing that arrives with a pull ever runs on your computer by itself (Guard 1, 2026-10-10). The installed copy refuses to run from inside the clone.
2. **Install it, or a newer version** (after reviewing it on GitHub: big-bucks-backups → `scripts/sync-backup.ps1` → **History** → the newest commit). In Windows PowerShell:

```bash
Copy-Item C:\BigBucksBackup\big-bucks-backups\scripts\sync-backup.ps1 C:\BigBucksBackup\sync-backup.ps1 -Force
```

   Claude tells you explicitly whenever the script changes and needs your review and install. If you forget, the next run says so (below).
3. Run it once in a terminal:

```bash
powershell -ExecutionPolicy Bypass -File C:\BigBucksBackup\sync-backup.ps1
```

   It answers "Synced … Newest backup: … Script: installed copy matches the repo's (<commit> of <date>)." In OneDrive, the folder **Big Bucks backup** now has `latest` (the newest backup's files), `big-bucks-history.bundle` (every day's backup in one file) and `last-sync.txt`.
4. Schedule it daily:
   1. **Start** → type **Task Scheduler** → open it.
   2. On the right, **Create Basic Task…**. **Name**: `Big Bucks backup copy` → **Next**.
   3. **Daily** → **Next**. **Start**: tomorrow at **9:30:00 AM**, **Recur every: 1 days** → **Next**.
   4. **Start a program** → **Next**. **Program/script**: `powershell.exe`. **Add arguments (optional)**: `-NoProfile -ExecutionPolicy Bypass -File C:\BigBucksBackup\sync-backup.ps1` → **Next**.
   5. Tick **Open the Properties dialog for this task when I click Finish** → **Finish**.
   6. In Properties: on the **General** tab, leave **Run only when user is logged on** selected (that's what lets the pop-up appear). On the **Settings** tab, tick **Run task as soon as possible after a scheduled start is missed**. On the **Conditions** tab, untick **Start the task only if the computer is on AC power**. → **OK**.
5. To test it: in the Task Scheduler Library list, right-click **Big Bucks backup copy** → **Run**, then open `last-sync.txt` in OneDrive. **Last Run Result** should say "The operation completed successfully. (0x0)".

**When it needs a look,** a Windows pop-up titled **Big Bucks backup copy** says what's wrong and points to `last-sync.txt`. It closes by itself after 12 hours. When all is well there's no pop-up. It pops up for:
- **"A newer sync script is in the repo … NOT been installed":** review it, then install it (item 2). It still synced.
- **"The newest backup is … hours old … more than 30":** see "A backup failed". A morning GitHub skipped shows here the next morning.
- **"The backup copy on this computer failed: …":** the reason follows. If it isn't clear, send it to Claude.

### 10. ✋ The first restore drill

In a terminal in the Big-Bucks folder, with Docker Desktop running:

```bash
npm run restore:drill -- C:\BigBucksBackup\big-bucks-backups\backup
```

It must end with **RESTORE DRILL: PASS**, every table and every account matching. That ticks the ACCEPTANCE box "One backup has been restored into the local copy of Supabase, with balances matching".

### 11. ✋ Download backup on your phone

In the app, signed in as yourself: **Settings** → **Backup** → **Download backup**. It says "Saved big-bucks-backup-….zip". Open the zip from your Downloads: it has a `csv` folder and a `json` folder, with every table in each.

## The daily backup

- **Every morning (the morning start, since Oct 2026):** production's own timer starts the **Backup** at 7:00 am Alberta time, then the **Health check** once that backup is recorded (normally 7:15 am), or at 9:00 am if it never is. In the repo's **Actions** list they show as run by "workflow_dispatch". Both run in the private `big-bucks-backups` repo. Alberta is UTC−6 all year, so the times never shift.
- **GitHub's own schedule is the backstop:** Backup at 18:37 UTC (12:37 pm) and Health check at 19:07 UTC (1:07 pm), shown as "Scheduled". GitHub often starts them hours late; that's fine. A backstop Backup stops early (green, with only the **fresh** job run) when this morning's backup is already committed. Why: on Oct 11, 2026 GitHub's schedule didn't fire at all, and on Oct 12 it fired 8 hours late.
- **What a backup holds:** everything, from one moment. Every table and row, the logins (not sessions), each table as CSV, and every account's balances worked out by the database. It's all in `backup/` in that repo; its README lists the files.
- **Git keeps every day's version.** To see an old day: **Code** → **History** (the clock icon) → that day's commit → **Browse files**.
- **When it fails on purpose:** the export is empty, or the ledger (or any other permanent table) has fewer rows than the day before. Yesterday's backup is then left as it was, and GitHub emails you.
- **Watched from two places, not only GitHub:**
  - **The database's own timer** (every evening from 4:30 pm) raises a Dashboard alert when no backup has been recorded for 36 hours, and another when no health check has run for 36 hours. A morning GitHub skips shows on the Dashboard that evening, around 9:00 pm. The next health check that does run then fails, and GitHub emails you.
  - **Your computer's 9:30 am sync** pops up when the newest backup is more than 30 hours old.
- **A second copy on your computer:** Task Scheduler copies it into OneDrive each morning (setup step 9).

## A backup failed

GitHub emailed you that **Backup** failed, the Dashboard says "The daily backup hasn't succeeded since …", or your computer popped up "The newest backup is … hours old".

1. The `big-bucks-backups` repo → **Actions** → **Backup**.
   - **No run at all that morning** (no "workflow_dispatch" run around 7:00 am): the morning start didn't happen. Click **Run workflow** → **Run workflow** to take today's backup now. Then look at the Dashboard for "GitHub refused this morning's start…" (see "The morning start failed"). If neither explains it, stop and ask.
   - **A red run:** open it. The red step's message says why:
     - **"Production didn't answer the ping"**: see "The project paused".
     - **"… has fewer rows than in the last backup … stop and ask"**: rows went missing from a table that can never lose any. Don't run anything else. Stop and ask.
     - **"The export is empty"**: stop and ask.
     - **"password authentication failed"**: the password changed. Redo setup steps 3 to 5 (a new password, a new string, the secret).
     - Anything else, such as a GitHub hiccup: **Re-run all jobs**.
2. When a run is green, the Dashboard alert settles by itself.

## The health check didn't run

The Dashboard says "The daily health check hasn't run since …". It's started every morning after the backup (see "The daily backup") in the big-bucks-backups repo, and it's also the Free plan's keep-alive.

1. The `big-bucks-backups` repo → **Actions** → **Health check**.
   - **No run that morning:** it wasn't started. Click **Run workflow** (leave **Send test alert** unticked) → **Run workflow**. Then see "The morning start failed". If it happens again, stop and ask.
   - **A red run:** its message says why (see "The project paused" for "Production didn't answer").
2. When a health check runs, the Dashboard alert settles by itself.

## The morning start

Production's own timer starts the Backup and the Health check each morning through GitHub's API. It needs a GitHub token that can only start workflows in big-bucks-backups. Set it up once, after the database change is live (Claude tells you when). Never between 7:00 and 11:45 am.

1. ✋ GitHub: your profile photo (top right) → **Settings** → **Developer settings** (bottom of the left list) → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
2. **Token name:** `big-bucks-morning-start`. **Description:** "Production starts the Backup and Health check each morning." **Resource owner:** you.
3. **Expiration:** **Custom**, then a weekday about a year out (GitHub allows up to 366 days). Write the date down.
4. **Repository access:** **Only select repositories** → pick `big-bucks-backups`. Nothing else.
5. **Permissions** → **Repository permissions** → **Actions**: **Read and write**. Leave everything else at **No access**. GitHub adds **Metadata: Read-only** by itself; that's expected.
6. **Generate token**, then copy it (GitHub shows it only once). Don't paste it anywhere else.
7. ✋ Supabase, production project → **Integrations** → **Vault** → **Secrets** → **Add new secret**. **Name:** `github_dispatch_token`. **Secret:** paste the token. **Description:** "Starts the morning backup (expires <date>)". Save. Use this screen, never the SQL Editor: the SQL Editor keeps a history of what you type.
8. ✋ Supabase → **SQL Editor**, with your username and the date from step 3:
   `select public.set_github_dispatch('<your GitHub username>/big-bucks-backups', date '<YYYY-MM-DD>');`
   It answers "Saved: …, token expires …. The token is in Vault too: the first start is at 7:00 am."
9. The next morning, check the runs (Claude gives you the exact list).

**If the token leaks**, someone could start, cancel or re-run big-bucks-backups' workflows, delete their logs, turn them off, or download the day's backup artifact (kept 1 day). They couldn't read or change the repo's files or secrets, or touch Big-Bucks. Revoke it (GitHub → the same **Fine-grained tokens** page → the token → **Delete**), then make a new one.

## The morning start failed

The Dashboard says "GitHub refused this morning's start of the …" or "GitHub didn't start this morning's …". GitHub's own schedule still backs up later the same day (the backstop), so no day is lost. Its Health check fails while this alert is open, so GitHub emails you too.

1. **"(401)" or "(403)": the token has expired or been revoked.** Make a new one: "Renew the GitHub token".
2. **"(404)":** GitHub can't find the repo or workflow. Check the repo name you gave `set_github_dispatch` (step 8 of "The morning start") and that the token still lists `big-bucks-backups`.
3. **"(no answer)" or another number:** usually a GitHub hiccup. If tomorrow's start works, the alert settles by itself. If it happens twice in a row, stop and ask.
4. The next start GitHub accepts settles the alert by itself. To start today's backup now: big-bucks-backups → **Actions** → **Backup** → **Run workflow**.

## Renew the GitHub token

The Dashboard says "The GitHub token that starts the morning backup expires on …" (21 days ahead), or the morning start failed with 401.

1. Do steps 1 to 8 of "The morning start": a new token (same settings), pasted into the existing Vault secret `github_dispatch_token` (**Integrations** → **Vault** → the secret → **Edit**), then `set_github_dispatch` with the new expiry date. The reminder settles when the new date is saved.
2. On GitHub's **Fine-grained tokens** page, delete the old token.
3. Update your calendar reminder for the new date.

## Restore drill (every few months)

This proves a backup really rebuilds Big Bucks, without touching the live app. It reads only the backup's files and builds a throwaway copy on your computer, separate from your normal local copy.

1. Bring your clone up to date: run `C:\BigBucksBackup\sync-backup.ps1`, or wait for its morning run.
2. Start Docker Desktop.
3. In a terminal in the Big-Bucks folder:

```bash
npm run restore:drill -- C:\BigBucksBackup\big-bucks-backups\backup
```

4. It restores the backup and puts back what a dump leaves out (`after_restore()`). Then it compares every table (rows, and every row's contents), the logins, and each account's savings, GICs, and fund units and cost with what the backup recorded when it was taken. Each line says **PASS** or **FAIL**, and the last says **RESTORE DRILL: PASS** or **FAIL**. Then it removes the throwaway copy.
5. Any **FAIL**: stop and ask.

To practise without production: `npm run backup:local` backs up your local copy the same way, then run `npm run restore:drill -- .local-backup/backup`. Adding `--tamper` changes one ledger row by a cent after the restore, to show the drill notices (it must FAIL).

## Rebuilding production from a backup

Only if the production project is lost for good (deleted, or a pause that can't be restored). Stop and ask before starting: Claude walks through it with you. The outline:

1. ✋ A new Supabase project (production setup steps 1 to 4). The Free plan allows two and the food inventory app uses the other, so the lost one must be gone first.
2. Claude, with your OK, loads the newest backup into it with `psql`, with the same files in the same order as the drill (its prelude, `schema.sql`, `auth.sql`, `data.sql`, then the wish list photos from `csv/public.wishlist_photos.csv` with psql's `\copy`, since Stage 9 keeps them out of `data.sql`). Not `db push`: the schema comes from the backup.
3. ✋ SQL Editor: `select * from public.after_restore();`. It puts back the login guard and the nightly and morning timers and makes a new login key. Then `select public.mark_production();` (harmless if already marked) and `select * from public.check_time_rules();` (production setup step 6).
4. ✋ **Reset each girl's PIN** (Settings → Logins): Vault's old login key can't be read in a new project, so no old PIN works.
5. ✋ Production setup step 7 (the nightly address and key in Vault) and step 4 (the function secrets). Then "The morning start", steps 7 and 8 (Vault can't be read in a new project, so the token goes in again; a new one if the old one is lost).
6. Deploy the functions, then update the URL and anon key in both repos' variables (Big-Bucks and big-bucks-backups) and the connection string (backup setup steps 3 to 5). Then deploy the app.
7. Everyone signs in again (sessions aren't in the backup). Your authenticator app still works: its setup is in the backup.

## The pre-launch reset (Stage 12)

Just before the girls start, this clears the beta's history: every transaction, GIC, request, notice, question, wish list item, signature, alert and login attempt. It keeps every account (the test kid too), every login, and all configuration: rates, settings, cancelled changes, the glossary, notes, holidays, funds, prices and the parent log. Every balance becomes $0.00, and each account signs its agreement and does onboarding again.

1. The `big-bucks-backups` repo → **Actions** → **Backup** → **Run workflow**. Wait until it's green.
2. Within 2 hours: Supabase Dashboard → **SQL Editor** → **New query**:

```sql
select public.prelaunch_reset('clear the test history');
```

3. It answers "Test history cleared: … rows from 16 tables …". It refuses, and changes nothing, if there's no backup from the last 2 hours, if anything changed since that backup, or if `launched_at` is set (then it can never run again).
4. The next morning's backup is allowed to be smaller, once, and says "(after the pre-launch reset)" in its commit message.

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
