# frozen_string_literal: true

require 'test_helper'
require 'csv'

class ExecuteCommunicationSetJobTest < ActiveSupport::TestCase
  def test_task_comment_action_adds_a_comment_to_each_selected_students_task
    unit = FactoryBot.create(
      :unit,
      with_students: false,
      task_count: 1,
      stream_count: 0,
      tutorials: 0,
      outcome_count: 0,
      staff_count: 1
    )

    task_definition = unit.task_definitions.first
    campus = Campus.first
    comment_author = unit.main_convenor_user

    student_one = FactoryBot.create(:user, :student)
    student_one.update!(first_name: 'Ada', last_name: 'Lovelace')
    project_one = unit.enrol_student(student_one, campus)

    student_two = FactoryBot.create(:user, :student)
    student_two.update!(first_name: 'Grace', last_name: 'Hopper')
    project_two = unit.enrol_student(student_two, campus)

    communication_set = unit.communication_sets.create!(name: 'Test Set', active: true)
    communication_rule = communication_set.communication_rules.create!(
      name: 'Comment Rule',
      operator: 'and',
      position: 0
    )
    communication_rule.communication_actions.create!(
      type: 'TaskCommentAction',
      task_definition: task_definition,
      body: 'Please review {{student.first_name}} for {{unit.code}}'
    )

    ExecuteCommunicationSetJob.new.perform(communication_set.id)

    task_one = project_one.task_for_task_definition(task_definition)
    task_two = project_two.task_for_task_definition(task_definition)

    assert_equal 1, TaskComment.where(task: task_one).count
    assert_equal 1, TaskComment.where(task: task_two).count

    comment_one = task_one.comments.last
    comment_two = task_two.comments.last

    assert_equal comment_author, comment_one.user
    assert_equal comment_author, comment_two.user
    assert_equal 'Please review Ada for ' + unit.code, comment_one.comment
    assert_equal 'Please review Grace for ' + unit.code, comment_two.comment
  end

  # BGW-24: the action-log CSV must stamp each row with the time its own
  # action ran, not the time the CSV was generated after the batch finished.
  def test_action_log_csv_stamps_each_row_with_its_own_execution_time
    unit = FactoryBot.create(
      :unit,
      with_students: false,
      task_count: 1,
      stream_count: 0,
      tutorials: 0,
      outcome_count: 0,
      staff_count: 1
    )

    task_definition = unit.task_definitions.first
    campus = Campus.first

    student = FactoryBot.create(:user, :student)
    project = unit.enrol_student(student, campus)

    communication_set = unit.communication_sets.create!(name: 'Test Set', active: true)
    communication_rule = communication_set.communication_rules.create!(
      name: 'Comment Rule',
      operator: 'and',
      position: 0
    )
    action = communication_rule.communication_actions.create!(
      type: 'TaskCommentAction',
      task_definition: task_definition,
      body: 'Please review {{student.first_name}}'
    )

    executed = Time.utc(2026, 1, 2, 3, 4, 5)
    results = [
      {
        action_id: action.id,
        action_type: action.type,
        status: 'commented',
        project_id: project.id,
        task_definition_id: task_definition.id,
        executed_at: executed
      },
      {
        action_id: action.id,
        action_type: action.type,
        status: 'skipped',
        project_id: project.id,
        reason: 'no recipient'
      }
    ]

    csv = ExecuteCommunicationSetJob.new.send(:build_action_log_csv, communication_rule, [project], results)
    rows = CSV.parse(csv, headers: true)

    commented = rows.find { |row| row['status'] == 'commented' }
    skipped = rows.find { |row| row['status'] == 'skipped' }

    assert_equal executed.iso8601, commented['executed_at'], 'an executed row should carry its own action time'
    assert skipped['executed_at'].blank?, 'a skipped action has no execution time'
  end
end
