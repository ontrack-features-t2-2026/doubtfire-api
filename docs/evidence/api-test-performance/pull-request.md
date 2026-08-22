# Suggested pull request title

`perf(tests): reduce API suite feedback time`

## Jira ticket

Ticket number or link: To be added by the ticket owner after creating the
Microsoft Planner task.

## Summary

Reduces API test feedback time while preserving the complete Rails test-file
inventory and keeping each CI shard isolated from the others.

The unit-test workflow now runs four deterministic, line-balanced shards in
parallel. The shard runner discovers every `test/**/*_test.rb` file
automatically, verifies that each file is assigned exactly once, preserves the
aggregate `unit-tests` required check, cancels superseded runs, supports
manual runs, and limits cache export to shard 1 within each workflow run.

Normal test runs no longer pay for an unused SimpleCov report, while explicit
coverage remains available with `COVERAGE=true`. The redundant
DatabaseCleaner transaction layer is removed in favour of Rails' existing
transactional tests.

The test audit also resolved duplicate Ruby method definitions that silently
replaced earlier tests. One distinct extension scenario is restored and its
outdated setup corrected; a strict-subset Turnitin test and two byte-identical
PDF-test copies are consolidated without losing assertions.

## Target branch

`11.0.x`

## Testing

- Targeted extension and Turnitin tests:
  `bundle exec rails test test/api/comments/extension_test.rb test/api/tii/tii_hook_test.rb --seed 12345`
  — 10 runs, 54 assertions, 0 failures, 0 errors, 0 skips.
- Coverage-enabled current-branch check:
  `COVERAGE=true bundle exec rails test test/models/activity_type_model_test.rb --seed 12345`
  — 9 runs, 12 assertions, 0 failures, 0 errors, and a SimpleCov report was
  generated.
- Four shard dry runs — 91 files discovered, 91 assigned, 91 unique; shard
  weights were 6,436 / 6,434 / 6,434 / 6,433 lines.
- Duplicate registration scan — no duplicate `ClassName#test_method` pairs
  across 706 `def test_*` declarations.
- Repeated shard construction — byte-identical output.
- Invalid shard values and unknown arguments — rejected with exit status 1 and
  clear messages.
- `bundle check` in the Rails image — dependencies satisfied.
- RuboCop on `script/test_shard.rb` — no offences.
- Actionlint on `.github/workflows/push.yml` — passed.
- Ruby syntax and `git diff --check` — passed.

The renamed PDF test retains the exact body that Ruby already ran before this
change, but it was not re-executed locally because it requires the complete
LaTeX/Docker service environment. The pull request's four shard jobs are the
full service-backed verification, and the aggregate `unit-tests` job passes
only when every shard succeeds.

## Security and privacy

No authentication, permissions, notifications, student-data handling, secrets,
personal information, or privacy behaviour is changed.

No known security or privacy impact.

## Evidence

- [Evidence index](https://github.com/ontrack-features-t2-2026/doubtfire-api/blob/perf/faster-api-tests/docs/evidence/api-test-performance/README.md)
- [Shard validation summary](https://github.com/ontrack-features-t2-2026/doubtfire-api/blob/perf/faster-api-tests/docs/evidence/api-test-performance/shard-validation.txt)
- [Targeted-test result](https://github.com/ontrack-features-t2-2026/doubtfire-api/blob/perf/faster-api-tests/docs/evidence/api-test-performance/targeted-test-results.txt)
- [Coverage-mode raw result](https://github.com/ontrack-features-t2-2026/doubtfire-api/blob/perf/faster-api-tests/docs/evidence/api-test-performance/coverage-test-results.txt)
- [Historical exploratory benchmark and limitations](https://github.com/ontrack-features-t2-2026/doubtfire-api/blob/perf/faster-api-tests/docs/evidence/api-test-performance/historical-benchmark.txt)
- [Representative 33m17s baseline workflow](https://github.com/doubtfire-lms/doubtfire-api/actions/runs/32479465525)

The historical exploratory benchmark reduced its 53-test sample from 240.16s
to 183.31s of test time, a 23.7% improvement before parallel sharding. It ran
on a different branch and is directional only. The projected four-shard
critical path is 12–15 minutes; the pull-request workflow will provide the
authoritative current-branch timing.

## Checklist

- [x] I selected the correct base branch.
- [ ] My changes match the assigned Jira ticket.
- [x] I kept the change within the agreed scope.
- [ ] I tested my changes.
- [x] I did not include passwords, tokens, API keys, secrets, or real student data.
- [x] I updated relevant documentation, or no documentation change was needed.
- [x] I reviewed my own changes before requesting review.
- [ ] This pull request is ready for review.
