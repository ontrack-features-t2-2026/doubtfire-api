require 'test_helper'

class NotificationTest < ActiveSupport::TestCase
  def test_the_factory_builds_a_valid_notification_for_every_category
    Notification::TYPES.each do |type|
      notification = FactoryBot.create(:notification, type.to_sym)

      assert notification.persisted?, "a #{type} notification did not save"
      assert_equal type, notification.notification_type
      assert_equal "#{type}_event", notification.event
      assert notification.message.present?
    end
  end

  def test_an_unread_notification_is_in_the_unread_scope
    notification = FactoryBot.create(:notification, :unread)

    assert_nil notification.read_at
    assert_not notification.read?
    assert_includes Notification.unread, notification
  end

  def test_a_read_notification_is_out_of_the_unread_scope
    notification = FactoryBot.create(:notification, :read)

    assert_not_nil notification.read_at
    assert notification.read?
    assert_not_includes Notification.unread, notification
  end

  def test_mark_read_keeps_the_first_read_time
    notification = FactoryBot.create(:notification, :unread)

    travel_to Time.zone.parse('2026-09-01 10:00:00') do
      notification.mark_read!
    end
    first_read_at = notification.reload.read_at

    travel_to Time.zone.parse('2026-09-02 10:00:00') do
      notification.mark_read!
    end

    assert_equal first_read_at, notification.reload.read_at
  end

  def test_an_unknown_category_is_rejected
    notification = FactoryBot.build(:notification, notification_type: 'unknown')

    assert_not notification.valid?
    assert notification.errors[:notification_type].any?
  end

  def test_an_event_is_required
    notification = FactoryBot.build(:notification, event: nil)

    assert_not notification.valid?
    assert notification.errors[:event].any?
  end

  # The column is text, so the full validated length reaches the database.
  def test_a_message_up_to_500_characters_is_stored_in_full
    message = 'a' * 500
    notification = FactoryBot.create(:notification, message: message)

    assert_equal message, notification.reload.message
    assert_not FactoryBot.build(:notification, message: 'a' * 501).valid?
  end

  def test_a_dedupe_key_is_unique_per_user
    user = FactoryBot.create(:user)
    FactoryBot.create(:notification, user: user, dedupe_key: 'task-1-due-soon')

    assert_raises(ActiveRecord::RecordNotUnique) do
      FactoryBot.create(:notification, user: user, dedupe_key: 'task-1-due-soon')
    end
    assert FactoryBot.create(:notification, dedupe_key: 'task-1-due-soon').persisted?
  end

  def test_the_target_is_optional_and_polymorphic
    project = FactoryBot.create(:project)
    task = project.task_for_task_definition(project.unit.task_definitions.first)

    targeted = FactoryBot.create(:notification, user: project.student, notifiable: task)
    untargeted = FactoryBot.create(:notification, user: project.student)

    assert_equal task, targeted.reload.notifiable
    assert_nil untargeted.reload.notifiable
  end

  def test_destroying_a_user_removes_their_notifications
    user = FactoryBot.create(:user)
    notification = FactoryBot.create(:notification, user: user)

    user.destroy

    assert_not Notification.exists?(notification.id)
  end
end
