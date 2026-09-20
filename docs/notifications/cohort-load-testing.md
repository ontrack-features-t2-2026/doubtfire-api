# Cohort notification load testing

`script/benchmark_notifications.rb` provides a reproducible synthetic workload
against a real database and Redis queue. It seeds configurable synthetic users,
valid push subscription material, and a configurable opt-out mix, then compares
inline delivery with queued delivery and two concurrent events. Mail delivery
uses Rails' test transport; push delivery is stubbed at the provider boundary.
It records trigger-service time, queue drain time, total time, sampled queue
depth and Linux resident memory, and removes its synthetic users on completion.

```sh
RAILS_ENV=test COHORT_SIZE=100 OPT_OUT_PERCENT=20 \
  bundle exec rails runner script/benchmark_notifications.rb
```

Use a dedicated populated test database and empty dedicated Redis database
(number 1 or higher). Never run alongside other workers using those queues.
The harness refuses production and nonempty delivery queues. It intentionally
uses only synthetic transports and `.invalid` email addresses.

Set `COHORT_SIZE` to the actual largest enrolment supplied by the institution,
then repeat with headroom and increasing sizes (record that enrolment as
`LARGEST_UNIT_ENROLMENT`). Keep the output and hardware/worker configuration with
the PR. Identify the size where the agreed latency or memory budget fails.
Do not describe a small local run as proof of production capacity.

The trigger measurement starts at `NotificationService`, so it excludes HTTP,
authentication and event-specific database eligibility queries. Queue drain is
one local worker and provider latency is synthetic. Production acceptance still
requires HTTP timing, the actual largest enrolment, representative worker
concurrency, transport latency, delivery-rate constraints and a measured
saturation point. Those institutional measurements are not fabricated here.
