# Existing Email Audit

This document records the email behaviour that already exists in OnTrack before
the v2 notification work. Its purpose is to prevent new notification events from
duplicating existing email behaviour or accidentally sending multiple messages
for the same action.

The audit covers both the API mailers and the existing communication subsystem
in the web application.

## API email send sites

A search of `doubtfire-api` for `.deliver`, `.deliver_now`, and
`.deliver_later` identified 21 real email send sites. Push notification service
calls and method definitions are not counted as email send sites.

| Existing email | Trigger / send site | Recipient | Preference / guard |
| --- | --- | --- | --- |
| Turnitin error log | `app/helpers/turn_it_in.rb:88` – Turnitin credential/error handling | Configured administrator/error-log address | None observed |
| Task PDF failed | `app/models/portfolio_evidence.rb:79` – task PDF generation failure | Project student | Task notification preference |
| Weekly student summary | `app/models/project.rb:682` – project weekly summary | Project student | Existing summary eligibility/preference logic |
| Task feedback ready | `app/models/unit.rb:2975` – feedback/PDF processing completes | Project student | Feedback notification preference |
| Weekly staff summary | `app/models/unit_role.rb:207` – staff weekly summary | Staff member represented by the unit role | Existing summary eligibility/preference logic |
| Single notification email | `app/services/notification_service.rb:69` – `NotificationService.notify` accepts an event for delivery | Notification user | Gated by the preference mapped from the notification category |
| Task PDF failed | `app/sidekiq/accept_submission_job.rb:36` – submitted task PDF conversion fails | Project student | `receive_task_notifications` |
| Submission processing error | `app/sidekiq/accept_submission_job.rb:55` – submission processing raises an error and produces an error mail | Administrator/error recipient | None observed |
| Archive error | `app/sidekiq/archive_old_units_job.rb:22` – old-unit archive operation produces an error mail | Administrator/error recipient | None observed |
| D2L grade transfer result | `app/sidekiq/d2l_post_grades_job.rb:27` – D2L grade transfer completes | User who initiated the transfer | None observed |
| D2L grade transfer failure | `app/sidekiq/d2l_post_grades_job.rb:35` – D2L grade transfer fails | User who initiated the transfer | None observed |
| Communication email to student | `app/sidekiq/execute_communication_set_job.rb:162` – an active communication rule executes for matched students | Students matched by the communication rule | Rule conditions determine recipients |
| Communication email to staff | `app/sidekiq/execute_communication_set_job.rb:203` – a staff-email communication action executes | Tutors and/or convenors selected by the rule | Recipient groups are configured in the rule |
| Communication action log | `app/sidekiq/execute_communication_set_job.rb:326` – communication execution produces its action log | Convenors | Operational communication email |
| Tutor note | `app/sidekiq/notify_tutor_notes_job.rb:8` – tutor-note notification job runs | Specific recipient supplied to the job | No preference gate observed in this send path |
| PDF-generation error mail | `lib/tasks/generate_pdfs.rake:145` – PDF generation produces an error mail | Administrator/error recipient | None observed |
| Portfolio ready | `lib/tasks/generate_pdfs.rake:157` – portfolio generation succeeds | Project student | `receive_portfolio_notifications` |
| Portfolio failed | `lib/tasks/generate_pdfs.rake:159` – portfolio generation fails | Project student | `receive_portfolio_notifications` |
| Task PDF failed – maintenance | `lib/tasks/maintenance.rake:50` – maintenance PDF processing fails | Project student | Existing task-notification guard in the maintenance flow |
| Maintenance error mail | `lib/tasks/maintenance.rake:72` – maintenance operation produces an error mail | Administrator/error recipient | None observed |
| Overseer assessment failed | `lib/tasks/overseer_notifications.rake:14` – failed Overseer assessments are grouped for notification | Affected project student | Existing Overseer notification flow |

## Mailers already present

The API currently contains the following relevant mailers:

- `CommunicationsMailer` – sends configurable communication emails and
  communication action logs.
