# MN-S04 – v2 Push Payload Lock-Screen Risk Review

## Decision

**Sign-off status: NOT APPROVED.**

The v2 event set cannot be approved against the lock-screen rule until the
failed events are changed and the conditional events have an explicit privacy
decision or safer push copy:

- Pass: EN-V01, EN-V02, EN-V03 and EN-V08
- Conditional: EN-V04 and EN-V07
- Fail: EN-V05 and EN-V06

This review covers the current implementations of EN-V01 to EN-V03 and EN-V05
on `feature/notifications`, plus the candidate EN-V04, EN-V06, EN-V07 and
EN-V08 ticket branches. Those candidate branches had not yet merged when this
review was completed.

## Lock-screen rule

A push notification must be safe to display on a locked device where anyone
nearby may read it. The banner title is **OnTrack**, and the notification body
is copied directly from `Notification#message`. Truncating that body to 400
characters limits payload size; it does not redact sensitive content.

The payload also contains an event-and-route collapse tag, the notification ID
and a validated internal click route. Those fields are not rendered as
lock-screen text by the service worker, so this review concentrates on the
title and body. A safe click route does not make an unsafe body safe.

## Event findings

| Event                             | Current lock-screen body                                                                                                       | Finding         | Reason and required action                                                                                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EN-V01 – Task due date changed    | `The due date for <task abbreviation> in <unit code> has changed.`                                                             | **Pass**        | Contains bounded academic identifiers but no date, student name, result, feedback or free-form text.                                                                                                                   |
| EN-V02 – New task available       | `A new task is available: <task abbreviation> in <unit code>.`                                                                 | **Pass**        | Contains bounded academic identifiers and does not reveal a result, submission, feedback or personal detail.                                                                                                           |
| EN-V03 – Task due soon            | `<task abbreviation> in <unit code> is due soon.`                                                                              | **Pass**        | Contains bounded academic identifiers without exposing the exact deadline or student-specific progress.                                                                                                                |
| EN-V04 – Tutorial changed         | `You have been moved to tutorial <tutorial abbreviation> in <unit code>. It meets on <day> at <time>.`                         | **Conditional** | The tutorial and exact meeting schedule reveal location-pattern metadata. Approve only if that metadata is explicitly classified as safe for a locked device. Otherwise use `Your tutorial details changed.` for push. |
| EN-V05 – Group membership changed | `You have been added to group <group name> in <unit code>.` or `You have been removed from group <group name> in <unit code>.` | **Fail**        | A group name is free-form user or staff content and may contain a person's name or other sensitive text. Use `Your group membership changed.` for push.                                                                |
| EN-V06 – Submitted for marking    | `<student name> submitted <task definition name> for marking in <product name>.`                                               | **Fail**        | Exposes a student's name and a potentially free-form task name on the recipient's lock screen. Use `A task is ready for marking.` for push.                                                                            |
| EN-V07 – Portfolio received       | `<product name> received your portfolio submission at <exact time>.`                                                           | **Conditional** | Confirms a student action and exposes its exact time. Approve only if both are explicitly classified as safe for a locked device. Otherwise use `Your portfolio submission was received.` for push.                    |
| EN-V08 – Discussion prompt ready  | `A discussion prompt is ready for you.`                                                                                        | **Pass**        | Generic copy reveals neither a task, staff or student name, nor discussion content. This finding applies to the rescoped discussion-prompt event in the candidate branch.                                              |

## Required changes before approval

1. Give EN-V05 and EN-V06 channel-specific push bodies using the safer text in
   the table. Their richer email and in-app copy may remain unchanged.
2. Resolve the privacy classification for the schedule details in EN-V04 and
   the submission/time details in EN-V07. If there is no explicit approval,
   use the safer push bodies in the table.
3. Treat every free-form value as unsafe for push by default. This includes
   group names, task names, comments, feedback and user-supplied labels.
4. Keep email/in-app meaning separate from lock-screen copy. A message that is
   appropriate after sign-in is not automatically appropriate for Web Push.
5. Add automated negative tests for every push event. Tests should assert that
   the rendered push body does not contain student or staff names, free-form
   values, comments, feedback, results, exact schedule metadata or exact action
   times unless each field has an explicit lock-screen approval.

## Sign-off checklist

- [x] Reviewed all eight v2 event bodies as they would appear in the shared
      Web Push payload.
- [x] Checked the visible title and body separately from hidden payload fields.
- [x] Recorded safer lock-screen copy for every failed or conditional event.
- [ ] Replace unsafe EN-V05 and EN-V06 push copy.
- [ ] Resolve EN-V04 and EN-V07 privacy decisions or replace their push copy.
- [ ] Add channel-specific copy support and lock-screen negative tests.
- [ ] Re-run this review and change the decision to approved.
