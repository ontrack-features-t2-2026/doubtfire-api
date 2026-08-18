# Student Peer Progress API

## Route

`GET /api/projects/:id/task_def_id/:task_definition_id/peer_progress`

The route is restricted to the authenticated student who owns the enrolled project.
The unit and target grade are derived from that project. The route does not accept a
student ID, unit ID, trimester, cohort, or target grade from the browser.

## Response fields

## Successful response contract

All authorised business states return HTTP 200 with exactly the following
fields. The API uses snake_case. PPI-F01 maps these fields to the frontend
camelCase interface.

| Field | Type | Nullable | Meaning |
| --- | --- | --- | --- |
| `task_definition_id` | Integer | No | Requested task definition |
| `unit_id` | Integer | No | Unit derived from the authenticated student's project |
| `target_grade` | Integer | Yes | Valid server-side target grade, or `null` when none is valid |
| `submitted_percentage` | Number | Yes | Value from 0.0 to 100.0, or `null` when the value must not be displayed |
| `is_suppressed` | Boolean | No | True when the cohort is below the privacy threshold |
| `is_stale` | Boolean | No | True when the stored snapshot is older than the approved freshness window |
| `is_feature_enabled` | Boolean | No | Whether the unit has enabled PPI |
| `last_updated_at` | String | Yes | UTC ISO 8601 snapshot time, or `null` when no snapshot was used |
| `unavailable_message` | String | No | Empty on success; otherwise a neutral and privacy-safe message |

A genuine zero is returned as `0.0`. It is not treated as missing data.

Student-facing percentages are quantised to the nearest five percentage points. The precise stored aggregate is not returned by this API.

`submitted_percentage` must be `null` for suppressed, stale, disabled and
unavailable states. The response never includes raw cohort size or submitted
count.

## State behaviour

| State | Percentage | Suppressed | Stale | Enabled | Last updated |
| --- | --- | --- | --- | --- | --- |
| Normal | Number | False | False | True | Timestamp |
| Genuine zero | `0.0` | False | False | True | Timestamp |
| Empty or small cohort, fresh | `null` | True | False | True | Timestamp |
| Empty or small cohort, stale | `null` | True | True | True | Timestamp |
| Stale snapshot | `null` | False | True | True | Timestamp |
| No snapshot | `null` | False | False | True | `null` |
| No valid target grade | `null` | False | False | True | `null` |
| Feature disabled | `null` | False | False | False | `null` |

### Normal
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": 65.0,
  "is_suppressed": false,
  "is_stale": false,
  "is_feature_enabled": true,
  "last_updated_at": "2026-08-10T03:15:00Z",
  "unavailable_message": ""
}
```

### Genuine zero
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": 0.0,
  "is_suppressed": false,
  "is_stale": false,
  "is_feature_enabled": true,
  "last_updated_at": "2026-08-10T03:15:00Z",
  "unavailable_message": ""
}
```

### Small-cohort suppression
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": null,
  "is_suppressed": true,
  "is_stale": false,
  "is_feature_enabled": true,
  "last_updated_at": "2026-08-10T03:15:00Z",
  "unavailable_message": "Peer progress is currently unavailable."
}
```

### Stale data
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": null,
  "is_suppressed": false,
  "is_stale": true,
  "is_feature_enabled": true,
  "last_updated_at": "2026-08-07T03:15:00Z",
  "unavailable_message": "Peer progress is currently unavailable."
}
```

### No valid target grade
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": null,
  "submitted_percentage": null,
  "is_suppressed": false,
  "is_stale": false,
  "is_feature_enabled": true,
  "last_updated_at": null,
  "unavailable_message": "Peer progress is currently unavailable."
}
```


### No snapshot for a valid target grade
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": null,
  "is_suppressed": false,
  "is_stale": false,
  "is_feature_enabled": true,
  "last_updated_at": null,
  "unavailable_message": "Peer progress is currently unavailable."
}
```

### Disabled
``` json
{
  "task_definition_id": 12,
  "unit_id": 5,
  "target_grade": 2,
  "submitted_percentage": null,
  "is_suppressed": false,
  "is_stale": false,
  "is_feature_enabled": false,
  "last_updated_at": null,
  "unavailable_message": "Peer progress is currently unavailable."
}
```

## Error responses

Business states such as suppressed, stale, disabled and missing data return the
normal nine-field HTTP 200 response.

Access-control and technical failures use a separate error response:

```json
{
  "error": "Safe error message"
}
```
- `404`: the student cannot safely access the requested project or task.
- `419`: authentication failed through the existing OnTrack authentication flow.
- `503`: required PPI configuration is missing or invalid.

## Privacy boundary

The response must not include names, usernames, student IDs, peer project IDs,
marks, feedback, individual task statuses, submitted counts, or raw cohort sizes.
The endpoint reads `cohort_size` only to apply suppression.

An empty cohort and any cohort below the configured privacy threshold return the same suppressed state. A suppressed snapshot can also be stale, so `is_suppressed` and `is_stale` may both be `true`.


## Target-grade change protection

Each project records `target_grade_changed_at`. The API does not return a
snapshot calculated before the current target-grade selection. After a target
grade change, peer progress remains unavailable until a newer aggregation run
creates a snapshot for that grade.

## Configuration

- `DF_PPI_MINIMUM_COHORT_SIZE`: approved minimum cohort size.
- `DF_PPI_STALE_AFTER_HOURS`: approved maximum snapshot age.

`DF_PPI_STALE_AFTER_HOURS` must be a positive integer. `DF_PPI_MINIMUM_COHORT_SIZE` must be an integer of at least `5`. No production defaults are included. An enabled unit
with a valid snapshot fails closed with HTTP 503 when either value is missing or invalid.

## Feature enablement

`units.peer_progress_enabled` defaults to `false`. Enable it for a test unit only after
privacy thresholds and the endpoint have been reviewed.

## Status behaviour

Malformed integer path parameters may return HTTP 400 from Grape before the project or task lookup.

- `200`: authorised request, including normal, zero, suppressed, stale, disabled, or unavailable state.
- `404`: wrong user, project, unit, task, target-grade applicability, inactive unit, or unreleased task. The same message is used to reduce object enumeration.
- `419`: OnTrack authentication failed.
- `503`: required PPI configuration is missing or invalid.

## Handover

The background job creates the snapshots. This endpoint only authorises the student,
selects the correct stored snapshot, applies display suppression and freshness rules,
and returns an allowlisted response. Frontend HTTP mapping remains in PPI-F01.
