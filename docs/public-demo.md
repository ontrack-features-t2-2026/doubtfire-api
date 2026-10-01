# Public synthetic demo bootstrap

This profile runs normal production APIs against made-up records. It is separate
from institutional deployment and from the guarded development-only
`all-features` walkthrough. It does not change either profile's safety rules.

The deployment must supply production secrets and these settings before Rails
boots:

```text
RAILS_ENV=production
DF_DEMO_DATA_PROFILE=public-demo
DF_AUTH_METHOD=database
DF_PRODUCTION_DB_DATABASE=doubtfire-public-demo
DF_INSTITUTION_HOST=https://ontrack.maplefox.au
DF_MAIL_DELIVERY_METHOD=smtp
DF_SMTP_ADDRESS=mailpit
DF_SMTP_PORT=1025
DF_SMTP_AUTHENTICATION=none
DF_TEAMS_ANNOUNCEMENTS_ENABLED=false
DF_STUDENT_WORK_DIR=/student-work
```

Both the configured and actually connected database must be
`doubtfire-public-demo`. Mailpit is the internal mail-capture service; it must not
forward mail. The bootstrap container shares the writable student-work volume
with the API and workers. Use the ordinary production worker, TexLive and JPlag
services for subsequent real submission-processing tests.

Before starting application writers, run:

```sh
bundle exec rake db:public_demo_prepare
bundle exec rake db:public_demo_verify
```

Preparation loads the checked-in schema only when the database has no tables or
views. It records a dedicated bootstrap marker in Rails internal metadata,
creates reference roles and task states without an administrator, then creates
the demo records and marks the bootstrap complete in one transaction. Existing
unmarked databases are refused before migration. A failed migration never falls
back to loading a schema. An interrupted preparation can retry its own empty
marked database, but cannot replace partially existing users or units.

After successful preparation, later runs migrate and report the existing demo.
They preserve changed profiles, new units, submissions and progress. The marker
is not accessible through the application API. Fresh creation verifies every
account's synthetic email and role; later verification checks the completed
marker and reports counts without rejecting legitimate visitor edits. There is
no automatic reset or deletion task.

All accounts start with password `password`:

| Account | Access |
| --- | --- |
| `student_1` | Complete sample lifecycle across five units, including a previous unit |
| `student_2` through `student_25` | Enrolled sample students and the privacy-safe peer cohort |
| `staff_1`, `staff_2` | Tutors assigned separate alternating-student tutorials |
| `chair_1` | Convenor of the sample units; not a global administrator |

Initial email addresses use `@example.invalid`. No `aadmin` or other administrator
is created. Email, push and summary preferences start off, and no push
subscriptions are created. A visitor can explicitly enable delivery preferences;
email still goes only to the internal Mailpit service.

The seed writes small valid synthetic PDFs, source downloads, feedback comments,
approved and pending extensions, overdue feedback, a help request, notifications,
groups, peer-progress snapshots, published Unit Hub announcements and recurring
HelpHubs. Calendar subscriptions use the regular account settings and secret feed
URL. The sample PDFs prove a readable initial state; a new upload still needs an
end-to-end worker/PDF conversion check. Production web builds do not require the
development Demo controls or the `/api/demo/scenario` fixture endpoint.
