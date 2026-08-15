# New Task Available Notification

## Event

`new_task_available`

## Purpose

Notifies eligible students when a new task becomes available through the normal convenor task-creation workflow.

## Trigger

The notification fan-out is queued after a new task definition is successfully created through the normal task-definition API.

The hook is located in:

`app/api/task_definitions_api.rb`

immediately after:

`task_def.save!`

A general `TaskDefinition` `after_create` callback is intentionally not used because task definitions are also created through rollover, copy and import workflows. Triggering from the model could therefore generate unexpected or duplicate notifications.

## Notification

- Type: `task`
- Event: `new_task_available`
- Recipient: eligible students enrolled in the unit
- Preference: `receive_task_notifications`

`NotificationService` applies the existing task-notification preference before creating and delivering the notification.

## Recipient eligibility

A student receives the notification only when all of the following are true:

- The task was created through the normal convenor API.
- The unit is active.
- The student is currently enrolled in the unit.
- The task applies to the student's target grade.
- The student's effective task start date is now or earlier.
- The student has task notifications enabled.

The student's effective start date is determined using the existing `Task#local_start_date` behaviour so that flexible dates, target-grade dates and supported student-specific date adjustments are respected.

## Fan-out

Notification delivery is not performed directly inside the API request.

After the task definition is saved, the API enqueues:

`NewTaskAvailableNotificationJob`

The job processes enrolled projects in batches and sends one notification to each eligible student.

Duplicate notifications for the same student and task are prevented if the fan-out job is executed more than once.

## Email templates

HTML:

`app/views/notifications_mailer/new_task_available.html.erb`

Plain text:

`app/views/notifications_mailer/new_task_available.text.erb`

## Link

The notification links the student to the new task on their project dashboard:

`/projects/:project_id/dashboard/:task_abbreviation`

## Future-dated tasks

Students whose effective task start date is in the future are not notified when the task definition is created.

The create endpoint will not execute again when that future start date arrives.

Scheduled release-time notifications for future-dated tasks are therefore outside the scope of this first EN-V02 implementation and should be handled as follow-up work.

## Out of scope

The following task-definition creation paths are deliberately outside this first implementation:

- unit rollover
- task copying
- CSV/import workflows
- scheduled notifications when a future effective start date is reached

## Tests

Automated tests are located at:

`test/models/notification_new_task_test.rb`

The tests cover:

- notification for an eligible student
- fan-out to multiple eligible students
- task-notification preference disabled
- unenrolled students
- task target-grade eligibility
- inactive units
- future effective start dates
- duplicate prevention

Test command:

`bundle exec rails test test/models/notification_new_task_test.rb`

Current result:

`8 runs, 52 assertions, 0 failures, 0 errors, 0 skips`