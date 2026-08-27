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
    assert_equal 'mailers', job['queue']
    assert_equal [notification.id], job['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_email_is_not_queued_until_the_creating_transaction_commits
    user = FactoryBot.create(:user)
    notification = nil

    ActiveRecord::Base.transaction do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'group_membership_changed', message: 'In a transaction.'
      )

      assert notification.persisted?
      # A worker picking the job up here could not see the row yet, so nothing
      # may be queued before the transaction commits.
      assert_empty NotificationEmailJob.jobs
    end

    assert_equal 1, NotificationEmailJob.jobs.size
    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_a_rolled_back_transaction_queues_no_email
    user = FactoryBot.create(:user)

    ActiveRecord::Base.transaction do
      NotificationService.notify(
        user: user, type: 'general', event: 'rolled_back_event', message: 'Never happened.'
      )
      raise ActiveRecord::Rollback
    end

    assert_equal 0, Notification.where(event: 'rolled_back_event').count
    assert_empty NotificationEmailJob.jobs
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

  def test_a_queue_failure_does_not_block_the_in_app_notification
    user = FactoryBot.create(:user)

    NotificationEmailJob.stub(:perform_async, ->(_id) { raise 'redis unavailable' }) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'queue_failure_check', message: 'Still saved.'
      )

      assert notification.persisted?
    end

    assert_equal 0, NotificationEmailJob.jobs.size
    assert_equal 0, ActionMailer::Base.deliveries.count
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

    # Email is queued by Notification's after_commit hook, on create. The second
    # notify returns the existing row rather than creating one, so it queues
    # nothing and the unique index is what makes the email single, not
    # delivered_at.
    assert_equal 1, NotificationEmailJob.jobs.size
    NotificationEmailJob.drain
    assert_equal 1, ActionMailer::Base.deliveries.count
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

    assert_no_difference 'Notification.count' do
      NotificationService.notify(**attributes)
    end

    assert_not_nil notification.reload.delivered_at
    # Still exactly one email. The retry re-delivers the push channel only,
    # because the row already existed so no second after_commit ran. A failed
    # push must not put a duplicate email in the student's inbox.
    assert_equal 1, NotificationEmailJob.jobs.size
    NotificationEmailJob.drain
    assert_equal 1, ActionMailer::Base.deliveries.count
  end
end
