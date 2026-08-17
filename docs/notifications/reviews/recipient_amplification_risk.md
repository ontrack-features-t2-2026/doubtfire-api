\# EN-S04 – Recipient and Email Amplification Risk Review



\## Purpose



This review looks at the recipient and email amplification risks for notification events EN-V01 to EN-V08.



The main question for each event is:



\- Who should actually receive the notification?

\- Can one user action cause several internal updates?

\- If it can, how many emails could that generate?

\- Is there already a guard in place?

\- If not, what kind of guard should be added when the event is implemented?



This is a review task only. No production notification code was changed as part of EN-S04.



The review was completed against the current `feature/notifications` branch of `doubtfire-api`.



\---



\## Main amplification risks found



While reviewing the notification paths, I found three places where one logical action can result in several internal operations.



\### 1. Unit date changes



`Unit#propogate\_date\_changes\_to\_tasks` runs when a unit start date changes.



It loops through the unit's task definitions and calls:



`td.propogate\_date\_changes date\_diff`



`TaskDefinition#propogate\_date\_changes` then changes the task dates and saves the TaskDefinition.



This means one unit date change can save many TaskDefinitions.



If a due-date email was attached directly to a general TaskDefinition update callback, one unit-level change could accidentally generate emails for every affected task and every eligible student.



If there are `T` task definitions and `S` eligible students, the worst-case fan-out could be approximately:



`T × S emails`



The current EN-V01 implementation avoids this by raising the event from the normal task-definition update API rather than from a generic model callback.



\---



\### 2. Moving a group between tutorials



`Group#switch\_to\_tutorial` processes every project in the group.



For each project it temporarily calls:



`remove\_member(proj, notify: false)`



and later:



`add\_member(proj, notify: false)`



These membership changes are internal steps needed to move the group. They are not real group leave/join events.



Without the `notify: false` guard, a group with `N` members could receive:



`N removal emails + N addition emails`



or:



`2N false emails`



from one tutorial move.



The current implementation correctly suppresses these temporary notifications.



\---



\### 3. Group task transitions



`GroupSubmission#propagate\_transition` loops through the tasks belonging to the group submission.



For the other eligible tasks it calls:



`task.trigger\_transition(... group\_transition: true ...)`



This means one group submission can cause several task transition calls internally.



Any notification added to the task transition path needs to distinguish the original action from the propagated transitions. Otherwise one logical group submission could generate several notifications.



The existing `group\_transition` flag gives us a way to make that distinction.



\---



\# EN-V01 – Task due date changed



\## Trigger



The current implementation raises this event from:



`app/api/task\_definitions\_api.rb`



After the normal task-definition update, the API checks whether `due\_date` actually changed and queues:



`TaskDueDateChangedNotificationJob`



The notification is deliberately not attached to every TaskDefinition save.



\## Recipient



The intended recipients are eligible students affected by that task.



The current job filters based on the active unit, enrolment and target grade. The existing task-notification preference is then handled through the notification system.



\## Worst case



For one directly changed task and `S` eligible students:



`S emails`



This is expected because the change affects the cohort.



The more dangerous case would be a unit date change affecting `T` tasks, which could become:



`T × S emails`



if the notification was attached to every TaskDefinition save.



\## Existing guard



The current API-level trigger avoids that cascade.



The job also checks that the queued due date is still current, which helps avoid stale notifications if the date changes again before the job runs.



\## Recommendation



Keep this event attached to the normal task-definition update workflow.



Do not move it to a generic TaskDefinition lifecycle callback.



If students need to be notified about a bulk unit schedule change in the future, a separate unit-level notification or digest would be safer than one email for every changed task.



\---



\# EN-V02 – New task available



\## Trigger



The current implementation queues:



`NewTaskAvailableNotificationJob`



after a TaskDefinition is successfully created through the normal task-definition API.



A generic `TaskDefinition after\_create` callback is not used.



\## Recipient



The intended recipients are students for whom the new task is actually available.



The current job checks things such as:



\- active unit;

\- current enrolment;

\- target-grade eligibility;

\- effective task start date; and

\- task notification preference.



\## Worst case



For one new task and `S` eligible students:



`S emails`



This is expected.



There are other TaskDefinition creation paths, including CSV/import-related code. If a bulk operation created `T` tasks and each automatically triggered a cohort notification, the fan-out could become:



`T × S emails`



from one import.



\## Existing guard



The current implementation only queues EN-V02 from the normal API creation path.



It also checks for an existing notification for the same student, event and task link before sending, which protects against the fan-out job being run again.



\## Recommendation



Keep the current API-level trigger.



Do not replace it with a generic `after\_create` callback.



If imports, rollovers or copying should generate this notification later, those workflows should be reviewed separately so that a bulk action does not unexpectedly email students once for every created task.



\---



\# EN-V03 – Task due soon



\## Trigger



