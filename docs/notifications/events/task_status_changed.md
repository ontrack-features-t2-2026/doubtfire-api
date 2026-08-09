# Event: task_status_changed

A staff member changes the status of a task. The student is told. Ticket EN-E02.

Built the same way as the worked example in `task_comment_created.md`; read that
one first.

## What it does

A tutor marks a task, and the student whose task it is gets an email telling them
the status changed.

- A tutor changes the status, the student is emailed.
- A student changing their own task is not emailed about their own action.

## Where it is raised

`app/models/task.rb`, in `notify_student_of_status_change`, called at the end of
`trigger_transition` once the transition has succeeded and the new status has
been saved.

    NotificationService.notify(
      user: project.student,
      type: 'task',
      event: 'task_status_changed',
      message: "#{by_user.name} updated the status of #{task_definition.abbreviation} in #{unit.code}.",
      link: "/projects/#{project.id}/dashboard/#{task_definition.abbreviation}"
    )

## Fields

| Field | Value |
|---|---|
| `type` | `task`, so the student's `receive_task_notifications` switch controls it |
| `event` | `task_status_changed` |
| `message` | Who acted, which task, which unit. Never the new status value |
| `link` | `/projects/<project id>/dashboard/<task abbreviation>` |

## Templates

- `app/views/notifications_mailer/task_status_changed.text.erb`
- `app/views/notifications_mailer/task_status_changed.html.erb`

`NotificationsMailer#single_notification` picks the template named after the
event when it exists. Adding this event never required editing the mailer.

## Three things to know before you copy this

1. **Only a staff action notifies.** The guard is `role == :tutor`. A student
   changing their own task (submitting, working on it) must never email
   themselves. `role` is already worked out at the top of `trigger_transition`.

2. **Only a real change notifies.** The status before the transition is captured
   and compared at the end. Re-applying the same status is a no-op and sends
   nothing.

3. **A notification must never break the transition.** The call is wrapped in a
   `rescue StandardError` that logs and swallows. Marking a task must succeed
   even if notifying fails.

## How to check it by hand

1. Sign in as a tutor, open a student's task, change its status.
2. An email to the student arrives at http://localhost:8025 (Mailpit). It names
   the tutor and the task, and does not contain the new status value.
3. Sign in as that student, change one of their own tasks, and confirm no email
   is sent to themselves.
4. Turn that student's task notifications off in their profile, have the tutor
   mark again, and no email arrives.

## Tests

`test/models/notification_task_status_test.rb`

Covers the staff change, the student's own action sending nothing, an unchanged
status sending nothing, the preference switch, the status value staying out of
the email, the event-specific template being used, and that a notification
failure still leaves the transition committed.
