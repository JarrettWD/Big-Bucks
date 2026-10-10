# Big Bucks — Runbook

Step-by-step jobs for Dad. Stage 4 adds the full production setup (linking the project, pushing migrations, secrets, sign-up and MFA settings, the cron job, `check_time_rules()`). This first part holds the safety steps that came out of the pre-launch audit (2026-10-08).

## Never do these

- **Never run `supabase db reset --linked`.** It wipes the production database completely: every girl's money history. Only ever run `supabase db reset` without `--linked` (that's your own computer).
- **Never run `supabase db push --include-seed`.** The seed is for your computer only. (If you ever did, it refuses on a production database that has been marked, below.)
- **Never point `npm run timemachine`, `npm run demo` or `npm run jobs:local` at production.** They already refuse anything but your own computer, and refuse a database marked as production.

## Right after the first migration push to production

1. In the Supabase Dashboard, open your project, then **SQL Editor** → **New query**.
2. Paste `select public.mark_production();` and click **Run**. It should answer "Marked as production: the time machine is off for good." Running it again is harmless ("Already marked as production.").
3. In the same editor, run `select * from public.check_time_rules();`. Every row must show `ok = true`, except the one information-only row (ok empty). The row "Marked as production …" must say `yes`. Any `ok = false` row means stop and ask before going further.

## Production settings to match your computer's

These live in the Supabase Dashboard, not in the repo:

1. **Max rows:** **Project Settings** → **Data API** → **Max rows** → set it to **20000**, then **Save**. (The default 1,000 would cut off the graphs' longest ranges.)
2. **Secure password change:** **Authentication** → **Sign In / Providers** (or **Providers** → **Email**) → turn on **Secure password change**, then **Save**. (Kids can't change theirs at all; the database refuses it. This covers your own login too.)

## Commit emails (your computer, once)

The repo is public, so commits must use your GitHub noreply address. CI fails on any other.

1. In a terminal in the project folder, run:

```bash
git config user.email "320070380+JarrettWD@users.noreply.github.com"
```

2. Then turn on the check that runs before every commit:

```bash
git config core.hooksPath .githooks
```

Both are already set on this computer (2026-10-08). Do them again on any other computer you commit from.