There is no model update that naturally happens when a deadline becomes close, so EN-V03 uses:



`SendDueSoonRemindersJob`



The job is scheduled through `config/schedule.yml`.



\## Recipient



The job considers students with outstanding eligible tasks whose actual due date falls within the reminder window.



It uses the existing due-date calculation rather than simply reading the raw TaskDefinition date.



\## Worst case



A scheduled run can legitimately find many student/task combinations.



If `S` students each have `T` eligible outstanding tasks inside the reminder window, the theoretical fan-out can approach:



`S × T reminders`



This is expected scheduled workload rather than amplification from a single convenor action.



\## Existing guard



Before sending, the job checks whether that student/task already has a `task\_due\_soon` notification.



The intended behaviour is therefore:



`one reminder per student per task`



Running the job again should not send the same reminder again.



\## Recommendation



Keep the duplicate check.



The schedule should not be made unnecessarily frequent because each newly matched student/task pair can result in an email.



The schedule entry should also not be described as fully verified in development until the required Sidekiq worker is available.



\---



\# EN-V04 – Tutorial changed



\## Proposed trigger



The relevant method is:



`Project#enrol\_in`



This method has different behaviours that need to be kept separate.



If the project is already in the requested tutorial, there is no real change.



If there is no existing matching enrolment, the method creates a new TutorialEnrolment. That is a first-time enrolment and should not be treated as a tutorial change.



The actual move happens when an existing enrolment is updated to another `tutorial\_id`.



\## Recipient



The correct recipient is:



`project.student`



Only the student whose tutorial changed should receive the notification.



The whole old tutorial or new tutorial should not be treated as the recipient list.



\## Worst case



A normal one-student move should generate:



`1 email`



A group tutorial move involving `N` students could legitimately result in:



`N tutorial-change emails`



if each student's tutorial really changes.



\## Risk



The main recipient risk would be notifying everyone in the old or new tutorial rather than only the students whose enrolments changed.



There is also a risk of treating first-time enrolment as a tutorial move.



\## Recommendation



Only raise EN-V04 when an existing tutorial enrolment actually changes tutorial.



Do not notify for:



\- first-time enrolment;

\- selecting the same tutorial again; or

\- internal enrolment cleanup that does not represent a real move.



The recipient should remain the affected project's student.



Bulk/import callers should be considered separately before they are allowed to generate student emails.



\---



\# EN-V05 – Group membership changed



\## Trigger



The current implementation uses:



`Group#add\_member`



and:



`Group#remove\_member`



\## Recipient



The current scope is student-only.



The recipient is the student whose membership changed.



Other members of the group are not notified.



\## Worst case



A normal direct addition should generate:



`1 email`



A normal direct removal should generate:



`1 email`



The important amplification case is `Group#switch\_to\_tutorial`.



Without a guard, a group with `N` members could receive:



`2N false group membership emails`



because every student is temporarily removed and added again.



\## Existing guard



The current tutorial-switch path calls both membership methods with:



`notify: false`



This correctly prevents the internal remove/add operations from becoming real notification events.



The current implementation also avoids broadcasting the event to every member of the group.



\## Stale member risk



The notification uses the project involved in the current add/remove operation rather than walking old GroupMembership records.



This reduces the risk of former or inactive members receiving a notification about a later membership change.



\## Recommendation



Keep the existing `notify: false` guard for internal operations.



The event should continue to notify only the student whose membership changed unless the team explicitly decides that group-wide notifications are required.



Bulk membership changes should also remain explicitly controlled rather than inheriting notification behaviour automatically.



\---



\# EN-V06 – Student submitted for marking



\## Proposed trigger



This event overlaps with:



`Task#trigger\_transition`



because a student submission moves the task into a ready-for-marking/feedback state.



EN-E02 already uses this transition area for task status notifications, so EN-V06 should not add another call blindly without checking the existing behaviour.



\## Recipient



The intended recipient is:



`project.tutor\_for(task\_definition)`



The implementation must handle the case where no tutor is returned.



\## Amplification risk



Group submissions are the important case.



`GroupSubmission#propagate\_transition` can call `trigger\_transition` for the other tasks in the group with:



`group\_transition: true`



If EN-V06 simply sent an email every time the transition method ran, one group submission could create several tutor emails.



For a group with `N` member tasks, one logical submission could potentially result in up to:



`N notification attempts`



instead of one.



\## Recommendation



Only the original submission should raise the tutor notification.



Transitions where:



`group\_transition: true`



should not independently raise the same `task\_submitted` event.



Another clean option would be to raise the notification once from the group-submission boundary rather than once from each member task.



There is also a legitimate volume concern even after the amplification issue is fixed. A tutor with many students could receive many independent submission emails in a short period.



That is not a duplicate-notification bug, but it may be worth discussing whether a future digest would provide a better experience.



\---



\# EN-V07 – Portfolio submission received



\## Proposed trigger



The portfolio submission path writes:



