# Event: task_due_date_changed

A staff member changes a task's due date. Every student who has that task is
told, one email each. Ticket EN (email when a task due date changes).

Built the same way as the worked example in `task_comment_created.md`; read that
one first.

## What it does

A convenor changes a task definition's due date, and every enrolled student who
has that task gets an email telling them the date changed. This means they find
out from OnTrack instead of discovering the change themselves.

## Hook point (confirmed)

`app/models/task_definition.rb`. The due date lives on the **task definition**,
and two existing callbacks already fire on a due-date change:

    after_update :update_tii_group,   if: :saved_change_to_due_date?   # line 63
    after_update :reset_overdue_tasks, if: :saved_change_to_due_date?  # line 65

This event adds a third callback in the same shape, right after them:

    after_update :notify_students_of_due_date_change, if: :saved_change_to_due_date?

`saved_change_to_due_date?` only fires after the new due date has been saved, so
the notification never runs on a change that did not commit.

## Reaching the affected students

`notify_students_of_due_date_change` walks `tasks` the same way
`reset_overdue_tasks` (task_definition.rb:257) does, filtered to enrolled
projects, and sends one notification per student:

    NotificationService.notify(
      user: task.project.student,
      type: 'task',
      event: 'task_due_date_changed',
      message: "The due date for #{abbreviation} in #{unit.code} has changed.",
      link: "/projects/#{task.project.id}/dashboard/#{abbreviation}"
    )

A due date change can affect a whole cohort at once, so the fan-out is per task
and each send is isolated in `notify_student_of_due_date_change`. This way one
student failing cannot stop the rest and cannot roll back the due date save.

## Fields

| Field | Value |
|---|---|
| `type` | `task`, so each student's `receive_task_notifications` switch controls it |
| `event` | `task_due_date_changed` |
| `message` | Names the task and unit. Never the new (or old) due date value |
| `link` | `/projects/<project id>/dashboard/<task abbreviation>` |

## Templates

- `app/views/notifications_mailer/task_due_date_changed.text.erb`
- `app/views/notifications_mailer/task_due_date_changed.html.erb`

Picked up automatically by `NotificationsMailer#event_template_name`; the mailer
is not edited.

## Three things to know before you copy this

1. **Only enrolled students are reached.** The walk filters
   `projects.enrolled = true`, so withdrawn students and staff are not emailed.

2. **One student, one email.** A student has a single task per definition, so the
   fan-out sends exactly one notification to each student rather than one per
   event listener.

3. **A notification must never break the save.** Each send is wrapped in a
   `rescue StandardError` that logs and swallows, so changing a due date succeeds
   even if a notification fails.

## How to check it by hand

1. As a convenor, change a task's due date.
2. Each enrolled student who has that task gets one email at
   http://localhost:8025 (Mailpit). It names the task but not the new date.
3. A student in another unit, and a withdrawn student, get nothing.
4. Turn a student's task notifications off in their profile, change the date
   again, and that student gets no email while the others still do.

## Tests

`test/models/notification_due_date_test.rb`. It covers the full fan-out, that a
student in another unit and a withdrawn student are not notified, the preference
switch, the new date staying out of the message, the link, and the
event-specific template. Run it on its own, because the test database is the
development database. See item 11 in `doubtfire-deploy/RUNNING-LOCALLY.md`.
