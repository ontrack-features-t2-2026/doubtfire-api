# Email delivery acceptance (NPR-Q01)

The repository verifies queuing, preferences, retries and persisted SMTP outcomes.
Closing production deliverability acceptance additionally requires an authorized
operator, the deployed mail provider and an institution-controlled test inbox.
No real email was sent for the local synthetic benchmark or this procedure.

## Find the deployment and owners

The deployment owner obtains the target URL, image/source revisions and runtime
configuration from the institution's hosting inventory and deployment records.
Use a private staging installation with production configuration first. Record
the application/deployment owner, SMTP provider administrator and mail/DNS owner
in the private operations directory. The repository does not identify those
people, a staging URL or an approved inbox; a student contributor need not guess
them. The provider administrator can identify the authenticated SMTP service,
verified sender/domain, DKIM selectors, rate limits and delivery-report access.

Have the institution provision an ordinary test user whose **primary** email is
the controlled inbox. The operator records its numeric user ID privately. Keep
its feedback preference enabled and give it no verified additional email, so
the trial has exactly one destination. Do not repoint an actual student's email.

Run commands below inside the chosen API release container, with its existing
runtime secrets injected. Do not paste credentials or complete environment dumps
into shell history, issues or PRs. These are operator commands, not commands run
as part of writing this document.

## Check configuration without sending

```sh
bundle exec rails runner - <<'RUBY'
settings = ActionMailer::Base.smtp_settings
puts({
  rails_environment: Rails.env,
  perform_deliveries: NotificationsMailer.perform_deliveries,
  delivery_method: NotificationsMailer.delivery_method,
  smtp_address: settings[:address], smtp_port: settings[:port],
  smtp_domain: settings[:domain], authentication: settings[:authentication],
  starttls_auto: settings[:enable_starttls_auto],
  username_configured: settings[:user_name].present?,
  password_configured: settings[:password].present?,
  sender: Doubtfire::Application.config.institution[:email_sender]
}.to_json)
RUBY
bundle exec rake notifications:delivery_counts
```

Production SMTP should have deliveries enabled, method `smtp`, the provider's
approved host/port/TLS/auth settings and a verified institutional sender.
Relevant variables are `DF_MAIL_PERFORM_DELIVERIES=yes`,
`DF_MAIL_DELIVERY_METHOD=smtp`, `DF_SMTP_ADDRESS`, `DF_SMTP_PORT`, `DF_SMTP_DOMAIN`,
`DF_SMTP_USERNAME`, `DF_SMTP_PASSWORD`, `DF_SMTP_AUTHENTICATION`,
`DF_SMTP_ENABLE_STARTTLS_AUTO` and `DF_INSTITUTION_EMAIL_SENDER`. Compare the safe
output privately with the provider settings; never print the SMTP settings hash.

Use `RAILS_ENV=production` in the isolated acceptance installation when validating
production sender headers. Although Rails' `staging` environment loads production
SMTP configuration, `ApplicationMailer` chooses the institutional From header
only when `Rails.env.production?` is true. Do not change the environment of an
unrelated running installation just to perform this test.

Confirm the deployed Sidekiq process consumes `mailers`; inspect its startup
command/configuration and the [queue checks](RUNBOOK.md). The normal production
worker reads `config/sidekiq.yml`; command-line `-q` flags can override that list.

## Send one approved email, then verify every boundary

Only the authorized operator executes this step after verifying the intended
environment and inbox. Set `TEST_USER_ID` to that account and `ACCEPTANCE_TAG` to
a unique, non-personal trial identifier in the operator session. Retain the tag
if retrying the command: the dedupe key prevents creating another event.

```sh
bundle exec rails runner - <<'RUBY'
abort 'Use the designated production-mode acceptance installation' unless Rails.env.production?
abort 'SMTP deliveries must be enabled' unless NotificationsMailer.perform_deliveries && NotificationsMailer.delivery_method == :smtp
user = User.find(Integer(ENV.fetch('TEST_USER_ID'), 10))
abort 'Test user must permit feedback notifications' unless user.receive_feedback_notifications
abort 'Use an account without a verified additional email' if user.additional_notification_email&.verified?
tag = ENV.fetch('ACCEPTANCE_TAG')
abort 'Use a short, non-personal trial tag' unless tag.match?(/\A[a-zA-Z0-9_-]{1,80}\z/)
notification = NotificationService.reserve(
  user: user, type: 'feedback', event: 'operator_email_acceptance',
  message: 'Synthetic email delivery verification', link: '/notifications',
  dedupe_key: "operator_email_acceptance:#{tag}:#{user.id}"
)
abort 'Notification was suppressed by the current preference' unless notification
puts({ notification_id: notification.id, email_delivery_state: notification.reload.email_delivery_state }.to_json)
RUBY
```

