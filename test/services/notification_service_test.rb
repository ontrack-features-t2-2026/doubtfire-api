require 'test_helper'
require 'minitest/mock'

class NotificationServiceTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    NotificationEmailJob.clear
    PushNotificationDeliveryJob.clear
  end
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

  def test_notify_queues_an_id_only_email_job
    user = FactoryBot.create(:user)
    notification = nil

    assert_difference(-> { NotificationEmailJob.jobs.size }, 1) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'general_notice', message: 'Queued email.'
      )
    end

    job = NotificationEmailJob.jobs.last
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

    assert_equal [notification.id], NotificationEmailJob.jobs.last['args']
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
  end

  def test_a_suppressed_notification_queues_no_email
    user = FactoryBot.create(:user, receive_feedback_notifications: false)

    NotificationService.notify(user: user, type: 'feedback', event: 'task_comment_created', message: 'Suppressed.')

    assert_empty NotificationEmailJob.jobs
  end

  def test_a_queue_failure_does_not_block_the_in_app_notification
    user = FactoryBot.create(:user)

    NotificationEmailJob.stub(:perform_async, ->(_id) { raise 'redis unavailable' }) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'queue_failure_check', message: 'Still saved.'
      )

      assert notification.persisted?
    end

    assert_empty NotificationEmailJob.jobs
  end

  def test_a_dedupe_key_queues_the_email_only_once
    user = FactoryBot.create(:user)
    attributes = {
      user: user,
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:321'
    }

    NotificationService.notify(**attributes)
    NotificationService.notify(**attributes)

    assert_equal 1, NotificationEmailJob.jobs.size
  end

  def test_notify_queues_an_id_only_push_job
    user = FactoryBot.create(:user)
    notification = nil

    assert_difference(-> { PushNotificationDeliveryJob.jobs.size }, 1) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'general_notice', message: 'Queued push.'
      )
    end

    job = PushNotificationDeliveryJob.jobs.last
    assert_equal 'notifications', job['queue']
    assert_equal [notification.id], job['args']
    assert_not_nil notification.reload.delivered_at
  end

  def test_a_suppressed_notification_queues_no_push
    user = FactoryBot.create(:user, receive_feedback_notifications: false)

    NotificationService.notify(user: user, type: 'feedback', event: 'task_comment_created', message: 'Suppressed.')

    assert_empty PushNotificationDeliveryJob.jobs
  end

  def test_an_email_queue_failure_still_hands_off_the_push
    user = FactoryBot.create(:user)
    notification = nil

    NotificationEmailJob.stub(:perform_async, ->(_id) { raise 'redis unavailable' }) do
      notification = NotificationService.notify(
        user: user, type: 'general', event: 'queue_failure_check', message: 'Still pushed.'
      )
    end

    assert_equal [notification.id], PushNotificationDeliveryJob.jobs.last['args']
    assert_not_nil notification.reload.delivered_at
  end

  def test_a_dedupe_key_hands_off_the_push_only_once
    user = FactoryBot.create(:user)
    attributes = {
      user: user,
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:654'
    }

    NotificationService.notify(**attributes)
    NotificationService.notify(**attributes)

    assert_equal 1, PushNotificationDeliveryJob.jobs.size
  end

  def test_a_failed_push_handoff_is_retried_without_a_second_email
    user = FactoryBot.create(:user)
    attributes = {
      user: user,
      type: 'task',
      event: 'new_task_available',
      message: 'A task is available.',
      dedupe_key: 'new_task_available:task-definition:456'
    }
    failure = ->(_notification_id) { raise StandardError, 'redis unavailable' }

    PushNotificationDeliveryJob.stub(:perform_async, failure) do
      NotificationService.notify(**attributes)
    end

    notification = Notification.find_by!(dedupe_key: attributes[:dedupe_key])
    assert_nil notification.delivered_at
    assert_equal 1, NotificationEmailJob.jobs.size
    assert_empty PushNotificationDeliveryJob.jobs

    assert_no_difference 'Notification.count' do
      NotificationService.notify(**attributes)
    end

    assert_not_nil notification.reload.delivered_at
    # The after-commit email belongs to the one created row. Retrying the failed
    # push hand-off must not queue a second email.
    assert_equal 1, NotificationEmailJob.jobs.size
    assert_equal [notification.id], PushNotificationDeliveryJob.jobs.last['args']
  end
end
