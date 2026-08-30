# frozen_string_literal: true

class AdditionalNotificationEmailVerificationJob
  include Sidekiq::Job

  # Keep verification secrets and addresses out of Redis. The worker loads the
  # current record and creates its short-lived signed token only while rendering
  # the email. A version mismatch makes a queued replacement/resend job stale.
  sidekiq_options queue: :mailers, retry: 3

  def perform(additional_notification_email_id, verification_version)
    record = AdditionalNotificationEmail.find(additional_notification_email_id)
    return unless record.pending?
    return if record.verification_expired?
    return unless record.verification_version == verification_version

    AdditionalNotificationEmailMailer.verification(record).deliver_now
    AdditionalNotificationEmailService.audit_delivery_event(
      record.user,
      'verification_email_delivered'
    )
  end
end
