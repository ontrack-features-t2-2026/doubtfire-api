require 'test_helper'
require 'date'
require './lib/helpers/database_populator'

class ProjectsApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper
  include TestHelpers::TestFileHelper
  include ActiveSupport::Testing::TimeHelpers

  def app
    Rails.application
  end

  def test_can_get_projects
    user = FactoryBot.create(:user, :student, enrol_in: 1)

    # Add username and auth_token to Header
    add_auth_header_for(user: user)

    get '/api/projects'
    assert_equal 200, last_response.status
  end

  def test_get_projects_with_streams_match
    unit = FactoryBot.create :unit, stream_count: 2, campus_count: 2, tutorials: 2, unenrolled_student_count: 0, part_enrolled_student_count: 0, inactive_student_count: 0
    project = unit.projects.first
    assert_equal 2, project.tutorial_enrolments.count

    # Add username and auth_token to Header
    add_auth_header_for(user: project.student)

    get '/api/projects'
    assert_equal 200, last_response.status
    assert_equal 1, last_response_body.count, last_response_body
  end

  def test_projects_returns_correct_number_of_projects
    user = FactoryBot.create(:user, :student, enrol_in: 2)

    # Add username and auth_token to Header
    add_auth_header_for(user: user)

    get '/api/projects'
    assert_equal 2, last_response_body.count
  end

  def test_projects_returns_correct_data
    user = FactoryBot.create(:user, :student, enrol_in: 2)

    # Add username and auth_token to Header
    add_auth_header_for(user: user)

    keys = %w[id unit campus_id user_id target_grade portfolio_available spec_con_days escalation_attempts_remaining]
    key_test = %w[campus_id target_grade spec_con_days]

    get '/api/projects'
    assert_equal 2, last_response_body.count, last_response_body
    last_response_body.each do |data|
      project = user.projects.find(data['id'])
      assert project.present?, data.inspect

      assert_json_limit_keys_to_exactly keys, data

      assert_json_matches_model(project, data, %w(campus_id target_grade campus_id))
      assert_json_matches_model(project.unit, data['unit'], %w(id code name active))

      assert_json_matches_model project, data, key_test
    end
  end

  def test_get_project_response_is_correct
    user = FactoryBot.create(:user, :student, enrol_in: 1)
    project = user.projects.first

    # Add username and auth_token to Header
    add_auth_header_for(user: user)

    keys = %w[id unit unit_id user_id campus_id target_grade submitted_grade portfolio_files compile_portfolio portfolio_available uses_draft_learning_summary tasks tutorial_enrolments groups spec_con_days escalation_attempts_remaining]
    key_test = keys - %w[unit user_id portfolio_available tasks tutorial_enrolments groups]

    get "/api/projects/#{project.id}"
    assert_equal 200, last_response.status, last_response_body

    assert_json_limit_keys_to_exactly keys, last_response_body
    assert_json_matches_model project, last_response_body, key_test
  end

  def test_projects_works_with_inactive_units
    user = FactoryBot.create(:user, :student, enrol_in: 2)
    Unit.last.update(active: false)

    # Add username and auth_token to Header
    add_auth_header_for(user: user)

    get '/api/projects'
    assert_equal 1, last_response_body.count

    get '/api/projects?include_inactive=false'
    assert_equal 1, last_response_body.count

    get '/api/projects?include_inactive=true'

    assert_equal 2, last_response_body.count

    last_response_body.each do |data|
      project = user.projects.find(data['id'])
      assert project.present?, data.inspect

      assert_json_matches_model(project, data, %w(campus_id target_grade campus_id))
      assert_json_matches_model(project.unit, data['unit'], %w(code id name active))
    end
  end

  def test_submitted_grade_cant_change_after_submission
    user = FactoryBot.create(:user, :student, enrol_in: 1)
    project = user.projects.first

    data_to_put = {
      id: project.id,
      submitted_grade: 2
    }

    add_auth_header_for(user: user)

    put_json "/api/projects/#{project.id}", data_to_put
    project.reload

    assert_equal 200, last_response.status, last_response_body
    assert_equal user.projects.find(project.id).submitted_grade, 2

    keys = %w(campus_id target_grade submitted_grade compile_portfolio portfolio_available uses_draft_learning_summary)

    assert_json_limit_keys_to_exactly keys, last_response_body
    assert_json_matches_model project, last_response_body, keys

    DatabasePopulator.generate_portfolio(project)

    data_to_put['submitted_grade'] = 1

    put_json "/api/projects/#{project.id}", data_to_put

    assert_not_equal user.projects.find(project.id).submitted_grade, 1
    assert_equal 403, last_response.status
  end

  def test_download_portfolio
    project = FactoryBot.create(:project)
    unit = project.unit

    project.portfolio_production_date = Time.zone.now
    project.save

    `fallocate -l 10M #{project.portfolio_path}`

    assert File.exist?(project.portfolio_path)
    assert project.portfolio_exists?

    data_to_put = {
      as_attachment: true
    }

    add_auth_header_for(user: project.student)

    get "/api/submission/project/#{project.id}/portfolio", data_to_put
    assert_equal 200, last_response.status
    assert last_response.headers['Content-Disposition'].starts_with?('attachment; filename=')
    assert_equal 'Content-Disposition', last_response.headers['Access-Control-Expose-Headers']
    assert last_response.headers['Content-Type'] == 'application/pdf'
    assert 10_485_760, last_response.length

    `fallocate -l 11M #{project.portfolio_path}`
    get "/api/submission/project/#{project.id}/portfolio", data_to_put
    assert_equal 206, last_response.status
    assert 10_485_760, last_response.length

    data_to_put = {
      as_attachment: false
    }

    add_auth_header_for(user: project.student)
    header 'range', 'bytes=1000-1500'

    get "/api/submission/project/#{project.id}/portfolio", data_to_put
    assert 500, last_response.length
    assert_equal 206, last_response.status
    assert_nil last_response.headers['Content-Disposition']
    assert_equal 'Content-Range,Accept-Ranges', last_response.headers['Access-Control-Expose-Headers']
    assert last_response.headers['Content-Type'] == 'application/pdf'

    unit.destroy!
  ensure
    FileUtils.rm_f(project.portfolio_path)
  end

  def test_engagement_heatmap_success_and_contract
    travel_to Time.zone.parse('2026-04-15 12:00') do
      unit = FactoryBot.create(:unit, student_count: 1, task_count: 2)
      project = unit.active_projects.first
      task = project.task_for_task_definition(unit.task_definitions.first)

      TaskEngagement.create!(
        task: task,
        engagement_time: Time.zone.parse('2026-04-15 09:00'),
        engagement: TaskStatus.ready_for_feedback.name
      )
      TaskEngagement.create!(
        task: task,
        engagement_time: Time.zone.parse('2026-04-14 11:00'),
        engagement: TaskStatus.complete.name
      )

      add_auth_header_for(user: project.student)
      get "/api/projects/#{project.id}/engagement_heatmap"

      assert_equal 200, last_response.status, last_response.body
      body = last_response_body

      assert_equal %w[days project_id range summary unit_id], body.keys.sort
      assert_equal project.id, body['project_id']
      assert_equal unit.id, body['unit_id']

      end_d = Time.zone.today
      start_d = end_d - (EngagementHeatmapService::WINDOW_DAYS - 1).days
      assert_equal start_d.strftime('%Y-%m-%d'), body['range']['start_date']
      assert_equal end_d.strftime('%Y-%m-%d'), body['range']['end_date']
      assert_equal EngagementHeatmapService::WINDOW_DAYS, body['range']['days']

      assert_equal EngagementHeatmapService::WINDOW_DAYS, body['days'].length
      body['days'].each do |day|
        assert_equal %w[activity_count date], day.keys.sort
      end

      assert_equal 1, body['days'].find { |d| d['date'] == '2026-04-15' }['activity_count']
      assert_equal 1, body['days'].find { |d| d['date'] == '2026-04-14' }['activity_count']

      assert_equal 1, body['summary']['tasks_completed']
      assert_equal 2, body['summary']['active_days']
      assert_equal 2, body['summary']['current_streak']
    end
  end

  def test_engagement_heatmap_unauthorized
    unit = FactoryBot.create(:unit, student_count: 1, task_count: 1)
    project = unit.active_projects.first
    other = FactoryBot.create(:user, :student)

    add_auth_header_for(user: other)
    get "/api/projects/#{project.id}/engagement_heatmap"

    assert_equal 403, last_response.status
  end

  def test_engagement_heatmap_scoped_to_project_no_cross_unit_leakage
    travel_to Time.zone.parse('2026-05-01 10:00') do
      unit_a = FactoryBot.create(:unit, student_count: 1, task_count: 1)
      unit_b = FactoryBot.create(:unit, student_count: 1, task_count: 1)
      project_a = unit_a.active_projects.first
      project_b = unit_b.active_projects.first
      task_a = project_a.task_for_task_definition(unit_a.task_definitions.first)

      5.times do |i|
        TaskEngagement.create!(
          task: task_a,
          engagement_time: Time.zone.parse("2026-05-01 #{9 + i}:00"),
          engagement: TaskStatus.working_on_it.name
        )
      end

      add_auth_header_for(user: project_b.student)
      get "/api/projects/#{project_b.id}/engagement_heatmap"

      assert_equal 200, last_response.status, last_response.body
      body = last_response_body

      assert_equal 0, body['summary']['active_days']
      assert_equal 0, body['summary']['tasks_completed']
      assert_equal 0, body['summary']['current_streak']
      assert body['days'].all? { |d| d['activity_count'].zero? }
    end
  end

  def test_engagement_heatmap_no_activity_all_zeros
    travel_to Time.zone.parse('2026-06-10 08:00') do
      unit = FactoryBot.create(:unit, student_count: 1, task_count: 1)
      project = unit.active_projects.first

      add_auth_header_for(user: project.student)
      get "/api/projects/#{project.id}/engagement_heatmap"

      assert_equal 200, last_response.status, last_response.body
      body = last_response_body

      assert body['days'].all? { |d| d['activity_count'].zero? }
      assert_equal 0, body['summary']['active_days']
      assert_equal 0, body['summary']['tasks_completed']
      assert_equal 0, body['summary']['current_streak']
    end
  end

  def test_engagement_heatmap_sparse_activity_and_tasks_completed_distinct
    travel_to Time.zone.parse('2026-07-20 15:00') do
      unit = FactoryBot.create(:unit, student_count: 1, task_count: 2)
      project = unit.active_projects.first
      td1 = unit.task_definitions.first
      td2 = unit.task_definitions.second
      task1 = project.task_for_task_definition(td1)
      task2 = project.task_for_task_definition(td2)

      TaskEngagement.create!(
        task: task1,
        engagement_time: Time.zone.parse('2026-07-20 10:00'),
        engagement: TaskStatus.need_help.name
      )
      TaskEngagement.create!(
        task: task1,
        engagement_time: Time.zone.parse('2026-07-20 14:00'),
        engagement: TaskStatus.working_on_it.name
      )
      TaskEngagement.create!(
        task: task2,
        engagement_time: Time.zone.parse('2026-07-18 09:00'),
        engagement: TaskStatus.complete.name
      )
      TaskEngagement.create!(
        task: task1,
        engagement_time: Time.zone.parse('2026-07-10 12:00'),
        engagement: TaskStatus.complete.name
      )

      add_auth_header_for(user: project.student)
      get "/api/projects/#{project.id}/engagement_heatmap"

      body = last_response_body

      assert_equal 2, body['days'].find { |d| d['date'] == '2026-07-20' }['activity_count']
      assert_equal 1, body['days'].find { |d| d['date'] == '2026-07-18' }['activity_count']
      assert_equal 1, body['days'].find { |d| d['date'] == '2026-07-10' }['activity_count']

      assert_equal 2, body['summary']['tasks_completed']
      assert_equal 3, body['summary']['active_days']
    end
  end

  def test_engagement_heatmap_streak_ends_yesterday_when_today_empty
    travel_to Time.zone.parse('2026-08-05 12:00') do
      unit = FactoryBot.create(:unit, student_count: 1, task_count: 1)
      project = unit.active_projects.first
      task = project.task_for_task_definition(unit.task_definitions.first)

      TaskEngagement.create!(
        task: task,
        engagement_time: Time.zone.parse('2026-08-04 10:00'),
        engagement: TaskStatus.ready_for_feedback.name
      )
      TaskEngagement.create!(
        task: task,
        engagement_time: Time.zone.parse('2026-08-03 10:00'),
        engagement: TaskStatus.ready_for_feedback.name
      )

      add_auth_header_for(user: project.student)
      get "/api/projects/#{project.id}/engagement_heatmap"

      body = last_response_body

      assert_equal 0, body['days'].find { |d| d['date'] == '2026-08-05' }['activity_count']
      assert_equal 2, body['summary']['current_streak']
    end
  end

  def test_engagement_heatmap_unknown_project_returns_404
    user = FactoryBot.create(:user, :student, enrol_in: 1)
    missing_id = Project.maximum(:id).to_i + 999_999

    add_auth_header_for(user: user)
    get "/api/projects/#{missing_id}/engagement_heatmap"

    assert_equal 404, last_response.status
  end
end
