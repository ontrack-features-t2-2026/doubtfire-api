require 'test_helper'
require 'minitest/mock'

# EN-V05: notify only the affected student when group membership changes.
class NotificationGroupTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear

    @project = FactoryBot.create(:project)
    @group = FactoryBot.create(:group, unit: @project.unit)
    @student = @project.student
  end

  def delivered_body
    mail = ActionMailer::Base.deliveries.last
    return '' if mail.nil?

    mail.multipart? ? mail.parts.map { |part| part.body.decoded }.join("\n") : mail.body.decoded
  end

  def test_adding_a_member_notifies_only_that_student
    assert_difference 'Notification.count', 1 do
      @group.add_member(@project)
    end

    notification = Notification.recent_first.first

    assert_equal @student, notification.user
    assert_equal 'general', notification.notification_type
    assert_equal 'group_membership_changed', notification.event
    assert_includes notification.message, 'added to'

    assert_equal 1, ActionMailer::Base.deliveries.count
    assert_equal [@student.email], ActionMailer::Base.deliveries.last.to

    # Confirms the event-specific template is being used.
    assert_includes delivered_body, 'group membership changed'
  end

  def test_removing_a_member_notifies_that_student
    @group.add_member(@project)

    ActionMailer::Base.deliveries.clear

    assert_difference 'Notification.count', 1 do
      @group.remove_member(@project)
    end

    notification = Notification.recent_first.first

    assert_equal @student, notification.user
    assert_equal 'general', notification.notification_type
    assert_equal 'group_membership_changed', notification.event
    assert_includes notification.message, 'removed from'

    assert_equal 1, ActionMailer::Base.deliveries.count
    assert_equal [@student.email], ActionMailer::Base.deliveries.last.to
  end

  def test_other_group_members_are_not_notified
    other_project = FactoryBot.create(:project, unit: @project.unit)

    @group.add_member(other_project)

    ActionMailer::Base.deliveries.clear

    assert_difference 'Notification.count', 1 do
      @group.add_member(@project)
    end

    notification = Notification.recent_first.first

    assert_equal @student, notification.user
    assert_not_equal other_project.student, notification.user

    assert_equal 1, ActionMailer::Base.deliveries.count
    assert_equal [@student.email], ActionMailer::Base.deliveries.last.to
  end

  def test_switch_to_tutorial_does_not_send_leave_then_join_notifications
    unit = FactoryBot.create(
      :unit,
      group_sets: 1,
      groups: [{ gs: 0, students: 0 }]
    )

    group_set = unit.group_sets.first
    group_set.update!(
      keep_groups_in_same_class: true,
      allow_students_to_manage_groups: true
    )

    group = group_set.groups.first

    project_one = group.tutorial.projects.first
    project_two = group.tutorial.projects.last

    group.add_member(project_one)
    group.add_member(project_two)

    new_tutorial = FactoryBot.create(:tutorial, unit: unit, campus: nil)

    ActionMailer::Base.deliveries.clear

    assert_no_difference 'Notification.count' do
      group.switch_to_tutorial(new_tutorial)
    end

    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_notification_failure_does_not_stop_membership_change
    NotificationService.stub :notify, ->(**_kwargs) { raise StandardError, 'notification failed' } do
      assert_nothing_raised do
        @group.add_member(@project)
      end
    end

    assert_includes @group.reload.projects, @project
  end
end
