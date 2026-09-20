# frozen_string_literal: true

require 'test_helper'
require 'timeout'

class NotificationDeliveryPolicyConcurrencyTest < ActiveSupport::TestCase
  # Each producer must commit on its own connection, as real request/job
  # transactions do. A fixture transaction would hide the recipient from them.
  self.use_transactional_tests = false

  setup do
    skip 'Requires MySQL/MariaDB repeatable-read transactions' unless ActiveRecord::Base.connection.adapter_name == 'Mysql2'

    @previous_limits = %w[
      DOUBTFIRE_NOTIFICATION_RECIPIENT_LIMIT
      DOUBTFIRE_NOTIFICATION_RECIPIENT_WINDOW_SECONDS
    ].index_with { |name| ENV.fetch(name, nil) }
    ENV['DOUBTFIRE_NOTIFICATION_RECIPIENT_LIMIT'] = '1'
    ENV['DOUBTFIRE_NOTIFICATION_RECIPIENT_WINDOW_SECONDS'] = '3600'

    nonce = SecureRandom.hex(8)
    @recipient = FactoryBot.create(:user, username: "quota-race-#{nonce}",
                                          email: "quota-race-#{nonce}@example.invalid")
    NotificationEmailJob.clear
    PushNotificationDeliveryJob.clear
  end

  teardown do
    @recipient&.destroy!
    @previous_limits&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def test_outer_transaction_snapshot_cannot_hide_a_committed_quota_reservation
    first, second = reserve_after_older_snapshot

    assert_equal 0, @snapshot_notification_count
    assert_equal 'pending', first.reload.email_delivery_state
    assert_equal 'throttled', second.reload.email_delivery_state
    assert_equal 2, Notification.where(user_id: @recipient.id).count
    assert_equal([[first.id]], NotificationEmailJob.jobs.map { |job| job['args'] })
    assert_equal([[first.id]], PushNotificationDeliveryJob.jobs.map { |job| job['args'] })
  end

  def test_duplicate_lookup_sees_the_winner_despite_an_older_transaction_snapshot
    first, second = reserve_after_older_snapshot(dedupe_key: 'concurrent-event')

    assert_equal 0, @snapshot_notification_count
    assert_equal first.id, second.id
    assert_equal 'pending', second.reload.email_delivery_state
    assert_equal 1, Notification.where(user_id: @recipient.id).count
    assert_equal([[first.id]], NotificationEmailJob.jobs.map { |job| job['args'] })
    assert_equal([[first.id]], PushNotificationDeliveryJob.jobs.map { |job| job['args'] })
  end

  private

  def reserve_after_older_snapshot(dedupe_key: nil)
    snapshot_established = Queue.new
    first_reservation_committed = Queue.new
    producers = []

    producers << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Timeout.timeout(15) { snapshot_established.pop }
        notification = raise_notification('first_reservation', dedupe_key)
        # notify has returned from its transaction, so the first row and both
        # channel hand-offs exist before the older transaction resumes.
        first_reservation_committed << true
        notification
      end
    end

    producers << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(isolation: :repeatable_read) do
          # An ordinary read in a surrounding workflow (for example the
          # project's eligibility reload) establishes this same older snapshot.
          @snapshot_notification_count = Notification.where(user_id: @recipient.id).count
          snapshot_established << true
          Timeout.timeout(15) { first_reservation_committed.pop }
          raise_notification('second_reservation', dedupe_key)
        end
      end
    end

    Timeout.timeout(20) { producers.map(&:value) }
  ensure
    producers&.each { |producer| producer.kill if producer.alive? }
    producers&.each(&:join)
  end

  def raise_notification(event, dedupe_key)
    NotificationService.notify(user: User.find(@recipient.id), type: 'general', event: event,
                               message: 'Concurrent quota regression', dedupe_key: dedupe_key)
  end
end
