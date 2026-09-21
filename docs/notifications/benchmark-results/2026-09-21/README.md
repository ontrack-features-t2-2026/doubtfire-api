# Isolated synthetic cohort results — 21 September 2026

The 500-user source is `e97a189abc5670deee3af05ab369d76bfc90159f`;
the 1,000-user source is `97592abc7ac2c796e8ab15564c6e78afd2c0492c` (abbreviated
in its JSON). Those revisions have identical runtime/harness Ruby; the second
adds only email acceptance documentation. API runtime is unchanged from PR #174's
`0fee2ba17b6e7640bcf87026ebc814366a9ad037`; the harness adds count/cleanup assertions
and synchronized sampling.
The runtime image supplied dependencies; the measured checkout was bind-mounted.
These are direct service/queue measurements, not HTTP or production capacity.

| Service | Image | Image ID | Container limit |
| --- | --- | --- | --- |
| API runner | `ontrack-unit-hub-release-preview-api:20260914` | `sha256:6bdb910b42135ceca88e4d1adf94e3050f4ebb759bdccb3080b6a0e80ba8fb60` | 2 CPUs / 1 GiB |
| Database | `mariadb:12.3` | `sha256:759869cb6f003234a95c6384cdee245b4bce7de26913fe607a8110362c0c007d` | 2 CPUs / 1 GiB |
| Redis | `redis:7.0` | `sha256:352c1fdadc91926edda08f45aeb3f27f37194c2f14101229c0523a11195c96e3` | 1 CPU / 256 MiB |

Docker Desktop exposed 10 CPUs and 8,321,515,520 bytes of memory. The VM and all
three container images were native arm64 (`aarch64`). Unrelated local
test containers shared that VM. Containers used a dedicated `--internal` network,
no host ports, a fresh MariaDB test database and a separate Redis instance (DB 1).
The network prevented external provider access; Rails mail transport was `test`
and push was stubbed in the process. No production secrets or data were used.

Set `BENCHMARK_IMAGE` to the local API test image above, then run from the measured
checkout. The names below are new disposable services; Docker refuses existing
names. Never substitute a real database into `db:schema:load`.

```sh
docker network create --internal notification-benchmark
docker run -d --name notification-benchmark-db --network notification-benchmark \
  --network-alias benchmark-db --cpus 2 --memory 1g \
  -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=notification_benchmark \
  --health-cmd='/usr/local/bin/healthcheck.sh --connect --innodb_initialized' \
  --health-interval=1s --health-retries=60 mariadb:12.3
docker run -d --name notification-benchmark-redis --network notification-benchmark \
  --network-alias benchmark-redis --cpus 1 --memory 256m \
  redis:7.0 redis-server --save '' --appendonly no
docker run -d --name notification-benchmark-app --network notification-benchmark \
  --cpus 2 --memory 1g -v "$PWD:/doubtfire" -w /doubtfire \
  -e RAILS_ENV=test -e BOOTSNAP_CACHE_DIR=/tmp/notification-benchmark-bootsnap \
  -e DF_TEST_DB_ADAPTER=mysql2 -e DF_TEST_DB_HOST=benchmark-db \
  -e DF_TEST_DB_DATABASE=notification_benchmark -e DF_TEST_DB_USERNAME=root \
  -e DF_TEST_DB_PASSWORD= -e DF_REDIS_SIDEKIQ_URL=redis://benchmark-redis:6379/1 \
  -e DF_STUDENT_WORK_DIR=/tmp/notification-benchmark-student-work \
  -e SKIP_OVERSEER_IMAGE_PULL_ON_POPULATE=true \
  --entrypoint sleep "$BENCHMARK_IMAGE" infinity
docker inspect --format '{{.State.Health.Status}}' notification-benchmark-db
# Wait until the database reports healthy before initialization.
docker exec notification-benchmark-app bundle exec rails db:schema:load db:init
mkdir -p benchmark-results
for cohort in 500 1000; do
  docker exec -e COHORT_SIZE="$cohort" -e OPT_OUT_PERCENT=20 \
    -e BENCHMARK_SOURCE_REVISION="$(git rev-parse HEAD)" \
    -e BENCHMARK_RESULT_PATH="/doubtfire/benchmark-results/cohort-$cohort.json" \
    notification-benchmark-app bundle exec rails runner script/benchmark_notifications.rb
done
```

The recorded run used these settings with containers
`remaining-api-benchmark-{app,db,redis}-20260921`, network
`remaining-api-benchmark-20260921` and database `remaining_api_benchmark_20260921`.
Each size runs in a fresh Rails process, fixed order (inline, queued, two-event
concurrent), no per-mode warm-up. Initialization, fixture creation, final count
verification and fixture cleanup are excluded from recorded timings. Sampling
overhead is included. Both queued modes drain jobs synchronously through one
local worker after enqueueing; this does not reproduce a fleet of Sidekiq workers
or provider latency. Queue/RSS peaks are sampled, not continuous high-water marks.
Default Rails test logging is included, with the checkout/log directory on the
host bind mount. Rails' test transport retains captured messages until each mode
ends, so this RSS includes test captures and is not production worker memory.

The inline comparison drains the same queues after each recipient; it does not
measure an older application release. The harness sets the per-recipient quota
to 100 and bypasses cohort admission; the configured cohort ceiling remains 500.
Each eligible recipient sees four synthetic events over the three modes. Results
contain no names, addresses, message bodies, credentials or subscription keys.

See [the capacity acceptance steps](../../cohort-load-testing.md#finish-institutional-capacity-acceptance-npr-t01)
for the institutional maximum, HTTP/provider/worker trials and SLO/saturation
inputs still required. Neither size establishes an approved production limit.
