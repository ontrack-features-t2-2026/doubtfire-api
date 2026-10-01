# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require Rails.root.join('lib/demo_data/public_demo_scenario')

class PublicDemoScenarioTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  setup do
    @scenario = DemoData::PublicDemoScenario.new(reference_time: Time.current)
    @profile = ENV.fetch('DF_DEMO_DATA_PROFILE', nil)
    @teams = ENV.fetch('DF_TEAMS_ANNOUNCEMENTS_ENABLED', nil)
    @mail_method = Rails.application.config.action_mailer.delivery_method
    @smtp_settings = Rails.application.config.action_mailer.smtp_settings
    ENV['DF_DEMO_DATA_PROFILE'] = 'public-demo'
    ENV['DF_TEAMS_ANNOUNCEMENTS_ENABLED'] = 'false'
    Rails.application.config.action_mailer.delivery_method = :smtp
    Rails.application.config.action_mailer.smtp_settings = { address: 'mailpit', port: 1025 }
    clear_auth_header
  end

  teardown do
    @profile.nil? ? ENV.delete('DF_DEMO_DATA_PROFILE') : ENV['DF_DEMO_DATA_PROFILE'] = @profile
    @teams.nil? ? ENV.delete('DF_TEAMS_ANNOUNCEMENTS_ENABLED') : ENV['DF_TEAMS_ANNOUNCEMENTS_ENABLED'] = @teams
    Rails.application.config.action_mailer.delivery_method = @mail_method
    Rails.application.config.action_mailer.smtp_settings = @smtp_settings
    clear_auth_header
  end

  test 'guards reject non production mode either wrong database and external mail' do
    assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.guard! }
    %i[configured_database connected_database].each do |option|
      with_production(**{ option => 'real-ontrack' }) do
        error = assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.guard! }
        assert_includes error.message, 'configured and connected database'
      end
    end
    with_production do
      ENV['DF_DEMO_DATA_PROFILE'] = 'all-features'
      assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.guard! }
      ENV['DF_DEMO_DATA_PROFILE'] = 'public-demo'
      Rails.application.config.action_mailer.smtp_settings = { address: 'smtp.example.org', port: 1025 }
      assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.guard! }
      Rails.application.config.action_mailer.smtp_settings = { address: 'mailpit', port: 1025 }
      ENV['DF_TEAMS_ANNOUNCEMENTS_ENABLED'] = 'true'
      assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.guard! }
    end
  end

  test 'existing unrelated records are refused without any changes' do
    before = [User.count, Unit.count, Task.count]
    with_production do
      error = assert_raises(DemoData::AllFeaturesScenario::SafetyError) { @scenario.run! }
      assert_includes error.message, 'bootstrap marker'
    end
    assert_equal before, [User.count, Unit.count, Task.count]
  end

  test 'fresh schema bootstrap does not run destructive populate or create an administrator' do
    connection = Minitest::Mock.new
    connection.expect(:data_sources, [])
    calls = []
    task = ->(name) { Object.new.tap { |object| object.define_singleton_method(:invoke) { calls << name } } }
    with_production do
      ActiveRecord::Base.stub(:connection, connection) do
        Rake::Task.stub(:[], task) do
          User.stub(:reset_column_information, nil) do
            @scenario.stub(:write_bootstrap_state, nil) do
              @scenario.stub(:run!, { prepared: true }) { assert_equal({ prepared: true }, @scenario.prepare!) }
            end
          end
        end
      end
    end
    assert_equal %w[db:schema:load db:init_reference_data], calls
    connection.verify
  end

  test 'existing schema migration failure never falls back to loading a schema' do
    connection = Minitest::Mock.new
    connection.expect(:data_sources, ['users'])
    calls = []
    task = lambda do |name|
      Object.new.tap do |object|
        object.define_singleton_method(:invoke) do
          calls << name
          raise 'Synthetic migration failure'
        end
      end
    end
    with_production do
      ActiveRecord::Base.stub(:connection, connection) do
        @scenario.stub(:bootstrap_state, DemoData::PublicDemoScenario::COMPLETE_STATE) do
          Rake::Task.stub(:[], task) { assert_raises(RuntimeError) { @scenario.prepare! } }
        end
      end
    end
    assert_equal ['db:migrate'], calls
    connection.verify
  end

  test 'synthetic accounts exercise normal APIs without administrative access and reruns preserve records' do
    # The normal suite starts with legacy fixtures. Clear rows only inside this
    # test's rollback transaction, without model callbacks touching their files.
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      (connection.data_sources - %w[roles task_statuses schema_migrations ar_internal_metadata]).each do |table|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
      end
    end
    original_work_dir = Rails.application.config.student_work_dir
    Dir.mktmpdir('ontrack-public-demo-test') do |directory|
      Rails.application.config.student_work_dir = directory
      begin
        @scenario.send(:write_bootstrap_state, DemoData::PublicDemoScenario::PENDING_STATE)
        with_production { @scenario.run! }
        assert_equal 28, User.count
        assert_equal 0, User.where(role: Role.admin).count
        assert_nil User.find_by(username: 'aadmin')
        assert(User.all.all? { |user| user.email == "#{user.username}@example.invalid" })
        assert User.all.none?(&:receive_task_email_notifications)
        assert User.all.none?(&:receive_feedback_push_notifications)
        assert_equal ['off'], User.distinct.pluck(:digest_frequency)
        student = User.find_by!(username: 'student_1')
        staff = User.find_by!(username: 'staff_1')
        assert_equal Role.student, student.role
        assert_equal Role.tutor, staff.role
        assert student.valid_password?('password')
        assert staff.valid_password?('password')
        assert_normal_student_endpoints(student)
        assert_normal_staff_endpoints(staff)
        assert_operator TaskComment.count, :>, 0
        sample = student.projects.first.tasks.where.not(file_uploaded_at: nil).first
        assert sample.submission_pdf_ready?
        assert File.binread(sample.final_pdf_path).start_with?('%PDF-1.4')
        original_ids = [User.ids, Unit.ids, Task.ids, UnitAnnouncement.ids, UnitLearningSession.ids]
        student.update!(nickname: 'My demo edit', email: 'edited@example.invalid')
        Unit.first.update!(description: 'A visitor edited this sample unit.')
        with_production { @scenario.run! }
        assert_equal original_ids, [User.ids, Unit.ids, Task.ids, UnitAnnouncement.ids, UnitLearningSession.ids]
        assert_equal 'My demo edit', student.reload.nickname
        assert_equal 'edited@example.invalid', student.email
        assert_empty PushSubscription.all
        assert_empty NotificationEmailJob.jobs
        assert_empty PushNotificationDeliveryJob.jobs
      ensure
        Unit.find_each(&:destroy!)
        Rails.application.config.student_work_dir = original_work_dir
      end
    end
  end

  private

  def with_production(configured_database: DemoData::PublicDemoScenario::DATABASE_NAME,
                      connected_database: DemoData::PublicDemoScenario::DATABASE_NAME, &block)
    Rails.stub(:env, ActiveSupport::StringInquirer.new('production')) do
      @scenario.stub(:configured_database_name, configured_database) do
        @scenario.stub(:connected_database_name, connected_database, &block)
      end
    end
  end

  def assert_normal_student_endpoints(student)
    add_auth_header_for(user: student)
    get '/api/projects'
    assert_equal 200, last_response.status, last_response.body
    other_project = User.find_by!(username: 'student_2').projects.first
    get "/api/projects/#{other_project.id}"
    assert_equal 403, last_response.status
    get '/api/users'
    assert_equal 403, last_response.status
    get '/api/unit_hub'
    assert_equal 200, last_response.status, last_response.body
    body = JSON.parse(last_response.body)
    assert_equal 4, body['announcements'].length
    assert_equal 4, body['sessions'].pluck('id').uniq.length
    get '/api/attention/staff'
    assert_empty JSON.parse(last_response.body)['units']
    put_json '/api/webcal', webcal: { enabled: true, include_learning_sessions: true }
    assert_equal 200, last_response.status, last_response.body
    guid = JSON.parse(last_response.body)['guid']
    clear_auth_header
    get "/api/webcal/#{guid}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Demo HelpHub'
  end

  def assert_normal_staff_endpoints(staff)
    add_auth_header_for(user: staff)
    get '/api/attention/staff'
    assert_equal 200, last_response.status, last_response.body
    totals = JSON.parse(last_response.body)['totals']
    assert_operator totals['awaiting_feedback_count'], :>, 0
    assert_operator totals['help_requested_count'], :>, 0
    assert_operator totals['extension_requested_count'], :>, 0
    assert_not staff.has_admin_capability?
    assert_not staff.has_convenor_capability?
  end
end
