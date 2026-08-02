require 'test_helper'
require 'minitest/mock'

class NotificationServiceTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
  end

  def test_notify_creates_a_notification_and_sends_one_email
    user = FactoryBot.create(:user)

    notification = NotificationService.notify(
      user: user,
      type: 'task',
      event: 'task_comment_created',
      message: 'Your tutor commented on your task.',
      link: "/projects/#{user.id}"
    )

    assert notification.persisted?
    assert_equal 'task', notification.notification_type
    assert_equal 'task_comment_created', notification.event

    # deliver_now, so the mail is in deliveries immediately without any queue
    # being drained. This is what breaks if someone puts deliver_later back.
    assert_equal 1, ActionMailer::Base.deliveries.count
    assert_equal [user.email], ActionMailer::Base.deliveries.last.to
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

    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_types_without_a_preference_are_always_delivered
    user = FactoryBot.create(:user, receive_task_notifications: false, receive_feedback_notifications: false, receive_portfolio_notifications: false)

    notification = NotificationService.notify(
      user: user, type: 'general', event: 'always_sent', message: 'General notice.'
    )

    assert notification.persisted?
    assert_equal 1, ActionMailer::Base.deliveries.count
  end

  def test_a_mail_failure_does_not_block_the_in_app_notification
    user = FactoryBot.create(:user)

    NotificationsMailer.stub :single_notification, ->(_n) { raise StandardError, 'smtp exploded' } do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'mail_failure_check', message: 'Still saved.'
      )

      assert notification.persisted?
    end

    assert_equal 0, ActionMailer::Base.deliveries.count
  end
end
