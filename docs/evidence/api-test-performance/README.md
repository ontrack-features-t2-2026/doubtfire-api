# API test performance and registration evidence

Prepared on 23 August 2026 for one planned pull request from
`perf/faster-api-tests` into `11.0.x`.

## Scope

This evidence covers test-only and CI changes in `doubtfire-api`:

- make SimpleCov opt-in for normal test runs;
- rely on Rails' built-in transactional tests instead of a second
  DatabaseCleaner transaction;
- distribute all Rails test files across four isolated CI jobs;
- cancel superseded workflow runs and limit cache export to one shard per
  workflow run; and
- resolve duplicate Ruby test-method definitions found during the audit.

No production application code or database schema is changed.

## Baseline and historical exploratory benchmark

Recent successful API workflows spent roughly 28–31 minutes in the serial test
phase, with the complete job taking about 34–35 minutes. A representative public
baseline is [workflow run 32479465525][baseline-run], which took 33m17s overall
and 28m58s in the unit-test step.

A historical exploratory 53-test sample used the same seed and produced 1,813
assertions in all three configurations:

| Configuration | Test time | Wall time | Change from original test time |
| --- | ---: | ---: | ---: |
| SimpleCov and DatabaseCleaner | 240.16s | 246.78s | baseline |
| Coverage disabled | 187.26s | 213.12s | 22.0% faster |
| Coverage disabled and DatabaseCleaner removed | 183.31s | 201.91s | 23.7% faster |

The sample was run on `feature/cross-unit` at
`5064860967deca8fe61be774a42d913b4f95e66d`, not on this PR's `11.0.x`
base. It had zero assertion failures and the same two LaTeX service errors in
every configuration because no LaTeX service was provided. Treat it only as
directional evidence for where time was being spent; the exact commands, raw
results, environment, and limitations are recorded in
[historical-benchmark.txt](./historical-benchmark.txt).

## Test-file and shard validation

The final source tree contains 91 `test/**/*_test.rb` files. The shard runner's
own completeness check and an independent union/uniqueness check produced:

```text
91 discovered / 91 assigned / 91 unique
shard 1: 23 files, 6436 lines
shard 2: 23 files, 6434 lines
shard 3: 23 files, 6434 lines
shard 4: 22 files, 6433 lines
```

Every file is assigned exactly once, no shard is empty, repeated construction
is deterministic, and every test file continues to load `test_helper`. The
validation summary is in
[shard-validation.txt](./shard-validation.txt).

## Duplicate test-method correction

The audit found three duplicate-name groups that Ruby previously resolved by
silently keeping only the final definition:

- two distinct `test_extension_application` methods;
- two `test_similarity_webhook` methods, where the second was a strict
  superset of the first; and
- three byte-identical `test_code_submission_with_long_lines` methods.

The correction gives the two distinct extension scenarios unique names,
updates the newly restored scenario to use the current factory's tutorial
stream, keeps the more complete Turnitin webhook scenario, and keeps one copy
of the identical PDF scenario under a descriptive name.

A repository-wide scan now reports:

```text
No duplicate ClassName#test_method pairs across 706 def-style tests
```

The targeted extension and Turnitin test subset passed with the fixed seed
shown in
[targeted-test-results.txt](./targeted-test-results.txt):

```text
10 runs, 54 assertions, 0 failures, 0 errors, 0 skips
```

The surviving PDF test body is unchanged from the definition that Ruby already
registered before this correction; the full service-backed workflow remains
the release check for it.

## Additional validation

| Check | Result |
| --- | --- |
| Ruby syntax for the shard runner and affected test files | Passed |
| RuboCop on `script/test_shard.rb` | Passed, no offences |
| Actionlint on the modified `push.yml` | Passed |
| Bundler lockfile/dependency check in the Rails image | Passed |
| Invalid shard count, number, excessive count, and unknown option | Rejected with exit status 1 and clear messages |
| Repeated shard construction | Byte-identical output |
| `git diff --check` | Passed |
| Explicit coverage mode | 9 runs, 12 assertions, 0 failures, 0 errors; report generated ([raw result](./coverage-test-results.txt)) |

## Remaining pull-request evidence

The first pull-request workflow is the authoritative end-to-end result because
it supplies isolated MariaDB, Redis, LaTeX, JPlag, Docker, cache, and filesystem
state to every shard. The expected critical path is approximately 12–15
minutes, but that is a projection until the four real shard jobs finish.

Before merging:

1. confirm all four shard jobs pass;
2. confirm the aggregate `unit-tests` job passes;
3. record the actual overall and slowest-shard durations here or in the pull
   request; and
4. rerun any failed shard without weakening or skipping its tests.

## Reproduction commands

```bash
# Preview every assignment without loading Rails.
for shard in 1 2 3 4; do
  TEST_SHARD_COUNT=4 TEST_SHARD_NUMBER="$shard" \
    ruby script/test_shard.rb --dry-run
done

# Run the corrected database-backed tests.
bundle exec rails test \
  test/api/comments/extension_test.rb \
  test/api/tii/tii_hook_test.rb \
  --seed 12345

# Generate coverage only when it is needed.
COVERAGE=true bundle exec rails test
```

[baseline-run]: https://github.com/doubtfire-lms/doubtfire-api/actions/runs/32479465525
