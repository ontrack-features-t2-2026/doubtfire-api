require 'test_helper'
require 'minitest/mock'

# EN: changing a task definition's due date emails every enrolled student who has
# that task, one each, and nobody else.
class NotificationDueDateTest < ActiveSupport::TestCase
  setup do
    @unit = FactoryBot.create(:unit)
    @task_def = @unit.task_definitions.first

    # Tasks are created on demand, so materialise one per active project to give
    # the fan-out records to walk (the same tasks a real cohort would have).
    @unit.active_projects.each { |p| p.task_for_task_definition(@task_def) }

    @affected = @task_def.tasks
                         .joins(:project)
                         .where(projects: { enrolled: true })
                         .map { |t| t.project.student }
                         .uniq

    ActionMailer::Base.deliveries.clear
  end

  def delivered_body
    mail = ActionMailer::Base.deliveries.last
    return '' if mail.nil?

    mail.multipart? ? mail.parts.map { |part| part.body.decoded }.join("\n") : mail.body.decoded
  end

  def change_due_date
    @task_def.update!(due_date: @task_def.due_date + 1.week)
  end

  def test_every_affected_student_is_emailed_once
    assert @affected.size >= 2, 'guard: need several students for a meaningful fan-out'

    assert_difference 'Notification.count', @affected.size do
      change_due_date
    end

    assert_equal @affected.size, ActionMailer::Base.deliveries.count
    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_equal @affected.map(&:email).sort, recipients.sort

    notification = Notification.recent_first.first
    assert_equal 'task', notification.notification_type
    assert_equal 'task_due_date_changed', notification.event
  end

  def test_a_student_in_another_unit_is_not_notified
    other = FactoryBot.create(:project)

    change_due_date

    assert_equal 0, Notification.where(user: other.student, event: 'task_due_date_changed').count
  end

  def test_a_withdrawn_student_in_the_same_unit_is_not_notified
    withdrawn = @unit.projects.find_by(enrolled: false)
    assert_not_nil withdrawn, 'guard: the unit factory should include a withdrawn project'
    withdrawn.task_for_task_definition(@task_def) # give them a task too

    change_due_date

    assert_equal 0, Notification.where(user: withdrawn.student, event: 'task_due_date_changed').count
  end

  def test_it_respects_receive_task_notifications
    opted_out = @affected.first
    opted_out.update!(receive_task_notifications: false)

    change_due_date

    assert_equal 0, Notification.where(user: opted_out, event: 'task_due_date_changed').count
    # everyone else still hears about it
    assert_equal @affected.size - 1, ActionMailer::Base.deliveries.count
  end

  def test_an_unrelated_update_sends_nothing
    assert_no_difference 'Notification.count' do
      @task_def.update!(description: 'A new description, unrelated to the due date.')
    end

    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  def test_the_message_names_the_task_but_not_the_new_date
    change_due_date

    notification = Notification.recent_first.first
    new_date = @task_def.reload.due_date

    assert_includes notification.message, @task_def.abbreviation
    assert_includes notification.message, @unit.code
    assert_not_includes notification.message, new_date.strftime('%Y')
  end

  def test_the_link_points_at_the_task_on_the_student_dashboard
    change_due_date

    notification = Notification.recent_first.first
    task = @task_def.tasks.detect { |t| t.project.student.id == notification.user_id }

    assert_equal(
      "/projects/#{task.project.id}/dashboard/#{@task_def.abbreviation}",
      notification.link
    )
  end

  def test_the_event_specific_template_is_used
    change_due_date

    assert_includes delivered_body, 'The new due date is not included in this email'
  end
end
