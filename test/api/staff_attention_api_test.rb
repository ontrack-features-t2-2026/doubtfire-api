# frozen_string_literal: true

require 'test_helper'

class StaffAttentionApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  setup do
    @unit = create(:unit, student_count: 2, task_count: 1, stream_count: 1)
    @definition = @unit.task_definitions.first
    @definition.update!(target_grade: 0)
    @task = @unit.active_projects.first.task_for_task_definition(@definition)
    @task.update!(task_status: TaskStatus.ready_for_feedback, submission_date: 10.days.ago)
    clear_auth_header
  end

  test 'authentication is required and students see no teaching workload' do
    get '/api/attention/staff'
    assert_equal 419, last_response.status
    add_auth_header_for(user: @task.project.student)
    get '/api/attention/staff'
    assert_equal 200, last_response.status
    assert_empty last_response_body['units']
  end

  test 'convenor sees only their own active units without student details' do
    add_auth_header_for(user: @unit.main_convenor_user)
    get '/api/attention/staff'
    assert_equal 200, last_response.status, last_response.body
    assert_equal [@unit.id], last_response_body['units'].pluck('unit_id')
    row = last_response_body['units'].first
    assert_equal 1, row['awaiting_feedback_count']
    assert_equal 10, row['oldest_wait_days']
    assert_not last_response.body.include?(@task.project.student.email)
    @unit.update!(active: false)
    get '/api/attention/staff'
    assert_empty last_response_body['units']
  end

  test 'unassigned tutor and unrelated convenor cannot see the submission' do
    tutor = create(:user, :tutor)
    create(:unit_role, unit: @unit, user: tutor, role: Role.tutor)
    add_auth_header_for(user: tutor)
    get '/api/attention/staff'
    assert_equal 0, last_response_body['totals']['awaiting_feedback_count']
    other = create(:unit, student_count: 0, task_count: 0).main_convenor_user
    add_auth_header_for(user: other)
    get '/api/attention/staff'
    assert_not_includes last_response_body['units'].pluck('unit_id'), @unit.id
  end

  test 'assigned tutor sees tasks only from their tutorial stream' do
    tutor = create(:user, :tutor)
    role = create(:unit_role, unit: @unit, user: tutor, role: Role.tutor)
    tutorial = create(:tutorial, unit: @unit, campus: @task.project.campus,
                                 unit_role: role, tutorial_stream: @definition.tutorial_stream)
    @task.project.enrol_in(tutorial)
    other_stream = create(:tutorial_stream, unit: @unit)
    other_definition = create(:task_definition, unit: @unit, target_grade: 0, tutorial_stream: other_stream)
    @task.project.task_for_task_definition(other_definition).update!(task_status: TaskStatus.ready_for_feedback,
                                                                     submission_date: 12.days.ago)
    add_auth_header_for(user: tutor)
    get '/api/attention/staff'
    assert_equal 1, last_response_body['totals']['awaiting_feedback_count']
    role.update!(observer_only: true)
    get '/api/attention/staff'
    assert_empty last_response_body['units']
  end

  test 'submitted and help work stays visible after student lowers target grade' do
    @task.project.update!(target_grade: 0)
    @definition.update!(target_grade: 3)
    staff = @unit.main_convenor_user
    summary = StaffAttentionService.new(staff).call
    assert_equal 1, summary[:totals][:awaiting_feedback_count]
    @task.update!(task_status: TaskStatus.need_help)
    summary = StaffAttentionService.new(staff).call
    assert_equal 1, summary[:totals][:help_requested_count]
  end

  test 'pending extension counts are distinct tasks and stop after assessment' do
    staff = @unit.main_convenor_user
    2.times do
      ExtensionComment.create!(task: @task, user: @task.project.student, recipient: staff,
                               content_type: :extension, comment: 'Please allow more time.', extension_weeks: 1)
    end
    assert_equal 1, StaffAttentionService.new(staff).call[:totals][:extension_requested_count]
    @task.comments.where(type: 'ExtensionComment').find_each { |comment| comment.update!(date_extension_assessed: Time.current) }
    assert_equal 0, StaffAttentionService.new(staff).call[:totals][:extension_requested_count]
  end

  test 'staff summary requires explicit opt in and deduplicates a cadence period' do
    staff = @unit.main_convenor_user
    assert_equal 'off', staff.staff_digest_frequency
    claims = Set.new
    guard = ->(user, period) { claims.add?([user.id, period]) }
    DigestDeliveryGuard.stub(:claim, guard) do
      assert_no_difference 'ActionMailer::Base.deliveries.count' do
        SendStaffAttentionSummariesJob.new.perform('daily')
      end
      staff.update!(staff_digest_frequency: 'daily')
      assert_difference 'ActionMailer::Base.deliveries.count', 1 do
        SendStaffAttentionSummariesJob.new.perform('daily')
        SendStaffAttentionSummariesJob.new.perform('daily')
      end
    end
    assert_equal [staff.email], ActionMailer::Base.deliveries.last.to
    assert_not_includes ActionMailer::Base.deliveries.last.body.encoded, @task.project.student.email
  end
end
