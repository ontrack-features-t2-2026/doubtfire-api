require 'test_helper'

class NotificationServiceTest < ActiveSupport::TestCase
  def test_notify_creates_a_notification
    user = FactoryBot.create(:user)

    notification = NotificationService.notify(
      user: user,
      type: 'task',
      event: 'task_comment_created',
      message: 'Your tutor commented on your task.',
      link: "/projects/#{user.id}"
    )

    assert notification.persisted?
    assert_equal user, notification.user
    assert_equal 'task', notification.notification_type
    assert_equal 'task_comment_created', notification.event
    assert_equal "/projects/#{user.id}", notification.link
  end

  def test_notify_records_what_the_notification_is_about
    project = FactoryBot.create(:project)
    task = project.task_for_task_definition(project.unit.task_definitions.first)

    notification = NotificationService.notify(
      user: project.student, type: 'task', event: 'task_status_changed', message: 'Status changed.', notifiable: task
    )

    assert_equal task, notification.reload.notifiable
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
  end

  def test_feedback_notification_is_created_when_the_category_preference_is_on
    user = FactoryBot.create(:user, receive_feedback_notifications: true)

    assert_difference 'Notification.count', 1 do
      notification = NotificationService.notify(
        user: user, type: 'feedback', event: 'feedback_available', message: 'Feedback available.'
      )

      assert notification.persisted?
    end
  end

  def test_task_preference_gates_notifications_in_both_directions
    user = FactoryBot.create(:user, receive_task_notifications: true)

    assert_difference 'Notification.count', 1 do
      NotificationService.notify(
        user: user, type: 'task', event: 'task_due_date_changed', message: 'Task date changed.'
      )
    end

    user.update!(receive_task_notifications: false)

    assert_no_difference 'Notification.count' do
      result = NotificationService.notify(
        user: user, type: 'task', event: 'task_due_date_changed', message: 'Suppressed task change.'
      )

      assert_nil result
    end
  end

  def test_portfolio_preference_gates_notifications_in_both_directions
    user = FactoryBot.create(:user, receive_portfolio_notifications: true)

    assert_difference 'Notification.count', 1 do
      NotificationService.notify(
        user: user, type: 'portfolio', event: 'portfolio_received', message: 'Portfolio received.'
      )
    end

    user.update!(receive_portfolio_notifications: false)

    assert_no_difference 'Notification.count' do
      result = NotificationService.notify(
        user: user, type: 'portfolio', event: 'portfolio_received', message: 'Suppressed portfolio receipt.'
      )

      assert_nil result
    end
  end

  def test_types_without_a_preference_are_always_created
    user = FactoryBot.create(
      :user,
      receive_task_notifications: false,
      receive_feedback_notifications: false,
      receive_portfolio_notifications: false
    )

    %w[general extension].each do |type|
      notification = NotificationService.notify(
        user: user, type: type, event: "#{type}_notice", message: 'Always sent.'
      )

      assert notification.persisted?, "#{type} was suppressed"
    end
  end

  def test_a_dedupe_key_creates_the_notification_only_once
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
    end
  end

  def test_the_same_dedupe_key_is_independent_per_user
    attributes = {
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:789'
    }

    assert_difference 'Notification.count', 2 do
      NotificationService.notify(user: FactoryBot.create(:user), **attributes)
      NotificationService.notify(user: FactoryBot.create(:user), **attributes)
    end
  end
end
