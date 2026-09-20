# Notification integration decisions

## 20 September 2026: the maintained base is 11.0.x

API PR #150 delivered the rebuilt notification integration and #159 assembled
the reviewed fixes on `11.0.x`. New notification work branches from and targets
current `origin/11.0.x`; the retired integration branch is not a second source
of truth. Refresh active work at least weekly and before requesting review,
then rerun checks affected by upstream changes. Record the exact API, web and
deploy revisions in the PR. Merges remain a separate reviewer's responsibility.

## 20 September 2026: burst policy

Cohort admission and per-recipient external delivery are bounded separately.
A blocked cohort sends nothing until an operator deliberately reruns it with
the large-fanout override. A recipient burst retains in-app records while
suppressing excess email/push. A digest would change notification semantics;
it is deferred rather than silently treating dropped emails as a digest.
A future digest proposal must define grouping, delivery delay and preference
changes before implementation. Throttled records are not automatically replayed.
