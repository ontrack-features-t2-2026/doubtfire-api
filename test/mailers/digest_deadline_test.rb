# frozen_string_literal: true

require 'test_helper'

class DigestDeadlineTest < ActiveSupport::TestCase
  test 'digest recommendation and calendar agree on personal flexible dates' do
    travel_to Time.zone.parse('2026-10-01 09:00:00 UTC') do
      unit = create(:unit, student_count: 1, task_count: 1, allow_flexible_dates: true)
      definition = unit.task_definitions.first
      definition.update!(target_grade: 0, target_date: 5.days.ago)
      project = unit.active_projects.first
      task = project.task_for_task_definition(definition)
      task.update!(target_due_date: 2.days.from_now, task_status: TaskStatus.working_on_it)

      mailer = NotificationsMailer.new
      mailer.instance_variable_set(:@window_start, 1.day.ago)
      summary = mailer.send(:digest_unit_summary, project)
      entry = summary[:soon].find { |item| item[:task_definition].id == definition.id }
      assert_not_nil entry
      assert_empty summary[:overdue]
      assert_equal task.effective_deadline_date, entry[:target_date]
      recommendation = TaskPrioritizationService.new(project.student).call.find { |item| item[:task_definition_id] == definition.id }
      assert_equal task.effective_deadline_date.iso8601, recommendation[:effective_deadline_date]
      assert_equal 'flexible_date', recommendation[:effective_deadline_reason]
      assert_equal task.effective_deadline_date, Webcal.end_date_for_task_definition(definition, task, project)

      legacy_mailer = NotificationsMailer.new
      legacy_mailer.process(:weekly_student_summary, project,
                            { unit: unit, week_start: 1.week.ago, week_end: Time.current }, false)
      assert_equal task.effective_deadline_date, legacy_mailer.instance_variable_get(:@task_due_dates)[definition.id]
      assert_equal 0, legacy_mailer.instance_variable_get(:@behind_target)
    end
  end

  test 'digest uses flexible grade target before a task row exists' do
    travel_to Time.zone.parse('2026-10-01 09:00:00 UTC') do
      unit = create(:unit, student_count: 1, task_count: 1, allow_flexible_dates: true)
      definition = unit.task_definitions.first
      definition.update!(target_grade: 0, target_date: 5.days.ago)
      project = unit.active_projects.first
      create(:task_definition_grade_due_date, task_definition: definition,
                                              target_grade: project.target_grade, target_due_date: 2.days.from_now)
      mailer = NotificationsMailer.new
      mailer.instance_variable_set(:@window_start, 1.day.ago)
      assert_no_difference 'Task.count' do
        summary = mailer.send(:digest_unit_summary, project)
        assert_empty summary[:overdue]
        assert_equal 0, summary[:behind_target]
        assert_equal 2.days.from_now.to_date, summary[:soon].first[:target_date]
      end
    end
  end
end