- `D2lResultMailer` – reports D2L grade-transfer results.
- `ErrorLogMailer` – sends operational/error reports.
- `NotificationsMailer` – sends single event notifications and weekly student
  and staff summaries.
- `PortfolioEvidenceMailer` – handles task PDF failure, task feedback ready,
  Overseer assessment failure, portfolio ready and portfolio failed emails.
- `TutorNoteMailer` – sends tutor-note notifications to a supplied recipient.

`ConvenorContactMailer#request_project_membership` and
`PortfolioEvidenceMailer#task_pdf_ready_message` also exist, but no active
`.deliver`/`.deliver_now` send site was found for either during this audit.
They are therefore not counted among the 21 current email send sites.

## Existing web communication subsystem

The web application already contains a unit communications editor under:

`src/app/units/states/edit/directives/unit-communications-editor/`

This is an existing communication system rather than a placeholder for future
notification work.

A convenor can configure communication rules with conditions and actions.
Available actions include:

- Send email to student
- Send email to staff
- Add a task comment
- Change target grade

Student emails support a configurable subject and body. Staff emails also
support configurable subject/body content and can target tutors, convenors, or
both.

Communication rules can filter students using existing conditions including
task status, target grade, login status, special consideration, tutorial,
tutorial stream and campus.

The subsystem also supports scheduled communication sets. A schedule can run
once or recur daily, weekly or monthly. It supports a start week/day/time,
timezone, recurrence interval, repeat count and optional end date.

When a communication set executes, matched students can receive the configured
actions. The execution logic also prevents a student matched by an earlier rule
in the same set from being processed again by a later rule.

## Duplicate-email risks

The existing communications subsystem is the largest duplication risk for v2.
OnTrack can already send configurable email to students and staff, including
scheduled and recurring communication across a unit. A new event should not
reimplement this behaviour without first deciding whether the event belongs in
the existing communication-rule system.

Portfolio events are another clear overlap. OnTrack already emails a student
when portfolio generation succeeds and when it fails. A v2 portfolio event that
also sends email could therefore double-mail the same student.

Task and feedback events must also be checked against
`PortfolioEvidenceMailer`, weekly summaries and the communication-rule system.
Existing task-PDF failures and feedback-ready messages already reach students.

Tutor-note and task-comment work also require care. Tutor notes already have a
direct email path, while the communication editor can create task comments.
New notification hooks around these actions should establish whether the
existing email is being replaced, supplemented, or intentionally left alone.

`NotificationService` introduces another duplication boundary. Events routed
through it can generate a notification email after the relevant notification
preference check. An event must not also retain an independent legacy email
unless two messages are explicitly intended.

## Recipient and preference observations

Existing emails do not use one common preference mechanism.

Some student-facing flows explicitly check preferences, including task,
feedback and portfolio notification settings. `NotificationService` also maps
notification categories to user preferences before delivery.

Other emails are operational messages or direct workflow results and have no
user preference gate in their send path. These include administrator error
messages and D2L transfer results.

The communication-rule subsystem determines recipients from rule conditions
and configured recipient groups rather than the v2 notification preference
mapping.

This distinction must be preserved when an existing email is migrated or
connected to a v2 event. Adding a second preference check without understanding
the legacy behaviour could either suppress a required operational message or
allow duplicate user-facing mail.

## Conclusion

OnTrack already has substantial email functionality in both repositories.

In particular:

1. Students are already emailed when their portfolio is ready or generation
   fails.
2. Students already receive task, feedback, summary and Overseer-related
   emails in existing flows.
3. Staff already receive weekly summaries and can be targeted through the unit
   communications system.
4. Convenors can already configure and schedule email to a unit without any
   new v2 notification feature.
5. The communication subsystem supports both student and staff email and
   recurring schedules.
6. New v2 events must be checked against these send paths before another email
   channel is added.

The safest rule for subsequent event tickets is therefore: before adding an
email delivery path, check this audit and the existing communication subsystem
to determine whether OnTrack already sends an equivalent message.