`reserve` creates the in-app row and queues email after commit. This procedure
does not call `deliver`, so it does not queue push. If the result is `throttled`,
wait for the account's quota window or choose a fresh approved test account;
do not bypass the recipient quota. Record the resulting notification ID.

Set `NOTIFICATION_ID` to that ID and inspect only its non-content audit fields:

```sh
bundle exec rails runner - <<'RUBY'
n = Notification.find(Integer(ENV.fetch('NOTIFICATION_ID'), 10))
puts n.attributes.slice('id', 'email_delivery_state', 'email_delivery_attempts',
                        'email_delivered_at', 'email_delivery_error_class').to_json
RUBY
```

In the controlled user's browser, confirm the same event appears at
`GET /api/notifications` and contributes to `GET /api/notifications/unread_count`.
The normal signed-in client supplies `Username` and `Auth-Token` headers; do not
put tokens in URLs or screenshots. There is no public notification-create API.

Then inspect the provider's delivery report and the actual inbox/spam folder.
Record the UTC timestamps, provider message identifier, SMTP acceptance, provider
delivery/bounce status and mailbox placement. `email_delivery_state=delivered`
means the SMTP call succeeded; it does not mean inbox arrival. This application
does not persist a provider message identifier or consume later bounce reports.
The operator correlates the trial's time, controlled recipient and message in
the provider console, storing raw headers privately. For Azure Communication
Services, use its documented [delivery reports](https://learn.microsoft.com/en-us/azure/event-grid/communication-services-email-events).

For an actual failure, diagnose the cause using [delivery operations](delivery-operations.md#email-outcomes-and-retry).
After the cause is corrected, the existing command below requeues only a
`failed` or `queue_failed` notification and **will send email** through the worker:

```sh
bundle exec rake notifications:retry_email
```

It uses the `NOTIFICATION_ID` already set above. Do not replay a delivered row or
an entire cohort. A provider's approved test-recipient/sandbox facility may be
used for a controlled rejection/bounce trial; do not send to a guessed address.

## Check domain authentication and record acceptance

The provider/mail owner supplies the envelope sender domain, DKIM signing domain
and selector, and visible From domain. These can differ; do not infer them from
`DF_SMTP_DOMAIN` (the SMTP HELO domain). Query their published records read-only:

```sh
dig +short TXT "$ENVELOPE_SENDER_DOMAIN"
dig +short CNAME "$DKIM_SELECTOR._domainkey.$DKIM_SIGNING_DOMAIN"
dig +short TXT "$DKIM_SELECTOR._domainkey.$DKIM_SIGNING_DOMAIN"
dig +short TXT "_dmarc.$FROM_DOMAIN"
```

The mail/DNS owner checks the received message's `Authentication-Results` for
SPF, DKIM and DMARC, including alignment to the visible From domain. A DNS record
existing is insufficient evidence of successful authentication or inbox delivery.
Use the provider's [sender authentication guidance](https://learn.microsoft.com/en-us/azure/communication-services/concepts/email/email-domain-and-sender-authentication)
when Azure Communication Services is the configured provider. DNS changes belong
to the institution's DNS owner and its change process.

Keep this evidence table in the private acceptance record; publish only a
redacted result and its approved evidence reference with the ticket:

| Required evidence | Operator records |
| --- | --- |
| Tested deployment | Environment/URL, API/web/deploy revisions, UTC date |
| Ownership | Application, SMTP provider and mail/DNS contacts |
| Controlled trial | Trial tag, user/notification IDs, approved inbox reference |
| Application and provider | State/attempts, provider message ID/status, inbox or spam result |
| Authentication | Verified sender, SPF/DKIM/DMARC results and alignment |
| Failure handling | Controlled rejection/bounce result, or explicit unexercised case and owner |
| Acceptance | Defects/actions, evidence location, operator and institutional reviewer sign-off |

NPR-Q01 remains awaiting institutional acceptance until this evidence exists.
A green unit test, synthetic transport or SMTP acceptance alone cannot close it.
