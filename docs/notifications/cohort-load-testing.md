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

## Local harness validation — 21 September 2026

A single smoke run completed with 40 synthetic recipients, 20% opted out, a
dedicated MariaDB 12.3 test database and Redis database 9. The API image was
`ontrack-unit-hub-release-preview-api:20260914` (Ruby 3.4.10, Rails 8.0.5.1).
The Docker VM exposed 10 CPUs and 7.75 GiB memory; the API container had no
additional CPU or memory limit. Other local test containers shared that VM.

| Mode | Simultaneous events | Trigger service (s) | Queue drain (s) | Total (s) | Sampled queue peak | Sampled RSS (KiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Inline baseline | 1 | 2.2752 | 0.0003 | 2.2755 | 2 | 317024 |
| Queued | 1 | 0.1893 | 0.3195 | 0.5088 | 64 | 317096 |
| Concurrent queued | 2 | 0.2697 | 0.5048 | 0.7745 | 128 | 322320 |

Both delivery queues were empty afterward and all synthetic users were removed.
This verifies that the harness runs through opt-outs, two external channels and
concurrent events. These are single samples in the displayed order without a
warm-up, so cold-start and cache effects differ between modes. The inline mode
drains after each recipient through the same queue adapters; it is a synchronous
comparison within this harness, not a measurement of a historical application
version. No email or push message left the test process. The institution's
largest enrolment was unavailable, and this run establishes neither a supported
cohort limit nor production latency, throughput or saturation.
