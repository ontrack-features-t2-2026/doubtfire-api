require 'test_helper'
require 'minitest/mock'

class NotificationServiceTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    NotificationEmailJob.clear
  end

  def test_notify_creates_a_notification_and_queues_one_id_only_email_job
    user = FactoryBot.create(:user)
    notification = nil

    assert_difference(
      -> { NotificationEmailJob.jobs.size },
      1
    ) do
      notification = NotificationService.notify(
        user: user,
        type: 'task',
        event: 'task_comment_created',
        message: 'Your tutor commented on your task.',
        link: "/projects/#{user.id}"
      )
    end

    assert notification.persisted?
    assert_equal 'task', notification.notification_type
    assert_equal 'task_comment_created', notification.event

    job = NotificationEmailJob.jobs.last
    assert_equal 'NotificationEmailJob', job['class']
    assert_equal 'default', job['queue']
    assert_equal [notification.id], job['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_notify_requires_an_event_keyword
    user = FactoryBot.create(:user)

    assert_raises ArgumentError do
      NotificationService.notify(user: user, type: 'general', message: 'No event given.')
    end
  end

  def test_blank_event_is_rejected
    user = FactoryBot.create(:user)

    assert_no_difference 'Notification.count' do
      assert_raises ActiveRecord::RecordInvalid do
        NotificationService.notify(user: user, type: 'general', event: '', message: 'Blank event.')
      end
    end

    assert_empty NotificationEmailJob.jobs
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_a_symbol_event_is_stored_as_a_string
    user = FactoryBot.create(:user)

    notification = NotificationService.notify(
      user: user, type: 'general', event: :task_comment_created, message: 'Symbol event.'
    )

    assert_equal 'task_comment_created', notification.event
  end

  def test_message_at_the_validated_maximum_survives_a_round_trip
    user = FactoryBot.create(:user)
    long_message = 'a' * 500

    notification = NotificationService.notify(
      user: user, type: 'general', event: 'long_message_check', message: long_message
    )

    # Fails before the message column became text: 500 characters passed
    # validation and were then truncated or rejected by VARCHAR(255).
    assert_equal 500, notification.reload.message.length
  end

  def test_notification_is_suppressed_when_the_category_preference_is_off
    user = FactoryBot.create(:user, receive_feedback_notifications: false)
    assert_no_difference 'Notification.count' do
      result = NotificationService.notify(
        user: user, type: 'feedback', event: 'task_comment_created', message: 'Suppressed.'
      )
      assert_nil result
    end

    assert_empty NotificationEmailJob.jobs
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_feedback_notification_is_queued_when_the_category_preference_is_on
    user = FactoryBot.create(:user, receive_feedback_notifications: true)
    notification = nil

    assert_difference(-> { NotificationEmailJob.jobs.size }, 1) do
      assert_difference 'Notification.count', 1 do
        notification = NotificationService.notify(
          user: user, type: 'feedback', event: 'feedback_available', message: 'Feedback available.'
        )

        assert notification.persisted?
      end
    end

    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_task_preference_gates_notifications_in_both_directions
    user = FactoryBot.create(:user, receive_task_notifications: true)
    notification = nil

    assert_difference(-> { NotificationEmailJob.jobs.size }, 1) do
      assert_difference 'Notification.count', 1 do
        notification = NotificationService.notify(
          user: user, type: 'task', event: 'task_due_date_changed', message: 'Task date changed.'
        )

        assert notification.persisted?
      end
    end
    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']

    user.update!(receive_task_notifications: false)

    assert_no_difference -> { NotificationEmailJob.jobs.size } do
      assert_no_difference 'Notification.count' do
        result = NotificationService.notify(
          user: user, type: 'task', event: 'task_due_date_changed', message: 'Suppressed task change.'
        )

        assert_nil result
      end
    end
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_portfolio_preference_gates_notifications_in_both_directions
    user = FactoryBot.create(:user, receive_portfolio_notifications: true)
    notification = nil

    assert_difference(-> { NotificationEmailJob.jobs.size }, 1) do
      assert_difference 'Notification.count', 1 do
        notification = NotificationService.notify(
          user: user, type: 'portfolio', event: 'portfolio_received', message: 'Portfolio received.'
        )

        assert notification.persisted?
      end
    end
    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']

    user.update!(receive_portfolio_notifications: false)

    assert_no_difference -> { NotificationEmailJob.jobs.size } do
      assert_no_difference 'Notification.count' do
        result = NotificationService.notify(
          user: user, type: 'portfolio', event: 'portfolio_received', message: 'Suppressed portfolio receipt.'
        )

        assert_nil result
      end
    end
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_types_without_a_preference_are_always_queued
    user = FactoryBot.create(
      :user,
      receive_task_notifications: false,
      receive_feedback_notifications: false,
      receive_portfolio_notifications: false
    )
    notification = nil

    assert_difference(
      -> { NotificationEmailJob.jobs.size },
      1
    ) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'always_sent', message: 'General notice.'
      )
    end

    assert notification.persisted?
    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_extension_notifications_are_always_queued
    user = FactoryBot.create(
      :user,
      receive_task_notifications: false,
      receive_feedback_notifications: false,
      receive_portfolio_notifications: false
    )
    notification = nil

    assert_difference(-> { NotificationEmailJob.jobs.size }, 1) do
      notification = NotificationService.notify(
        user: user, type: 'extension', event: 'extension_decided', message: 'Extension decision available.'
      )
    end

    assert notification.persisted?
    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_a_queue_failure_does_not_block_the_in_app_notification
    user = FactoryBot.create(:user)
    notification = nil

    NotificationEmailJob.stub(:perform_async, ->(_id) { raise 'redis unavailable' }) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'queue_failure_check', message: 'Still saved.'
      )

      assert notification.persisted?
    end

    assert_equal 0, NotificationEmailJob.jobs.size
    assert_equal 0, ActionMailer::Base.deliveries.count
    assert_nil notification.reload.delivered_at
  end

  def test_dedupe_key_delivers_only_once
    user = FactoryBot.create(:user)
    attributes = {
      user: user,
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:123'
    }

    assert_difference 'Notification.count', 1 do
      first = NotificationService.notify(**attributes)
      second = NotificationService.notify(**attributes)

      assert_equal first, second
      assert_not_nil first.delivered_at
    end

    assert_equal 1, NotificationEmailJob.jobs.size
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_failed_channel_delivery_is_retried_at_least_once
    user = FactoryBot.create(:user)
    attributes = {
      user: user,
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:456'
    }
    failure = ->(_notification) { raise StandardError, 'push interrupted' }

    PushNotificationService.stub(:deliver, failure) do
      assert_raises(StandardError) { NotificationService.notify(**attributes) }
    end

    notification = Notification.find_by!(dedupe_key: attributes[:dedupe_key])
    assert_nil notification.delivered_at
    assert_equal 1, NotificationEmailJob.jobs.size
    assert_equal 0, ActionMailer::Base.deliveries.count

    assert_no_difference 'Notification.count' do
      NotificationService.notify(**attributes)
    end

    assert_not_nil notification.reload.delivered_at
    assert_equal 2, NotificationEmailJob.jobs.size
    assert_equal 0, ActionMailer::Base.deliveries.count
  end
end
