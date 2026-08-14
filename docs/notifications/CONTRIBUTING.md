# How to contribute to notifications

For everyone working on Email Notifications or Mobile Notifications.

Read this once. It is short. Most of it is here because somebody already lost a
day to it.

This is not the `CONTRIBUTING.md` at the root of `doubtfire-api`. That one is
upstream Doubtfire's and it is not ours.

---

## The three rules that matter most

1. **Branch off `feature/notifications`. Open your pull request back into
   `feature/notifications`.** Never `11.0.x`. Never `development`.
2. **Paste your pull request link into your Planner ticket.** If you skip this,
   your work does not get counted. There is no automatic backup.
3. **If you are stuck for more than about an hour, say so.** Post where you got
   stuck. That is not failure, that is the job. Sitting silently stuck helps
   nobody and it costs you the ticket.

---

## Before you start a ticket

Tick the first checklist item on the ticket: **"Confirmed I have started. My
branch name is ______"** and fill in the branch name.

This is how we know a ticket is being worked on. If that box is empty, anyone
can take the ticket. Ten seconds of your time saves someone else duplicating
your work.

---

## Setting up, and the four things that go wrong

Full instructions are in `doubtfire-deploy/RUNNING-LOCALLY.md`. Read that first.
These are the failures that are not in it.

**You are probably pointed at the wrong remote.** Our work is in the
`ontrack-features-t2-2026` organisation. It is not on `thoth-tech` and it is not
on `doubtfire-lms`. If `git fetch` cannot find `feature/notifications`, this is
why.

```
git remote set-url origin https://github.com/ontrack-features-t2-2026/<repo>.git
git fetch origin
```

`doubtfire-api` and `doubtfire-web` sit on `feature/notifications`.
`doubtfire-deploy` sits on `11.0.x` and has no notifications branch.

**A push that fails with 403 is an access problem, not a git problem.** Being a
member of the organisation gives you read only. Write comes from the
`ontrack-contributors` team. Ask the lead and it takes one minute to fix.

**On Windows, do not put the database on a bind mount.** MariaDB cannot reliably
rename a table across the Windows host share and `db:populate` dies with
`Tablespace is missing for a table`. This is fixed on `11.0.x` in deploy, using a
named `db_data` volume. If you hand edited your compose file to work around it,
undo the edit and pull instead.

**The branch name your clone shows you can be a lie.** On macOS the filesystem
is case insensitive, so an inherited `Feature/` directory in `.git/refs` swallows
later lowercase `feature/*` refs and `git branch -a` will show you a capitalised
branch that does not exist on the server. Never read a branch name off
`git branch -a` for a pull request. Use `git ls-remote --heads origin`.

---

## Which repository

Every ticket says which repository it is in.

| Repo | What it is |
|---|---|
| `doubtfire-api` | The backend. Ruby on Rails |
| `doubtfire-web` | The frontend. Angular |
| `doubtfire-deploy` | Docker and configuration |

If your ticket says `none`, there is no code. You are writing a document and
attaching it to the ticket.

---

## Branches

Integration branch: **`feature/notifications`**

Your branch is named on the ticket. It looks like `email/task-comment` or
`push/opt-in`.

```
git checkout feature/notifications
git pull origin feature/notifications
git checkout -b email/task-comment
```

Do the work, then:

```
git add <the files you changed>
git commit -m "feat(notifications): email on new task comment"
git push -u origin email/task-comment
```

**Never create a branch underneath a name that is already a branch.** Git cannot
hold both a branch and a folder at the same path and it fails with
`cannot lock ref`. Concretely: no work branch may be named
`feature/notifications/<anything>`. Work branches live under `email/` and
`push/`, which can never collide with the integration branch.

---

## Commits

Format: `type(scope): short summary in the present tense`

```
feat(notifications): email on new task comment
fix(profile): stop resetting notification preferences on edit
docs(notifications): audit existing email send sites
test(notifications): cover preference gating
chore(deploy): add mail catcher to local dev stack
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`. Keep the summary under
about 50 characters. Use the scope `notifications` unless you are genuinely
touching something else. Every ticket has its commit message already written on
it, so you can copy it.

---

## Pull requests

