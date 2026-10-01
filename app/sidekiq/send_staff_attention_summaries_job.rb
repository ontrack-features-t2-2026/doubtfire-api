# frozen_string_literal: true

# Staff summaries have their own explicit opt-in and never re-enable the older
# per-unit student summary job. One email covers the recipient's teaching units.
class SendStaffAttentionSummariesJob
  include Sidekiq::Job

  CADENCES = %w[daily weekly].freeze
  sidekiq_options queue: :mailers, retry: 2,
                  lock: :until_executed,
                  lock_args_method: ->(args) { ["staff-attention-#{args.first}"] },
                  on_conflict: :reject

  def perform(cadence = 'weekly')
    raise ArgumentError, 'Unknown staff summary cadence' unless CADENCES.include?(cadence)

    period = "#{DigestDeliveryGuard.period_for(cadence)}:staff"
    failures = []
    User.where(staff_digest_frequency: cadence).find_each do |user|
      user.reload
      next unless user.staff_digest_frequency == cadence

      summary = StaffAttentionService.new(user).call
      next if summary[:units].empty? || StaffAttentionService::COUNT_KEYS.all? { |key| summary[:totals][key].zero? }
      next unless DigestDeliveryGuard.claim(user, period)

      begin
        NotificationsMailer.staff_attention_summary(user, summary).deliver_now
      rescue StandardError => e
        DigestDeliveryGuard.release(user, period)
        failures << user.id
        Rails.logger.error "Staff attention summary failed for user #{user.id}: #{e.class}"
      end
    end
    raise "Staff attention summaries failed for users: #{failures.join(', ')}" if failures.any?
  end
end
