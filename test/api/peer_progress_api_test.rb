# frozen_string_literal: true

require 'test_helper'
require 'time'

class PeerProgressApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  RESPONSE_KEYS = %w[
    task_definition_id
    unit_id
    target_grade
    submitted_percentage
    is_suppressed
    is_stale
    is_feature_enabled
    last_updated_at
    unavailable_message
  ].freeze

  FORBIDDEN_KEYS = %w[
    cohort_size
    submitted_count
    user_id
    student_id
    username
    first_name
    last_name
    project_id
    task_status
    marks
    feedback
  ].freeze

  setup do
    clear_auth_header

    @original_minimum_cohort_size =
      ENV.fetch('DF_PPI_MINIMUM_COHORT_SIZE', nil)

    @original_stale_after_hours =
      ENV.fetch('DF_PPI_STALE_AFTER_HOURS', nil)
    ENV['DF_PPI_MINIMUM_COHORT_SIZE'] = '5'
    ENV['DF_PPI_STALE_AFTER_HOURS'] = '48'

    @unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0,
      tutorials: 1,
      staff_count: 0,
      outcome_count: 0
    )
    @unit.update!(peer_progress_enabled: true)

    @student = create(:user, :student)
    @project = @unit.enrol_student(
      @student,
      @unit.tutorials.first.campus
    )
    @project.update!(target_grade: 1)

    @task_definition = create(
      :task_definition,
      unit: @unit,
      target_grade: 0,
      start_date: 1.day.ago,
      outcome_count: 0
    )
  end

  teardown do
    restore_env(
      'DF_PPI_MINIMUM_COHORT_SIZE',
      @original_minimum_cohort_size
    )
    restore_env(
      'DF_PPI_STALE_AFTER_HOURS',
      @original_stale_after_hours
    )
    clear_auth_header
  end

  test 'requires authentication' do
    get endpoint

    assert_equal 419, last_response.status
    assert_private_no_store
  end

  test 'returns a privacy-safe normal response for the owning student' do
    create_snapshot(
      submitted_percentage: 62.5,
      cohort_size: 5
    )

    request_as(@student)

    assert_equal 200, last_response.status, last_response.body
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_equal @task_definition.id, body['task_definition_id']
    assert_equal @unit.id, body['unit_id']
    assert_equal @project.target_grade, body['target_grade']
    assert_in_delta 62.5, body['submitted_percentage'], 0.001
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal true, body['is_feature_enabled']
    assert body['last_updated_at'].present?
    assert_equal '', body['unavailable_message']
  end

  test 'returns a genuine zero as zero rather than unavailable' do
    create_snapshot(
      submitted_percentage: 0,
      cohort_size: 5
    )

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_equal 0.0, body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal '', body['unavailable_message']
  end

  test 'does not allow access before a student specific flexible start date' do
    @unit.update!(allow_flexible_dates: true)

    create(
      :task,
      project: @project,
      task_definition: @task_definition,
      task_status: TaskStatus.not_started,
      target_start_date: 1.day.from_now
    )

    request_as(@student)

    assert_peer_progress_not_found
  end

  test 'does not allow access before a target grade specific start date' do
    @unit.update!(allow_flexible_dates: true)

    TaskDefinitionGradeDueDate.create!(
      task_definition: @task_definition,
      target_grade: @project.target_grade,
      start_date: 1.day.from_now,
      target_due_date: @task_definition.target_date
    )

    request_as(@student)

    assert_peer_progress_not_found
  end

  test 'allows access after the target grade specific start date' do
    @unit.update!(allow_flexible_dates: true)

    TaskDefinitionGradeDueDate.create!(
      task_definition: @task_definition,
      target_grade: @project.target_grade,
      start_date: 1.day.ago,
      target_due_date: @task_definition.target_date
    )

    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )

    request_as(@student)

    assert_equal 200, last_response.status
    assert_equal 50.0, last_response_body['submitted_percentage']
  end

  test 'does not create a task row while checking the release date' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )

    assert_no_difference('Task.count') do
      request_as(@student)
    end

    assert_equal 200, last_response.status
  end

  test 'fails closed when the cohort configuration is below the privacy floor' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )

    ENV['DF_PPI_MINIMUM_COHORT_SIZE'] = '4'

    request_as(@student)

    assert_equal 503, last_response.status
    assert_equal(
      PeerProgressApi::CONFIG_ERROR_MESSAGE,
      last_response_body['error']
    )
    assert_private_no_store
  end

  test 'accepts a configured threshold above the privacy floor' do
    ENV['DF_PPI_MINIMUM_COHORT_SIZE'] = '6'

    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 6
    )

    request_as(@student)

    assert_equal 200, last_response.status
    assert_equal 50.0, last_response_body['submitted_percentage']
    assert_equal false, last_response_body['is_suppressed']
  end

  test 'does not allow a student to read another students project' do
    other_student = create(:user, :student)
    other_project = @unit.enrol_student(
      other_student,
      @unit.tutorials.first.campus
    )
    other_project.update!(target_grade: 1)

    request_as(
      @student,
      endpoint(project: other_project)
    )

    assert_peer_progress_not_found
  end

  test 'does not allow a tutor to use the student endpoint' do
    tutor = create(:user, :tutor)
    @unit.employ_staff(tutor, Role.tutor)

    request_as(tutor)

    assert_peer_progress_not_found
  end

  test 'does not allow an unenrolled project' do
    @project.update!(enrolled: false)

    request_as(@student)

    assert_peer_progress_not_found
  end

  test 'does not allow an inactive unit in the first release' do
    @unit.update!(active: false)

    request_as(@student)

    assert_peer_progress_not_found
  end

  test 'does not allow a task from another unit' do
    other_unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0,
      tutorials: 0,
      staff_count: 0,
      outcome_count: 0
    )
    other_task = create(
      :task_definition,
      unit: other_unit,
      target_grade: 0,
      start_date: 1.day.ago,
      outcome_count: 0
    )

    request_as(
      @student,
      endpoint(task_definition: other_task)
    )

    assert_peer_progress_not_found
  end

  test 'does not allow a task above the students target grade' do
    higher_grade_task = create(
      :task_definition,
      unit: @unit,
      target_grade: 2,
      start_date: 1.day.ago,
      outcome_count: 0
    )

    request_as(
      @student,
      endpoint(task_definition: higher_grade_task)
    )

    assert_peer_progress_not_found
  end

  test 'does not allow an unreleased task' do
    future_task = create(
      :task_definition,
      unit: @unit,
      target_grade: 0,
      start_date: 1.day.from_now,
      outcome_count: 0
    )

    request_as(
      @student,
      endpoint(task_definition: future_task)
    )

    assert_peer_progress_not_found
  end

  test 'returns a neutral unavailable state when no snapshot exists' do
    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal true, body['is_feature_enabled']
    assert_nil body['last_updated_at']
    assert body['unavailable_message'].present?
  end

  test 'suppresses a cohort below the configured threshold' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 4
    )

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['submitted_percentage']
    assert_equal true, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert body['unavailable_message'].present?
    assert_not body.key?('cohort_size')
  end

  test 'shows a cohort at the exact configured threshold' do
    create_snapshot(
      submitted_percentage: 40,
      cohort_size: 5
    )

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_equal 40.0, body['submitted_percentage']
    assert_equal false, body['is_suppressed']
  end

  test 'hides the percentage when an active unit snapshot is stale' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5,
      calculated_at: 49.hours.ago
    )

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal true, body['is_stale']
    assert body['last_updated_at'].present?
    assert body['unavailable_message'].present?
  end

  test 'returns a disabled state when the unit has disabled PPI' do
    @unit.update!(peer_progress_enabled: false)

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal false, body['is_feature_enabled']
    assert_nil body['last_updated_at']
    assert body['unavailable_message'].present?
  end

  test 'ignores a browser supplied target grade' do
    create_snapshot(
      submitted_percentage: 60,
      cohort_size: 5
    )

    request_as(
      @student,
      "#{endpoint}?target_grade=3"
    )

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_equal @project.target_grade, body['target_grade']
    assert_equal 60.0, body['submitted_percentage']
  end

  test 'returns a neutral unavailable state when no target grade is selected' do
    # Intentionally bypass validations and callbacks to verify that the API
    # safely handles a project with no stored target grade.
    # rubocop:disable Rails/SkipsModelValidations
    @project.update_column(:target_grade, nil)
    # rubocop:enable Rails/SkipsModelValidations

    request_as(@student)

    assert_equal 200, last_response.status
    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['target_grade']
    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal true, body['is_feature_enabled']
    assert_nil body['last_updated_at']
    assert_equal(
      PeerProgressApi::UNAVAILABLE_MESSAGE,
      body['unavailable_message']
    )
  end

  test 'does not expose an invalid stored target grade' do
    # Intentionally bypass validations and callbacks to verify that the API
    # safely handles an invalid legacy target-grade value.
    # rubocop:disable Rails/SkipsModelValidations
    @project.update_column(:target_grade, 999)
    # rubocop:enable Rails/SkipsModelValidations

    request_as(@student)

    assert_equal 200, last_response.status

    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['target_grade']
    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal true, body['is_feature_enabled']
    assert_nil body['last_updated_at']
    assert_equal(
      PeerProgressApi::UNAVAILABLE_MESSAGE,
      body['unavailable_message']
    )
  end

  test 'returns unavailable rather than zero for an empty stored cohort' do
    create_snapshot(
      submitted_percentage: nil,
      cohort_size: 0
    )

    request_as(@student)

    assert_equal 200, last_response.status

    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_nil body['submitted_percentage']
    assert_equal false, body['is_suppressed']
    assert_equal false, body['is_stale']
    assert_equal true, body['is_feature_enabled']
    assert body['last_updated_at'].present?
    assert body['unavailable_message'].present?
  end

  test 'returns the snapshot timestamp in UTC ISO 8601 format' do
    calculated_at = Time.zone.parse('2026-08-10 03:15:00 UTC')

    create_snapshot(
      submitted_percentage: 62.5,
      cohort_size: 5,
      calculated_at: calculated_at
    )

    request_as(@student)

    assert_equal 200, last_response.status

    body = last_response_body
    assert_peer_progress_response_contract(body)

    assert_equal(
      calculated_at.utc.iso8601,
      body['last_updated_at']
    )
  end

  test 'fails closed when the stale window configuration is missing' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )

    ENV.delete('DF_PPI_STALE_AFTER_HOURS')

    request_as(@student)

    assert_equal 503, last_response.status
    assert_equal(
      PeerProgressApi::CONFIG_ERROR_MESSAGE,
      last_response_body['error']
    )
    assert_private_no_store
  end

  test 'returns the same generic response for unknown project and task ids' do
    unknown_project_id = Project.maximum(:id).to_i + 10_000

    request_as(
      @student,
      "/api/projects/#{unknown_project_id}/task_def_id/" \
      "#{@task_definition.id}/peer_progress"
    )

    assert_peer_progress_not_found

    unknown_task_id = TaskDefinition.maximum(:id).to_i + 10_000

    request_as(
      @student,
      "/api/projects/#{@project.id}/task_def_id/" \
      "#{unknown_task_id}/peer_progress"
    )

    assert_peer_progress_not_found
  end

  test 'fails closed for invalid positive integer configuration' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )

    [
      ['DF_PPI_MINIMUM_COHORT_SIZE', '0'],
      ['DF_PPI_MINIMUM_COHORT_SIZE', 'not-a-number'],
      ['DF_PPI_STALE_AFTER_HOURS', '-1'],
      ['DF_PPI_STALE_AFTER_HOURS', '1.5']
    ].each do |name, value|
      original = ENV.fetch(name, nil)

      begin
        ENV[name] = value
        request_as(@student)

        assert_equal 503, last_response.status
        assert_equal(
          PeerProgressApi::CONFIG_ERROR_MESSAGE,
          last_response_body['error']
        )
        assert_private_no_store
      ensure
        restore_env(name, original)
      end
    end
  end

  test 'keeps a snapshot available at the exact stale boundary' do
    travel_to Time.zone.parse('2026-08-10 12:00:00 UTC') do
      create_snapshot(
        submitted_percentage: 50,
        cohort_size: 5,
        calculated_at: 48.hours.ago
      )

      request_as(@student)

      assert_equal 200, last_response.status

      body = last_response_body
      assert_peer_progress_response_contract(body)

      assert_equal 50.0, body['submitted_percentage']
      assert_equal false, body['is_stale']
    end
  end

  test 'fails closed when required PPI configuration is missing' do
    create_snapshot(
      submitted_percentage: 50,
      cohort_size: 5
    )
    ENV.delete('DF_PPI_MINIMUM_COHORT_SIZE')

    request_as(@student)

    assert_equal 503, last_response.status
    assert_equal(
      PeerProgressApi::CONFIG_ERROR_MESSAGE,
      last_response_body['error']
    )
    assert_private_no_store
  end

  private

  def endpoint(project: @project, task_definition: @task_definition)
    "/api/projects/#{project.id}/task_def_id/" \
      "#{task_definition.id}/peer_progress"
  end

  def request_as(user, path = endpoint)
    clear_auth_header
    add_auth_header_for(user: user)
    get path
  end

  def create_snapshot(
    submitted_percentage:,
    cohort_size:,
    calculated_at: Time.zone.now
  )
    create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition,
      target_grade: @project.target_grade,
      submitted_percentage: submitted_percentage,
      cohort_size: cohort_size,
      calculated_at: calculated_at
    )
  end

  def assert_peer_progress_not_found
    assert_equal 404, last_response.status

    body = last_response_body

    assert_json_limit_keys_to_exactly %w[error], body

    assert_equal(
      PeerProgressApi::NOT_FOUND_MESSAGE,
      body['error']
    )

    assert_private_no_store
  end

  def restore_env(name, value)
    if value.nil?
      ENV.delete(name)
    else
      ENV[name] = value
    end
  end

  def assert_private_no_store
    cache_control = last_response.headers.fetch('Cache-Control', '')

    assert_includes cache_control, 'private'
    assert_includes cache_control, 'no-store'
  end

  def assert_peer_progress_response_contract(body)
    assert_json_limit_keys_to_exactly RESPONSE_KEYS, body

    assert_kind_of Integer, body['task_definition_id']
    assert_kind_of Integer, body['unit_id']

    assert(
      body['target_grade'].nil? ||
        body['target_grade'].is_a?(Integer),
      'target_grade must be an integer or null'
    )

    assert(
      body['submitted_percentage'].nil? ||
        body['submitted_percentage'].is_a?(Numeric),
      'submitted_percentage must be numeric or null'
    )

    unless body['submitted_percentage'].nil?
      assert_operator body['submitted_percentage'], :>=, 0.0
      assert_operator body['submitted_percentage'], :<=, 100.0
    end

    %w[
      is_suppressed
      is_stale
      is_feature_enabled
    ].each do |key|
      assert_includes(
        [true, false],
        body.fetch(key),
        "#{key} must be a boolean"
      )
    end

    unless body['last_updated_at'].nil?
      parsed_timestamp = nil

      assert_nothing_raised do
        parsed_timestamp = Time.iso8601(body['last_updated_at'])
      end

      assert_equal(
        0,
        parsed_timestamp.utc_offset,
        'last_updated_at must use UTC'
      )
    end

    assert_kind_of String, body['unavailable_message']
    assert_empty FORBIDDEN_KEYS & body.keys
    assert_private_no_store
  end
end