Open it against **`feature/notifications`**. Double-check this. GitHub often
defaults to the wrong branch and it is the single most common mistake.
**Check the base repository, not just the branch name.** It must read
`ontrack-features-t2-2026/...`. If it reads `doubtfire-lms/...`, change it. The
upstream maintainer has a branch called `feature/notifications` too, two hops up
the fork network, so the branch name on its own no longer tells you where you
are pointing.

Your PR description must include:

```
Ticket: EN-E01

Built against:
  doubtfire-api    feature/notifications  <commit sha>
  doubtfire-web    feature/notifications  <commit sha>
  doubtfire-deploy 11.0.x                 <commit sha>

What this does:
  <two or three sentences>

How I tested it:
  <what you actually did, and what you saw>
```

**Reviewers are told to reject pull requests that leave out the built-against
block.** Get each sha with `git rev-parse --short HEAD` in that repository. Yes,
all three, even if you only touched one. It is how a reviewer reproduces what you
saw.

Keep pull requests small. Everything that merged last trimester was between
about 30 and 130 lines across fewer than ten files. Large pull requests stall,
and they stall for weeks rather than days.

---

## Review

How many approvals you need depends on what you touched.

**One approval** if your change only adds new files of your own plus a few lines
in a model. Most event tickets are this.

**Two approvals** if you touched any of:

- a database migration
- `db/schema.rb`
- `NotificationService` or `PushNotificationService`
- configuration, a manifest, or the Gemfile
- a file another open ticket is also touching

If you are not sure, ask. Guessing low wastes a reviewer's time. Guessing high
costs you nothing.

The lead merges. Do not merge your own pull request, and note that GitHub will
not let you approve it either.

**There is no CI.** Nothing on GitHub runs either test suite. No status check
will ever go green or red on your pull request, so a merge button that looks
happy tells you nothing about whether your code works. The human read is the
only gate we have. Put your real test output in the pull request body so a
reviewer has something to check rather than a promise.

**Two approvals is our rule, not GitHub's.** The ruleset enforces one. Do not
treat an available merge button as evidence the rule was met.

**If you stack your branch on somebody else's unmerged branch, the approval gate
quietly disappears.** Rulesets cover `feature/notifications`, not whatever branch
was cut yesterday. So a pull request targeting a teammate's branch can merge with
zero approvals. Stacking is sometimes the right thing to do, just tell the lead
when you do it, and retarget to `feature/notifications` once the branch below you
lands.

---

## Keeping up to date

Other people are merging into `feature/notifications` while you work. Before you
open your pull request:

```
git checkout feature/notifications
git pull origin feature/notifications
git checkout <your branch>
git merge feature/notifications
```

Fix any conflicts, then push. If a conflict looks frightening, **stop and ask.**
Do not force push. Do not delete files to make the conflict go away. Someone
will help you in five minutes.

---

## Two files that cause conflicts, and how we avoid them

**`db/schema.rb`.** This is rebuilt automatically every time anyone adds a
migration, and two branches with migrations will always conflict. Only a couple
of tickets have a migration and they are all held by the lead. **If your ticket
does not mention a migration and you find yourself writing one, stop and ask.**
You are probably solving the wrong problem.

**Event documentation.** Every event gets its own file at
`docs/notifications/events/<event_name>.md`. Never add to a shared list. If
everyone edited one file, every event ticket would conflict with every other one.

One more that is not a file. **Leave a newline at the end of every file you
touch.** Prettier enforces it on the web side, and a missing final newline turns
the last line of a shared file into a conflict against every other open pull
request.

---

## The one domain rule: notifications send inline

`NotificationService.notify` sends the email and the push **synchronously**, on
the request thread. There is no worker process running in the dev stack, which
is exactly why it works that way. `app/services/notification_service.rb` explains
the reasoning at the top of the file.

The consequence matters more than the mechanism. **Any event that can address a
whole cohort sends one email plus one push per person, inside a single web
request.** A group CSV import, a task definition added to a unit, a bulk marking
run. Every one of those is a timeout in production and a very long request in
development.

So before you wire an event to a hook, ask who it reaches when the hook fires in
the worst case, not the normal case. Three separate tickets have hit this
independently. If the answer is "everyone in the unit", stop and talk to the lead
before you build it. Batching is EN-F03 and it is not done yet.

