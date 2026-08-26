# The effective resubmission deadline

**Status: the rule written here is the rule OnTrack already ran, written down. It is
not approved policy. SLR-E01 (Confirm the Intended Post-Feedback Deadline Rule) has
to confirm or correct it.**

When staff send a task back to a student for more work, the student needs time to do
that work. If the deadline is close, OnTrack quietly moves it. Nobody had written down
what "close" means or how much time gets added, so SLR-E02 wrote it down and fixed the
parts that were wrong no matter which policy SLR-E01 lands on.

## The rule as it stands

A task earns one automatic extension when all of these are true.

| Condition | Where it lives |
|---|---|
| The task was set to Fix and Resubmit, Discuss, Rediscuss or Demonstrate | `Task#resubmission_extension_statuses` |
| The deadline is less than 7 days away, measured from the assessment | `Task#resubmission_extension_window` |
| The unit grants more than 0 weeks on resubmit | `Task#resubmission_extension_weeks` |
| The task can still be extended without passing the unit deadline | `Task#can_apply_for_extension?` |
| This round of feedback has not already had one | `Task#resubmission_extension_comment` |

The extension is the unit's `extension_weeks_on_resubmit_request`, capped so it never
runs past the unit deadline. Units that let students manage their own dates
(`allow_flexible_dates`) never get one.

A round of feedback starts when the student submits. So a student who resubmits and is
sent back again earns another extension, and staff who assess the same submission twice
do not move the deadline twice.

## What SLR-E01 has to decide

1. Is 7 days the right window, and should it be measured from the assessment or from
   the student reading the feedback.
2. Are those four statuses the right list. Demonstrate and Discuss ask the student to
   turn up, not to resubmit, so they may not belong.
3. Is one extension per submission right, or should it be one per task for the whole
   trimester.
4. Whether anything should be applied retroactively. Nothing here is. Tasks that were
   over-extended by the old behaviour keep the weeks they were given.

Changing 1, 2 or 3 is a change to one of the four methods named in the table.

## Worked examples, all covered by tests in `test/models/task_test.rb`

| Case | Result |
|---|---|
| Task due in 2 days, set to Fix and Resubmit | 1 week added, deadline moves once |
| Same task assessed again, same submission | Nothing changes |
| Same task set to Discuss straight after | Nothing changes |
| Student resubmits a week later, sent back again | A second week added |
| Tutor grants 2 more weeks, then reassesses | Stays at 3 weeks, nothing added or removed |
| Task due in 4 weeks, set to Fix and Resubmit | No extension |
| Unit grants 0 weeks on resubmit | No extension |
| Assessment processed with a date from 3 weeks ago | No extension, the window was shut then |
| A prerequisite fix cascades to a dependent task, twice | The dependent task gets 1 week, not 2 |

## Why the deadline used to move more than once

`Task#grant_extension` adds weeks, it does not set them. The old code ran the whole check
on every call to `Task#assess`, so a second Fix and Resubmit on the same submission added
another week, and so did the recursive fix that cascades to dependent tasks. An already
overdue task was the worst case, because it stays inside the 7 day window after being
extended, so it could be extended again and again.

## What the fix does

- One extension per round of feedback. The check is an `ExtensionComment` recorded against
  the task, so it survives restarts, retries and duplicate events, and needed no migration.
- That comment is also the audit trail. It records the weeks, the status that triggered it,
  who assessed it, when, and a sentence the student can read. `task_status_id` is set on
  automatic extensions and nil on ones a student asked for, which is what tells them apart.
  `ExtensionComment#serialize` exposes `automatic` and `source_status` for the interface
  and for notifications.
- The window is measured from the assessment's own timestamp rather than the wall clock,
  so replaying an event gives the answer it gave at the time, and the seven days are added
  as a duration rather than 168 fixed hours. The week that contains a daylight saving
  change is 167 hours long and used to shift the boundary by an hour.

## Known gaps, not fixed here

Group submissions copy the submitter's extension count onto each member task and then run
the check on each of them, so a group can end up further ahead than its submitter. That is
a separate defect in `GroupSubmission#propagate_transition` and it needs its own ticket.

These came out of an independent review of the change. None of them is a regression, every
one of them is either older than this branch or a consequence of deliberately not making a
retroactive change, and each needs a decision from SLR-E01 rather than a quiet fix.

**Tasks extended by the old code are not recognised.** The idempotency check looks for an
`ExtensionComment`, and the old code created none. So a task that already carries an
automatic extension from before this lands can earn one more the next time the same
submission is assessed. After that it is idempotent like everything else. Making the old
rows idempotent means backfilling comments for extensions nobody recorded a reason for,
which is exactly the retroactive change requirement 6 rules out. Flagged rather than fixed.

**The application time zone is UTC.** Nothing sets `config.time_zone`, so
`resubmission_extension_window_open?` judges the window in UTC while campuses carry their
own `timezone`. Near midnight, and on a daylight saving day, the boundary can sit an hour
off the campus day. Reading `project.campus.timezone` would change who qualifies, so it is
a policy call.

**Nothing serialises the check.** The read of the guard, the `extensions` update and the
comment insert are three statements with no lock and no transaction around them. Two
assessments landing together can both see no comment and both grant. A row lock on the task
would close it and is the obvious follow-up.

**The extension is written before the comment.** `grant_extension` persists first and
`record_resubmission_extension` saves after. If the comment raises, the deadline has already
moved and no key exists to stop the next assessment moving it again. Wrapping the pair in a
transaction is the fix and it belongs with the lock above.

**Group threads show one comment per member.** The comment is recorded against each member
task, and `Task#all_comments` returns every comment across the group submission, so a
three-person group assessed once shows three automatic extension comments to everyone. The
extensions themselves are per task and correct. Only the thread is noisy.

**Second-precision timestamps.** The guard compares `date_extension_assessed` against
`submission_date`. On a database still using the older second-precision `datetime` columns,
an assessment and a genuine resubmission inside the same second compare equal and the new
round is suppressed. Unlikely by hand, reachable by a script.