`project.portfolio\_submission\_date = Time.zone.now`



in:



`app/api/projects\_api.rb`



The reviewed branch does not currently contain a `portfolio\_received` event.



\## Existing portfolio emails



The existing `PortfolioEvidenceMailer` contains:



\- `portfolio\_ready`

\- `portfolio\_failed`



These describe what happened after portfolio generation.



They are different from a confirmation that the student's submission itself was received.



\## Recipient



The intended recipient should be:



`project.student`



\## Worst case



A normal accepted portfolio submission should generate:



`1 confirmation email`



The risk is repeated requests or retries generating multiple receipt emails for the same logical submission.



\## Recommendation



Only raise the receipt notification when a genuine portfolio submission is accepted.



The implementation should prevent a retry or repeated request for the same submission from creating another receipt, while still allowing a later genuine resubmission to receive its own confirmation.



The exact deduplication mechanism should be agreed with the lead before implementation.



EN-V07 should also remain separate from the existing `portfolio\_ready` and `portfolio\_failed` emails because they represent different stages of the portfolio process.



\---



\# EN-V08 – Discussion or check-in booked



\## Scope finding



This event cannot currently be implemented as written.



The reviewed API does not contain a booking model, appointment model or calendar booking table that represents a future discussion booking.



The existing discussion/check-in related models represent things that have already happened rather than a future appointment.



For example, the existing discussed-comment path records a discussion that has already taken place.



\## Recipient



There is no reliable recipient or trigger to review until the event itself is redefined.



\## Recommendation



Do not force EN-V08 onto an unrelated model or invent a booking concept.



The replacement event needs to be agreed with the lead first.



One possible replacement mentioned in the ticket is a notification when a discussion prompt is raised for a student, but that should only be implemented if the team agrees that this is the intended replacement.



If no replacement is agreed, closing or rescoping EN-V08 is the correct outcome.



\---



\# Risk Summary



| Event | Expected fan-out from one action | Main risk | Current/recommended guard |

|---|---:|---|---|

| EN-V01 – Due date changed | `S` | Unit date propagation could become `T × S` | Keep API-level trigger; avoid generic TaskDefinition callback |

| EN-V02 – New task | `S` | Bulk creation/import could become `T × S` | Keep normal API trigger; handle bulk paths separately |

| EN-V03 – Due soon | Up to `S × T` per scheduled sweep | Same reminder being sent every run | Existing duplicate check: one reminder per student/task |

| EN-V04 – Tutorial changed | `1` normally, `N` for a real group move | Notifying whole tutorials or first-time enrolments | Notify only projects whose existing enrolment actually changed |

| EN-V05 – Group changed | `1` normally | Tutorial switch could create `2N` false emails | Existing `notify: false` guard |

| EN-V06 – Submitted for marking | `1` intended | Group transition could create up to `N` notification attempts | Suppress propagated `group\_transition` calls or notify once at group boundary |

| EN-V07 – Portfolio received | `1` intended | Duplicate confirmation after retry/repeated request | Send once per genuine submission occurrence |

| EN-V08 – Discussion booked | N/A | No booking concept exists | Rescope before implementation |



\---



\# General recommendations



From this review, the main rule I would follow for the remaining v2 notification work is:



\*\*A notification should represent one meaningful user-facing event, not every internal model operation needed to complete that event.\*\*



In particular:



1\. Use the project/student directly affected by the event instead of building unnecessarily broad recipient lists.



2\. Avoid generic lifecycle callbacks where the same model is also changed by imports, rollovers, propagation or maintenance operations.



3\. Use existing context flags such as `group\_transition` when an internal update needs to be distinguished from the original action.



4\. Keep bulk operations explicit. A CSV import or group-wide change should not start emailing large numbers of people simply because it happens to call the same model method as an individual action.



5\. Use duplicate protection for jobs that may be retried or scheduled repeatedly.



6\. Check current membership/enrolment state rather than using historical relationships when deciding recipients.



7\. Where an event has no matching domain action, as with EN-V08, rescope it rather than forcing a notification onto the wrong hook.



\---



\# Conclusion



The review confirmed that the biggest email amplification risks are caused by internal cascades rather than by the email templates themselves.



The three clearest examples are:



\- a unit date change updating many TaskDefinitions;

\- a group tutorial move temporarily removing and re-adding every member; and

\- a group task submission propagating the same transition across several tasks.



The current EN-V01, EN-V02, EN-V03 and EN-V05 work already contains useful safeguards against these problems.



For the remaining events, the most important protections are to keep recipients narrow, distinguish real user actions from internal propagation, and prevent repeated execution from generating duplicate email.



EN-V08 should remain unimplemented until the team agrees on a replacement event because the current API does not contain a discussion-booking concept.



Overall, the safest pattern is:



\*\*one logical event → the intended current recipient(s) → no extra email just because the action caused several internal records to change.\*\*

