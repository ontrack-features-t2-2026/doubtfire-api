# frozen_string_literal: true

require 'test_helper'

class TaskPrioritizationApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  setup do
    clear_auth_header
    @today = Time.zone.parse('2026-08-24 10:00:00 UTC')
  end

  teardown do
    clear_auth_header
  end

  test 'requires authentication' do
    get endpoint

    assert_equal 419, last_response.status
  end

  test 'ranks by personalized local due date and returns the documented contract' do
    travel_to @today do
      unit = create_unit(allow_flexible_dates: true)
      later_definition = create_task_definition(
        unit,
        name: 'Later task',
        target_date: 1.day.from_now,
        weighting: 10
      )
      urgent_definition = create_task_definition(
        unit,
        name: 'Urgent task',
        target_date: 20.days.from_now,
        weighting: 10
      )
      student = create(:user, :student)
      project = enrol_student(unit, student, target_grade: 0)
      later_task = project.task_for_task_definition(later_definition)
      urgent_task = project.task_for_task_definition(urgent_definition)

      later_task.update!(target_due_date: 20.days.from_now)
      urgent_task.update!(target_due_date: 1.day.from_now)

      request_as(student)

      assert_equal 200, last_response.status, last_response.body
      body = last_response_body
      assert_equal [urgent_task.id, later_task.id], body['data'].pluck('task_id')
      assert_operator body['data'].first['priority_score'], :>, body['data'].last['priority_score']
      assert_equal(
        %w[task_id task_name project_id unit_id priority_score],
        body['data'].first.keys
      )
      assert_equal(
        {
          'page' => 1,
          'per_page' => TaskPrioritizationApi::DEFAULT_PER_PAGE,
          'total_count' => 2,
          'total_pages' => 1
        },
        body['meta']
      )
    end
  end

  test 'only returns eligible tasks owned by the authenticated student' do
    travel_to @today do
      active_unit = create_unit
      open_definition = create_task_definition(active_unit, name: 'Open task', target_grade: 0)
      complete_definition = create_task_definition(active_unit, name: 'Complete task', target_grade: 0)
      higher_grade_definition = create_task_definition(active_unit, name: 'Higher grade task', target_grade: 3)
      student = create(:user, :student)
      project = enrol_student(active_unit, student, target_grade: 0)
      open_task = project.task_for_task_definition(open_definition)
      project.task_for_task_definition(complete_definition).update!(task_status: TaskStatus.complete)

      other_student = create(:user, :student)
      other_project = enrol_student(active_unit, other_student, target_grade: 3)
      other_task = other_project.task_for_task_definition(open_definition)

      inactive_unit = create_unit(active: false)
      inactive_definition = create_task_definition(inactive_unit, name: 'Inactive task')
      inactive_project = enrol_student(inactive_unit, student, target_grade: 0)
      inactive_task = inactive_project.task_for_task_definition(inactive_definition)

      withdrawn_unit = create_unit
      withdrawn_definition = create_task_definition(withdrawn_unit, name: 'Withdrawn task')
      withdrawn_project = enrol_student(withdrawn_unit, student, target_grade: 0)
      withdrawn_project.update!(enrolled: false)
      withdrawn_task = withdrawn_project.task_for_task_definition(withdrawn_definition)

      request_as(student)

      returned_ids = last_response_body['data'].pluck('task_id')
      assert_equal [open_task.id], returned_ids
      assert_not_includes returned_ids, project.task_for_task_definition(complete_definition).id
      assert_not_includes returned_ids, project.task_for_task_definition(higher_grade_definition).id
      assert_not_includes returned_ids, other_task.id
      assert_not_includes returned_ids, inactive_task.id
      assert_not_includes returned_ids, withdrawn_task.id
    end
  end

  test 'paginates every recommendation without overlap' do
    travel_to @today do
      unit = create_unit
      definitions = 3.times.map do |index|
        create_task_definition(
          unit,
          name: "Task #{index}",
          target_date: (index + 1).days.from_now,
          weighting: 10
        )
      end
      student = create(:user, :student)
      project = enrol_student(unit, student, target_grade: 0)
      expected_ids = definitions.map { |definition| project.task_for_task_definition(definition).id }

      add_auth_header_for(user: student)
      get endpoint, page: 1, per_page: 2
      first_page = last_response_body

      get endpoint, page: 2, per_page: 2
      second_page = last_response_body

      returned_ids = first_page['data'].pluck('task_id') + second_page['data'].pluck('task_id')
      assert_equal expected_ids.sort, returned_ids.sort
      assert_equal 2, first_page['data'].length
      assert_equal 1, second_page['data'].length
      assert_equal 3, first_page['meta']['total_count']
      assert_equal 2, first_page['meta']['total_pages']
      assert_empty first_page['data'].pluck('task_id') & second_page['data'].pluck('task_id')
    end
  end

  test 'uses task id as a deterministic tie breaker' do
    travel_to @today do
      unit = create_unit
      definitions = 2.times.map do |index|
        create_task_definition(
          unit,
          name: "Equal task #{index}",
          target_date: 5.days.from_now,
          weighting: 10
        )
      end
      student = create(:user, :student)
      project = enrol_student(unit, student, target_grade: 0)
      task_ids = definitions.map { |definition| project.task_for_task_definition(definition).id }

      request_as(student)

      assert_equal task_ids.sort, last_response_body['data'].pluck('task_id')
    end
  end

  private

  def endpoint
    '/api/tasks/recommended'
  end

  def request_as(user)
    add_auth_header_for(user: user)
    get endpoint
  end

  def create_unit(active: true, allow_flexible_dates: false)
    create(
      :unit,
      with_students: false,
      task_count: 0,
      staff_count: 0,
      outcome_count: 0,
      active: active,
      allow_flexible_dates: allow_flexible_dates,
      start_date: @today - 30.days,
      end_date: @today + 90.days
    )
  end

  def create_task_definition(
    unit,
    name:,
    target_date: @today + 7.days,
    target_grade: 0,
    weighting: 10
  )
    create(
      :task_definition,
      unit: unit,
      name: name,
      start_date: @today - 7.days,
      target_date: target_date,
      due_date: @today + 60.days,
      target_grade: target_grade,
      weighting: weighting,
      outcome_count: 0
    )
  end

  def enrol_student(unit, student, target_grade:)
    project = unit.enrol_student(student, unit.tutorials.first&.campus)
    project.update!(target_grade: target_grade)
    project
  end
end
