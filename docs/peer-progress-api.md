# Student Peer Progress API

## Route

`GET /api/projects/:id/task_def_id/:task_definition_id/peer_progress`

The route is restricted to the authenticated student who owns the enrolled project.
The unit and target grade are derived from that project. The route does not accept a
student ID, unit ID, trimester, cohort, or target grade from the browser.

## Response fields

- `task_definition_id`
- `unit_id`
- `target_grade`
- `submitted_percentage`
- `is_suppressed`
- `is_stale`
- `is_feature_enabled`
- `last_updated_at`
- `unavailable_message`

`submitted_percentage` is `null` for suppressed, stale, disabled, and unavailable
states. A genuine zero is returned as `0.0`.

## Privacy boundary

The response must not include names, usernames, student IDs, peer project IDs,
marks, feedback, individual task statuses, submitted counts, or raw cohort sizes.
The endpoint reads `cohort_size` only to apply suppression.

## Configuration

- `DF_PPI_MINIMUM_COHORT_SIZE`: approved minimum cohort size.
- `DF_PPI_STALE_AFTER_HOURS`: approved maximum snapshot age.

Both must be positive integers. No production defaults are included. An enabled unit
with a valid snapshot fails closed with HTTP 503 when either value is missing or invalid.

## Feature enablement

`units.peer_progress_enabled` defaults to `false`. Enable it for a test unit only after
privacy thresholds and the endpoint have been reviewed.

## Status behaviour

- `200`: authorised request, including normal, zero, suppressed, stale, disabled, or unavailable state.
- `404`: wrong user, project, unit, task, target-grade applicability, inactive unit, or unreleased task. The same message is used to reduce object enumeration.
- `419`: OnTrack authentication failed.
- `503`: required PPI configuration is missing or invalid.

## Handover

The background job creates the snapshots. This endpoint only authorises the student,
selects the correct stored snapshot, applies display suppression and freshness rules,
and returns an allowlisted response. Frontend HTTP mapping remains in PPI-F01.
