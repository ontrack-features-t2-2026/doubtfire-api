# PPI-S01 privacy and authorisation review

Review date: 2026-08-23

Reviewed target: `feature/peer-progress-indicator` at `50cd1e72`

Result: **Conditional pass**

## Scope and attribution

This review covers the task-level student peer-progress endpoint, its aggregate
snapshot path, and ordinary application logging. It does not change the PPI
response contract, aggregation rules, frontend, or feature scope.

The endpoint privacy and authorisation test foundation was added by Maple Fox
in commit `e224f2b2` and later expanded on the shared branch. PPI-S01 preserves
that attribution and adds the remaining independent log-privacy evidence and
risk result.

## Test result

| Risk | Evidence | Result |
| --- | --- | --- |
| Unauthenticated request | `requires authentication` | Pass: HTTP 419 and private, no-store response |
| Cross-user project request (IDOR) | `does not allow a student to read another students project` | Pass: generic HTTP 404 with no data |
| Cross-unit task request | `does not allow a task from another unit` | Pass: generic HTTP 404 with no data |
| Non-student use of the student route | `does not allow a tutor to use the student endpoint` | Pass: generic HTTP 404 with no data |
| Invalid or unreleased context | Enrolment, active-unit, target-grade and release-date tests | Pass: denied with no peer-progress data |
| Response overexposure | Exact response-key allowlist and forbidden-key assertions | Pass: aggregate contract only; no peer identity, raw count, mark, feedback or task-status list |
| Small or empty cohort | Suppression, threshold and empty-cohort tests | Pass: percentage hidden below the configured floor |
| Missing, stale or disabled data | Unavailable, stale and disabled-state tests | Pass: percentage hidden and neutral state returned |
| Object enumeration | Unknown project/task comparison | Pass: the same generic one-key error is returned |
| Browser-supplied cohort selection | `ignores a browser supplied target grade` | Pass: target grade comes from the authorised project |
| Ordinary logs and Sidekiq failure state | `sanitizes aggregation errors before Sidekiq handles them` plus code review | Pass: a synthetic exception canary stays out of the application log and sanitized failure passed to Sidekiq; unit context and exception class remain available in the application log |

The endpoint and aggregation service add no peer-specific log statements. The
existing authentication helper records the requesting student's username and
IP address, but does not receive peer records. The background job records only
its unit context, lifecycle state and exception class. Its failure path no
longer interpolates or re-raises the original exception message, because
Sidekiq 7.3.9 persists the raised exception message in retry and dead-job
state. Instead, the job raises a generic `AggregationError` with no original
cause. The job-level regression raises a service exception containing a
synthetic username, name, email and student ID and proves that none reach the
application log or the exception handed to Sidekiq.

All automated evidence uses generated records. No real student data is used.

## Security assessment

The current endpoint resists direct IDOR and peer-record disclosure:

- the project is selected from the authenticated student's active enrolments;
- the task is selected through that project's unit;
- access failures use the same generic response;
- successful responses are built from an exact aggregate-only allowlist;
- raw cohort size and submitted count are never returned;
- small cohorts and stale or unavailable snapshots hide the percentage;
- responses are marked `private, no-store`; and
- the feature defaults to disabled at the unit level.

This is a conditional rather than unconditional pass because two inference
risks need an explicit product/security decision before broad enablement:

1. A student can change their own target grade through the existing project
   update flow. The endpoint invalidates snapshots that predate that change,
   and values are quantised, but a later aggregation can still let the student
   observe a different target-grade bucket. Consider a cooldown, rate limit,
   fixed cohort assignment, or an explicit acceptance of this behaviour.
2. The requesting student is a member of the aggregate cohort. Moving between
   target-grade cohorts can change whether a group crosses the privacy floor.
   Consider a margin above the minimum, delayed cohort changes, or another
   approved disclosure-control rule.

These are aggregate-inference risks, not a bypass of the tested project/task
authorisation boundary. They are recorded here rather than expanding PPI-S01
into production feature work.

## Reproduction

Run the PPI regression set with a fixed seed:

```sh
bundle exec rails test \
  test/models/peer_progress_snapshot_test.rb \
  test/services/peer_progress_aggregation_service_test.rb \
  test/sidekiq/aggregate_peer_progress_job_test.rb \
  test/sidekiq/scheduled_job_test.rb \
  test/api/peer_progress_api_test.rb \
  test/api/units_api_test.rb \
  --seed 20260823
```

Then run targeted linting:

```sh
bundle exec rubocop \
  app/sidekiq/aggregate_peer_progress_job.rb \
  test/sidekiq/aggregate_peer_progress_job_test.rb
```

Verified on 2026-08-23: 104 tests, 1,008 assertions, 0 failures,
0 errors and 0 skips; two RuboCop files inspected with no offences.