Two related habits worth having:

- **Never notify somebody about their own action.** Check the actor against the
  recipient.
- **Look at every caller of the method you are hooking, not just the obvious
  one.** `add_member` looks like a student joining a group. It is also called by
  tutorial changes, enrolment deletion and CSV import.

---

## Documentation

All notification documentation lives in **one** place:
`doubtfire-api/docs/notifications/`. Do not start a new folder, and do not put it
in `doubtfire-web`.

Naming: lowercase, hyphenated, no dates in the filename, one file per subject.
`push-setup.md`, not `PushSetup_2026-08-14.md`.

| What you are writing | Where it goes |
|---|---|
| An event | `docs/notifications/events/<event_name>.md` |
| Anything else | `docs/notifications/<subject>.md` |

**For an event, copy `docs/notifications/events/_template.md` and fill in the
eight field table.** It is not optional formatting. The table is what lets
somebody read the recipient and the preference gate without opening the code,
and it is what the security review tickets read.

Worked examples to copy rather than invent:

- `docs/notifications/events/task_comment_created.md` — the model event doc
- `docs/notifications/events/_template.md` — the eight fields
- `docs/notifications/push-setup.md` — VAPID keys and payloads
- `docs/notifications/testing-push-locally.md` — read this before you try to
  test push on a phone

**Push does not work on a phone over your LAN address.** A phone on your wifi
hitting `http://192.168.x.x:4200` is not a secure context, so the browser hides
the push API entirely and the opt-in button greys out. `localhost` is fine
without HTTPS. A phone is not localhost. You need a tunnel, and
`testing-push-locally.md` has the commands. On iOS there is a second step, you
have to Add to Home Screen and open it from the icon.

If somebody asks you a question this page does not answer, the answer goes in
here, not just in a reply.

---

## Tests

Write them. Every code ticket has its tests in the steps.

- **API:** Minitest, in `test/`, mirroring the `app/` path. So a test for
  `app/models/task.rb` goes in `test/models/`. Run inside the container, never
  on your own machine.
- **Web:** vitest, in `<name>.spec.ts` beside the component.

Every Grape endpoint gets a test. Every new Angular component gets a `.spec.ts`.

The `.rspec` file at the root of the api repository is **dead configuration.**
Ignore it. This project does not use RSpec, and the handover document that says
it does is a trimester out of date. The same document says Angular 17 and Karma.
It is Angular 22 and vitest.

Development mail is written to files, not sent. It lands in
`doubtfire-deploy/data/tmp/mails/`, **not** `doubtfire-api/tmp/mails` as the
comment in `config/environments/development.rb` claims. The container mounts
`../data/tmp` over `/doubtfire/tmp`, so the comment is wrong under Docker. Mailpit
on port 8025 is the easier way to look at them.

---

## Where things live

| What | Where |
|---|---|
| Tickets | Microsoft Planner |
| Code | GitHub, `ontrack-features-t2-2026` |
| Evidence and documents | Attached to your Planner ticket |
| Notification documentation | `doubtfire-api/docs/notifications/` |
| How to run the app | `doubtfire-deploy/RUNNING-LOCALLY.md` |
| How to test push on a phone | `docs/notifications/testing-push-locally.md` |

---

## Where your work ends up

```
your branch            ->  feature/notifications               lead merges
feature/notifications  ->  thoth-tech Feature/Notifications    Brian Dang merges
thoth-tech             ->  doubtfire-lms 11.0.x                definition of done
```

`thoth-tech` has no `Feature/Notifications` branch yet. It has to be created
there before the second hop can happen, and that has been asked for.

So a pull request you open is two merges away from the real OnTrack project.
That is worth knowing when you decide how much care to put into it.

---

## If you are stuck

Post in the team channel with:

1. Your ticket ID
2. What you were trying to do
3. The exact error text, copied and pasted, not described
4. What you already tried

Asking early is what a good contributor does. Nobody is judging you for it.
Going quiet for a week is the only thing that actually causes a problem.

And if you are given a command you do not understand, say so before you run it.
That has already found one real bug in our Docker setup.
