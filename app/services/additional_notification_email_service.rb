# frozen_string_literal: true

class AdditionalNotificationEmailService
  class InvalidToken < StandardError; end
  class AlreadyVerified < StandardError; end
  class RateLimited < StandardError; end

  VERIFICATION_LIFETIME = 24.hours
  RATE_LIMIT_WINDOW = 1.hour
  RATE_LIMIT_COUNT = 3

  def self.request(user:, email:)
    record = nil
    version = nil

    user.with_lock do
      enforce_rate_limit!(user)

      record = user.additional_notification_email || user.build_additional_notification_email
      replacement = record.persisted? && !record.email.to_s.casecmp?(email.to_s.strip)

      prepare_pending_record(record, email)
      record.save!

      audit!(user, 'address_replaced') if replacement
      audit!(user, 'verification_requested')
      version = record.verification_version
    end

    AdditionalNotificationEmailVerificationJob.perform_async(record.id, version)
    record
  end

  def self.resend(user:)
    record = nil
    version = nil

    user.with_lock do
      enforce_rate_limit!(user)
      record = user.additional_notification_email
      raise ActiveRecord::RecordNotFound if record.nil?
      raise AlreadyVerified if record.verified?

      prepare_pending_record(record, record.email)
      record.save!
      audit!(user, 'verification_resent')
      audit!(user, 'verification_requested')
      version = record.verification_version
    end

    AdditionalNotificationEmailVerificationJob.perform_async(record.id, version)
    record
  end

  def self.verify(token:)
    record = AdditionalNotificationEmail.record_for_token(token)
    raise InvalidToken if record.nil?

    record.with_lock do
      # with_lock reloads the row. Validate the signed version again so a
      # concurrent replacement/resend cannot make an earlier token verify the
      # newly written address between the first lookup and this lock.
      current_record = AdditionalNotificationEmail.record_for_token(token)
      raise InvalidToken unless current_record&.id == record.id
      raise AlreadyVerified if record.verified?
      raise InvalidToken if record.verification_expired?

      record.update!(verified_at: Time.current)
      audit!(record.user, 'verified')
    end

    record
  end

  def self.remove(user:)
    user.with_lock do
      record = user.additional_notification_email
      return false if record.nil?

      audit!(user, 'removed')
      record.destroy!
    end

    true
  end

  def self.audit!(user, event)
    user.additional_notification_email_audits.create!(event: event)
  end

  # Delivery has already happened (or failed) by the time these operational
  # audit events are written. An audit-store outage must not retry and
  # duplicate accepted mail, or mask the original SMTP failure.
  def self.audit_delivery_event(user, event)
    audit!(user, event)
  rescue StandardError => e
    Rails.logger.error(
      "Additional notification email audit failed for user_id=#{user.id} " \
      "event=#{event}: #{e.class}"
    )
    nil
  end

  def self.prepare_pending_record(record, email)
    record.assign_attributes(
      email: email,
      verified_at: nil,
      verification_version: record.verification_version.to_i + 1,
      verification_sent_at: Time.current,
      verification_expires_at: Time.current + VERIFICATION_LIFETIME
    )
  end
  private_class_method :prepare_pending_record

  def self.enforce_rate_limit!(user)
    count = user.additional_notification_email_audits
                .where(event: 'verification_requested')
                .where(created_at: RATE_LIMIT_WINDOW.ago..)
                .count
    raise RateLimited if count >= RATE_LIMIT_COUNT
  end
  private_class_method :enforce_rate_limit!
end
