# Big Bucks — Runbook

Step-by-step jobs for Dad. Stage 4 fills in the rest of the production setup (linking the project, pushing migrations, secrets, the cron job). This first part holds the safety steps and checklist items that came out of the pre-launch audits (2026-10-08).

## Never do these

- **Never run `supabase db reset --linked`.** It wipes the production database completely: every girl's money history. Only ever run `supabase db reset` without `--linked` (that's your own computer).
- **Never run `supabase db push --include-seed`.** The seed is for your computer only. (On a production database that has been marked, below, it refuses anyway.)
- **Never point `npm run timemachine`, `npm run demo` or `npm run jobs:local` at production.** They already refuse anything but your own computer, and refuse a database marked as production.

## Stage 4 production setup checklist

Do these in order on the production project. Stage 4 adds the steps before and after them.

1. **Right after the first migration push, mark production:**
   1. In the Supabase Dashboard, open your project, then **SQL Editor** → **New query**.
   2. Paste `select public.mark_production();` and click **Run**. It answers "Marked as production: the time machine is off for good." Running it again is harmless.
2. **Check the time rules** in the same editor: `select * from public.check_time_rules();`. Every row must show `ok = true`, except the one information-only row (ok empty). The row "Marked as production …" must say `yes`. Any `ok = false` row means stop and ask before going further.
3. **Check the login key and the login guard exist** (the first push is the first time hosted Supabase runs them), in the same editor:
   1. `select count(*) from vault.secrets where name = 'kid_login_key';` must answer `1`.
   2. `select tgname from pg_trigger where tgname = 'protect_kid_login';` must answer one row.
   If either is missing, stop and ask.
4. **Max rows: 20,000.** **Project Settings** → **Data API** → **Max rows** → type **20000** → **Save**. The default 1,000 would cut off the graphs' longer ranges (Growth by option already passes 1,000 rows for one year with three options).
5. **Secure password change:** **Authentication** → **Providers** → **Email** → turn on **Secure password change** → **Save**. (Kids can't change theirs at all; the database refuses it. This covers your own login.)
6. **Which address the login sees:** after the kid-login function is deployed, sign in as a test kid once, then in the SQL Editor run `select client, attempted_at from public.login_attempts order by id desc limit 3;`. Sign in again from your phone on mobile data (not Wi-Fi): the `client` value must change. If it stays the same, the device lockout can't tell devices apart; stop and ask.

7. **A caller can't choose his own device address** (forged-header test, third audit). On your computer, in a terminal in the project folder, run this twice, with your project's address and its anon key (Dashboard → **Project Settings** → **API**) in place of the two placeholders, and a username that isn't a kid's:

```bash
curl -s -X POST "https://YOUR-PROJECT.supabase.co/functions/v1/kid-login" -H "apikey: YOUR-ANON-KEY" -H "Authorization: Bearer YOUR-ANON-KEY" -H "Content-Type: application/json" -H "cf-connecting-ip: 203.0.113.77" -H "x-real-ip: 203.0.113.78" -H "X-Forwarded-For: 203.0.113.79" -d '{"username":"nobody_here","pin":"000000"}'
```

   Then change the three numbers ending `.77`, `.78` and `.79` to `.87`, `.88` and `.89` and run it once more. In the SQL Editor: `select client from public.login_attempts where username = 'nobody_here' order by id;`. All three rows must show the **same** `client` (your computer's real address). If the last one differs, the platform passes a made-up address through, and a stranger could dodge the per-device lock (the 20-a-day lock still holds): stop and ask before going further. Then clean up with `delete from public.login_attempts where username = 'nobody_here';`.

(Menu names are as of 2026-10; if Supabase has moved one, the setting has the same name.)

## A girl forgot her PIN

**In the app (normal way):**

1. Sign in as yourself (with the authenticator code).
2. **Settings** → **Logins** → **Reset {name}'s PIN** → read the note → **Reset {name}'s PIN** again.
3. A 6-digit code appears, shown only this once. Give it to her (it works for 7 days).
4. On her device she types her username, then the code where her PIN goes. She chooses a new PIN and types it again. Done.

Her old PIN stops working straight away, she is signed out on every device (straight away, even a device that was in the middle of something), and any lockout from her wrong guesses is lifted. She gets a notice. If the code is lost or runs out (Settings → Logins says so), reset again.

**With the setup script: your computer's local copy only.** `npm run setup-account` → `pin` sets a PIN in the **local** database (the demo and testing), never production: it refuses anything but your own computer. On production, always use the app. (Stage 4 adds the production version of the setup script, for creating the real accounts; it will get the same PIN option.)

```bash
npm run setup-account
```

Type `pin`, her username, then her new PIN twice. Like a reset in the app, it signs her out everywhere and lifts any lockout.

## The login key was lost

Each girl's Supabase password is worked out from her PIN with a key kept in Supabase Vault. If that key is ever lost (for example after restoring a backup into a new Supabase project, where Vault can't read the old key), no girl can sign in until her PIN is reset.

1. In the Supabase Dashboard, **SQL Editor** → **New query**, run `select public.new_kid_login_key();`. It answers that a new key is in place.
2. Reset each girl's PIN (above, "In the app").

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
