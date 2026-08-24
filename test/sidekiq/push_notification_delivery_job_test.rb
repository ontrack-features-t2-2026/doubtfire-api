# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class PushNotificationDeliveryJobTest < ActiveSupport::TestCase
  setup do
    PushNotificationDeliveryJob.clear
  end

  def test_perform_delivers_the_reloaded_notification
    notification = FactoryBot.create(:notification, event: 'general')
    delivered = nil

    PushNotificationService.stub(:deliver, ->(record) { delivered = record }) do
      PushNotificationDeliveryJob.new.perform(notification.id)
    end

    assert_equal notification, delivered
  end

  def test_missing_notification_is_a_no_op
    calls = 0

    PushNotificationService.stub(:deliver, ->(_record) { calls += 1 }) do
      PushNotificationDeliveryJob.new.perform(-1)
    end

    assert_equal 0, calls
  end

  def test_delivery_failure_is_raised_so_sidekiq_can_retry
    notification = FactoryBot.create(:notification, event: 'general')
    failure = ->(_record) { raise 'push provider unavailable' }

    PushNotificationService.stub(:deliver, failure) do
      error = assert_raises(RuntimeError) do
        PushNotificationDeliveryJob.new.perform(notification.id)
      end
      assert_equal 'push provider unavailable', error.message
    end
  end

  def test_async_payload_contains_only_the_notification_id
    notification = FactoryBot.create(:notification, event: 'general')
    jid = PushNotificationDeliveryJob.perform_async(notification.id)
    job = PushNotificationDeliveryJob.jobs.find do |candidate|
      candidate['jid'] == jid
    end

    assert_not_nil job
    assert_equal 'PushNotificationDeliveryJob', job['class']
    assert_equal 'default', job['queue']
    assert_equal [notification.id], job['args']
    assert_equal 3, PushNotificationDeliveryJob.get_sidekiq_options['retry']
  end
end
