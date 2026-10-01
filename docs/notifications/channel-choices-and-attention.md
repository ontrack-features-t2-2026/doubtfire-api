# Notification choices and teaching attention

## Rollout and existing consent

Apply `20261001000001_add_notification_channel_choices` before deploying the API
and web changes. It copies each existing task, feedback and portfolio preference
to both new outgoing channel columns. Accounts with feedback notifications off
move to `digest_frequency=off`, preserving the old summary opt-out. No existing
account is newly subscribed to email or push by the migration.

The account owner can then choose email and push independently with
`receive_{task|feedback|portfolio}_{email|push}_notifications`. Turning either
channel off retains future in-app activity. Unit Hub keeps its existing category
switch and separate channel opt-ins. Extension decisions, group changes and tutorial updates use the task
email/push choices as well, so turning those channels off is respected. Push still requires a browser subscription and VAPID
configuration; these preferences do not grant browser permission.

Only the account owner can change these choices, `digest_frequency`, or
`staff_digest_frequency`. Old clients can still submit `receive_*_notifications`;
a legacy category choice updates both outgoing channels. Explicit new channel
fields take precedence over stale legacy fields in the same request.

The legacy switch mirrors `email AND push` after a new choice. This deliberately
keeps an older application from re-enabling an opted-out channel during an image
rollback. The down migration copies that same conservative value before dropping
the new columns. Do not roll back the schema while new API/worker instances run.
Digest opt-outs are never reversed by rollback. Restore application and worker
versions together; old scheduled student summaries retain their old behaviour.

## Summaries

Student cadence is independent of event email/push: `off`, `daily`, `weekly` or
`monthly`. The job rechecks the stored cadence immediately before reserving a
send. Failed recipients release their delivery claim and the sweep raises so
Sidekiq retries; successful recipients keep their period claim.

Teaching summaries use `staff_digest_frequency`: `off` (default), `daily`, or
`weekly`. `send_daily_staff_attention` and `send_weekly_staff_attention` call
`SendStaffAttentionSummariesJob` on the `mailers` queue. Each opted-in staff member
receives one combined email only when a teaching unit has work requiring a
response. The recipient's current non-observer teaching roles and active enrolled
students define the scope. There is no automatic system-wide administrator view.

A tutor's tasks must match their assigned tutorial stream; convenors see their
unit. Email includes counts and unit codes, not student identities or feedback.
No new push message or lock-screen content is introduced.

`GET /api/attention/staff` is authenticated and returns `Cache-Control: private,
no-store`, `units` and `totals`. Each unit contains `unit_id`, `unit_code`,
`unit_name`, `queue_scope` (`mine` or `all`), `awaiting_feedback_count`,
`help_requested_count`, `extension_requested_count`, `oldest_wait_days`,
`overdue_feedback_count`, and `feedback_warning_threshold_days`. Pending extension
counts are distinct tasks. Waits use existing teaching days (excluding breaks),
and overdue means the unit's warning threshold has been reached, not that the
separate overflow-claim threshold has been reached. The existing inbox remains
authoritative when the user opens it.

## Deadline agreement and reminder identity

The calendar date helper is reused by recommendation ranking, cross-unit digest
figures and next-task selection, including student flexible dates and grade dates
before a Task row exists. Task recommendation responses add the effective date,
reason and plain-language next action without removing existing fields.

Due-soon reminder identity is `(project, task definition, effective calendar
date)`. A changed date earns one fresh reminder within the three-day window;
repeat sweeps/concurrent retries share the database deduplication key. An old
unkeyed reminder cannot establish which historical effective date it represented,
so the first post-upgrade sweep may add one keyed reminder for an eligible task.
Subsequent sweeps do not duplicate it. No historical deadline is invented.

Calendar subscriptions still depend on provider refresh intervals. This change
does not assert instant Google/Apple/Outlook sync or alter the approved academic
extension policy.

## Notification inbox contract

`GET /api/notifications` preserves the existing array response. New clients opt
into an envelope with `paginated=true`; `page` and `per_page` bound the list
(`per_page` maximum 100). Filters are `unread_only`, `notification_type`, `event`,
and `unit_id`. The envelope contains `notifications`, `total_count`, `page`,
`per_page`, global `unread_count`, `through_id`, `units`, and `events`.

Every list, facet and count is derived from the current account. Unit filters
resolve recognised notification targets and links through authorised data;
filtering is performed before pagination. `through_id` is the confirmation
boundary for Delete all, so events arriving after the confirmation was shown
survive deletion. Pagination does not change that existing deletion contract.

## Verification

Focused regression coverage includes legacy migration opt-outs, account-owner
settings, per-channel delivery, deadline agreement with flexible dates, reminder
rearming, staff assignment/observer isolation, and opted-in summary deduplication.
Use a populated disposable test database and local mail capture. Template tests
prove rendering; they do not prove delivery to a real inbox or device.

On 1 October 2026 the full RuboCop check passed all 650 Ruby files. A separate
disposable database passed an actual migration down/up/down/up audit: historical
category opt-outs remained off in both outgoing channels, historical feedback
opt-outs retained `digest_frequency=off`, explicit daily summary consent survived
the initial upgrade, and an email-on/push-off choice rolled back conservatively
to both off. Staff summaries remained off by default. This audit did not touch
the development or regression-test databases.
