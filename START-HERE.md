# Start here: building Big Bucks with Claude Code

This kit turns the Big Bucks framework into something Claude Code can build, one stage at a time. You don't write code; you paste a prompt, approve the plan Claude Code proposes, and check the result.

## What's in the kit

| File | What it's for |
|---|---|
| `CLAUDE.md` | Standing rules Claude Code reads automatically in every session: the stack, the money rules, security, and how to work |
| `docs/SPEC.md` | The framework, as the build spec, plus a Build decisions section that settles the details a builder needs |
| `docs/BUILD-PLAN.md` | The 13 stage prompts to paste, in order, plus prompts for resuming and fixing bugs |
| `docs/ACCEPTANCE.md` | The version 1 checklist the finished app must pass |
| `docs/PROGRESS.md` | Claude Code's log of what each stage delivered |
| `public/icons/` | The Big Bucks icon at every size the app needs |

The kit contains no names, usernames, PINs or emails. The girls' real accounts are created later by a setup script on your computer, so the app repo can be public if you like.

## One-time setup (about an hour)

1. **Install on your computer:** Node.js (the LTS version), Git, Docker Desktop and the Supabase CLI. Run Claude Code on your computer, not in the cloud, because the local test copy of Supabase needs Docker.
2. **Create a GitHub repo** called `big-bucks`. Use the same visibility as your food inventory app: GitHub Pages from a private repo needs a paid GitHub plan, and a public repo is fine because the kit holds nothing personal.
3. **Copy the kit into the repo:** unzip it into the repo folder so `CLAUDE.md` sits at the top level, then commit and push.
4. **Check your Supabase slot:** the free plan allows two active projects and the food app uses one. You'll create the Big Bucks project at stage 4, not before.

## Running the build

1. Open Claude Code in the `big-bucks` folder.
2. Paste the **Stage 0** prompt from `docs/BUILD-PLAN.md`.
3. Claude Code replies with a short plan. Read it, ask questions, and say "go" when it looks right.
4. When the stage ends, skim `docs/PROGRESS.md`, do any "Dad to do by hand" steps it lists, and ask Claude Code to commit and push.
5. Start a new session for the next stage and paste its prompt.

Stages 0–2 make a realistic first weekend. The money engine is proven by its tests before any screens exist, so don't worry if there's little to look at early on.

## Things you'll be asked for along the way

| Stage | What you'll need |
|---|---|
| 0 | The GitHub repo, and later a choice of price-data provider from Claude Code's comparison |
| 4 | A new Supabase project for Big Bucks, and the price-data API key, stored as a Supabase secret |
| 5 | A second, **private** GitHub repo for backups, such as `big-bucks-backups` |
| 6 | An authenticator app on your phone (such as Google Authenticator) for your parent login |

**Keep secrets out of the chat:** when Claude Code needs a key or password, it will tell you where to paste it (Supabase secrets or GitHub secrets). Never paste one into the conversation or a file in the repo.

## When the build is done

Phase 1 ends at stage 8, which is when your solo beta starts. Follow the Big Bucks — Beta Test Plan doc, logging bugs there and fixing them with the bug-fix prompt at the end of `docs/BUILD-PLAN.md`. Phase 2 (stages 9–11) is built while the beta runs, and stage 12 takes you through launch day.
