# Reduce API test feedback time and restore hidden test coverage

## Planner fields

- **Repository:** `ontrack-features-t2-2026/doubtfire-api`
- **Suggested branch:** `perf/faster-api-tests`
- **Target branch:** `11.0.x`
- **Status:** In progress
- **Priority:** Important
- **Start date:** 23/08/2026
- **Due date:** Not set
- **Repeat:** Does not repeat
- **Bucket:** Not assigned — select the existing backend/API bucket when
  creating the task
- **Suggested labels:** Testing, github, Foundation

## Purpose

Reduce the API suite's 30-plus-minute feedback cycle without skipping tests or
weakening assertions, while correcting Ruby test-method collisions that hid one
distinct extension scenario and left redundant test bodies in the source.

## Dependencies and boundaries

- Preserve Rails 8, Minitest, MariaDB, Redis, LaTeX, JPlag, Overseer, cache, and
  filesystem test behaviour.
- Keep each CI shard isolated so the suite's shared mutable state cannot cross
  between jobs.
- Keep coverage reporting available explicitly even though it is not generated
  during every normal test run.
- Continue using Rails transactional tests; any future test that opts out or
  writes through another process must add targeted cleanup.
- Preserve the existing required `unit-tests` check name.
- Do not remove slow tests, assertions, fixtures, or service-backed coverage to
  reach the runtime target.
- Treat the latest completed pull-request workflow as the authoritative
  full-suite result.

## Deliverable

One `doubtfire-api` pull request containing:

- opt-in SimpleCov reporting with a documented `COVERAGE=true` command;
- removal of the redundant DatabaseCleaner transaction dependency and hooks;
- deterministic discovery and balanced assignment of all Rails test files;
- four isolated GitHub Actions test shards and one aggregate required check;
- cancellation of superseded runs and cache export limited to one shard per
  workflow run;
- correction of duplicate Ruby test-method definitions;
- targeted and structural test evidence; and
- a completed pull-request description.

## Acceptance criteria

- All 91 `test/**/*_test.rb` files are assigned exactly once across the four
  shards, with no missing, duplicate, or empty assignment.
- Normal test runs do not load SimpleCov.
- `COVERAGE=true bundle exec rails test` still generates a coverage report.
- Database state remains isolated using Rails' built-in transactions.
- No duplicate `ClassName#test_method` pair remains in the current
  `def test_*` inventory.
- The previously hidden extension-range scenario executes and passes.
- The Turnitin and PDF duplicate bodies are consolidated without losing unique
  assertions.
- All four service-backed pull-request shards and the aggregate `unit-tests`
  check pass.
- The measured pull-request critical path is recorded and is materially below
  the 30-plus-minute baseline, with a target of approximately 12–15 minutes.
- No production code, schema, authentication, permissions, student-data, or
  privacy behaviour changes.
- Reviewer evidence and the filled pull-request template are linked from the
  branch.

## Out of scope

- Production application performance work.
- Rails, Ruby, database, Docker-image, or service upgrades.
- Factory or fixture redesign beyond repairing the restored test's outdated
  tutorial-stream lookup.
- Removing integration tests or reducing assertion coverage.
- Broad renaming of unrelated test classes.
- Changes to `doubtfire-web` or `doubtfire-deploy`.

## Checklist

- [x] Review recent CI timings and identify the serial test phase as the bottleneck.
- [x] Confirm the complete API test-file inventory and isolation requirements.
- [x] Make SimpleCov opt-in and retain an explicit coverage command.
- [x] Remove the redundant DatabaseCleaner transaction layer.
- [x] Add deterministic four-way test sharding and workflow aggregation.
- [x] Resolve duplicate test-method definitions and repair the restored scenario.
- [x] Run the targeted extension/Turnitin tests and structural validation.
- [x] Add evidence and a filled pull-request description.
- [ ] Open the pull request into `11.0.x`.
- [ ] Record the four-shard CI result and final before/after timing.

## Evidence

- Evidence index: `docs/evidence/api-test-performance/README.md`
- Shard validation: `docs/evidence/api-test-performance/shard-validation.txt`
- Targeted tests: `docs/evidence/api-test-performance/targeted-test-results.txt`
- Coverage-mode result:
  `docs/evidence/api-test-performance/coverage-test-results.txt`
- Historical exploratory benchmark:
  `docs/evidence/api-test-performance/historical-benchmark.txt`
- Filled PR description: `docs/evidence/api-test-performance/pull-request.md`
- Representative baseline:
  https://github.com/doubtfire-lms/doubtfire-api/actions/runs/32479465525
- Branch and commit links: add after the branch is pushed.
- Pull-request and final CI links: add after the pull request is created.

## Completion chat update template

Use this after the pull request's four shard jobs pass.

API test performance and registration cleanup is ready for review.

Branch: `perf/faster-api-tests`

PR and CI evidence: add the links after opening the PR.

Measured critical path: `________` (slowest shard: `________`)

Normal tests no longer pay for coverage instrumentation, Rails now provides the
database rollback without a redundant DatabaseCleaner transaction, every Rails
test file is assigned exactly once across four isolated jobs, and the duplicate
Ruby test definitions have been corrected. Targeted verification passed 10
tests and 54 assertions with no failures or errors. No production behaviour or
database schema changed.
