# frozen_string_literal: true

require Rails.root.join('lib/demo_data/all_features_scenario')

module DemoData
  # Uses the existing synthetic task/cohort builders, not the local walkthrough
  # registry. Public demo users exercise ordinary production API endpoints.
  # Preparation never drops, resets or replaces an existing database.
  class PublicDemoScenario < AllFeaturesScenario
    DATABASE_NAME = 'doubtfire-public-demo'
    PROFILE_NAME = 'public-demo'
    STUDENT_USERNAMES = (1..25).map { |number| "student_#{number}" }.freeze
    STAFF_USERNAMES = %w[staff_1 staff_2].freeze
    CHAIR_USERNAME = 'chair_1'
    USERNAMES = [*STUDENT_USERNAMES, *STAFF_USERNAMES, CHAIR_USERNAME].freeze
    CAMPUS_ABBREVIATION = 'PUBDEMO'
    MARKER = 'Synthetic public OnTrack demo. Contains no real student data.'
    BOOTSTRAP_KEY = 'ontrack_public_demo_bootstrap'
    PENDING_STATE = 'preparing-v1'
    COMPLETE_STATE = 'complete-v1'

    def guard!
      raise SafetyError, 'Public demo preparation requires Rails production.' unless Rails.env.production?
      unless ENV.fetch('DF_DEMO_DATA_PROFILE', nil) == PROFILE_NAME
        raise SafetyError, 'Set DF_DEMO_DATA_PROFILE=public-demo for this dedicated installation.'
      end
      unless configured_database_name == DATABASE_NAME && connected_database_name == DATABASE_NAME
        raise SafetyError, "Public demo preparation requires configured and connected database #{DATABASE_NAME}."
      end
      unless AuthenticationHelpers.db_auth?
        raise SafetyError, 'Public demo accounts require database authentication.'
      end
      unless mail_capture_configured?
        raise SafetyError, 'Public demo mail must use SMTP mailpit:1025; external SMTP is not allowed.'
      end
      if ENV.fetch('DF_TEAMS_ANNOUNCEMENTS_ENABLED', 'false').to_s.match?(/\A(?:true|1)\z/i)
        raise SafetyError, 'Public demo cannot connect to institutional Teams announcements.'
      end
      true
    end

    def prepare!
      guard!
      connection = ActiveRecord::Base.connection
      empty_database = connection.data_sources.empty?
      unless empty_database || [PENDING_STATE, COMPLETE_STATE].include?(bootstrap_state)
        raise SafetyError, 'Refusing an existing database without the public-demo bootstrap marker.'
      end
      previous_skip = ENV.fetch('SKIP_TEST_DATABASE', nil)
      begin
        ENV['SKIP_TEST_DATABASE'] = 'true'
        # Only a truly empty database can load the current schema. A failed
        # migration never falls back to schema:load and cannot erase records.
        Rake::Task[empty_database ? 'db:schema:load' : 'db:migrate'].invoke
        write_bootstrap_state(PENDING_STATE) if empty_database
        User.reset_column_information
        Rake::Task['db:init_reference_data'].invoke
        run!
      ensure
        previous_skip.nil? ? ENV.delete('SKIP_TEST_DATABASE') : ENV['SKIP_TEST_DATABASE'] = previous_skip
      end
    end

    def run!
      guard!
      return verify! if bootstrap_state == COMPLETE_STATE
      unless bootstrap_state == PENDING_STATE
        raise SafetyError, 'Refusing an existing database without the public-demo bootstrap marker.'
      end
      if User.exists? || Unit.exists?
        raise SafetyError, 'Incomplete public-demo bootstrap contains records; refusing to replace them.'
      end

      ActiveRecord::Base.transaction do
        create_public_scenario!
        verify_fresh_dataset!
        write_bootstrap_state(COMPLETE_STATE)
      end
      verify!
    end

    def verify!
      guard!
      unless bootstrap_state == COMPLETE_STATE
        raise SafetyError, 'Public demo bootstrap has not completed.'
      end
      summary
    end

    private

    def verify_fresh_dataset!
      guard_dataset!
      unless User.where(username: USERNAMES).count == USERNAMES.length && Unit.where(code: UNIT_CODES).count == UNIT_CODES.length
        raise SafetyError, 'Public demo is incomplete; preparation will not overwrite a partial or changed installation.'
      end
      student = User.find_by!(username: STUDENT_USERNAMES.first)
      unless student.projects.exists? && UnitAnnouncement.exists? && UnitLearningSession.exists?
        raise SafetyError, 'Public demo is missing its projects or published Unit Hub content.'
      end
      true
    end

    def summary
      {
        profile: PROFILE_NAME,
        users: User.count,
        students: User.where(role: Role.student).count,
        tutors: User.where(role: Role.tutor).count,
        convenors: User.where(role: Role.convenor).count,
        units: Unit.count,
        projects: Project.count,
        tasks: Task.count,
        announcements: UnitAnnouncement.count,
        sessions: UnitLearningSession.count
      }
    end

    def configured_database_name
      ActiveRecord::Base.connection_db_config.database
    end

    def metadata
      ActiveRecord::InternalMetadata.new(ActiveRecord::Base.connection_pool)
    end

    def bootstrap_state
      metadata[BOOTSTRAP_KEY] if metadata.table_exists?
    end

    def write_bootstrap_state(state)
      metadata[BOOTSTRAP_KEY] = state
    end

    def mail_capture_configured?
      config = Rails.application.config.action_mailer
      smtp = config.smtp_settings || {}
      config.delivery_method.to_s == 'smtp' && smtp[:address] == 'mailpit' && smtp[:port].to_i == 1025
    end

    # Names alone are insufficient: refuse real-looking identities or unrelated
    # records even if an operator accidentally chose the dedicated DB name.
    def guard_dataset!
      connection = ActiveRecord::Base.connection
      unless connection.data_source_exists?('users') && connection.data_source_exists?('units')
        raise SafetyError, 'Public demo database has a partial schema; inspect it before continuing.'
      end
      if User.where.not(username: USERNAMES).exists? || Unit.where.not(code: UNIT_CODES).exists?
        raise SafetyError, 'Public demo database contains unexpected accounts or units; refusing to change it.'
      end
      User.find_each do |user|
        expected_role = if STUDENT_USERNAMES.include?(user.username)
                          Role.student
                        elsif STAFF_USERNAMES.include?(user.username)
                          Role.tutor
                        else
                          Role.convenor
                        end
        unless user.email == "#{user.username}@example.invalid" && user.role_id == expected_role.id
          raise SafetyError, 'Public demo identities or roles differ from the synthetic profile; refusing to change them.'
        end
      end
      if Unit.where.not(description: MARKER).exists?
        raise SafetyError, 'Public demo units are not marked synthetic; refusing to change them.'
      end
    end

    def create_public_scenario!
      ensure_reference_data!
      campus = Campus.create!(name: 'Public Demo Campus', abbreviation: CAMPUS_ABBREVIATION,
                              mode: :manual, active: true, timezone: 'Australia/Melbourne')
      chair = create_user!(username: CHAIR_USERNAME, first_name: 'Demo', last_name: 'Chair', role: Role.convenor)
      tutors = STAFF_USERNAMES.each_with_index.map do |username, index|
        create_user!(username: username, first_name: 'Demo', last_name: "Tutor #{index + 1}", role: Role.tutor)
      end
      students = STUDENT_USERNAMES.each_with_index.map do |username, index|
        create_user!(username: username, first_name: 'Demo', last_name: "Student #{index + 1}",
                     role: Role.student, student_id: "PUBLIC-DEMO-#{index + 1}")
      end
      units = UNIT_CODES.index_with do |code|
        create_unit!(code: code, convenor: chair).tap { |unit| unit.update!(description: MARKER) }
      end
      main_projects = units.transform_values do |unit|
        enrol!(unit: unit, student: students.first, campus: campus).tap { |project| materialise_demo_tasks!(project) }
      end
      peer_projects = create_ppi_cohorts!(units: units, peers: students.drop(1), campus: campus)
      units.each_value { |unit| assign_tutorials!(unit, campus, tutors) }
      CURRENT_UNIT_CODES.each do |code|
        unit = units.fetch(code)
        aggregate_peer_progress!(unit)
        create_hub_content!(unit, chair)
      end
      create_group_hook!(unit: units.fetch(MobileFeedbackScenario::GROUP.fetch(:unit_code)), campus: campus,
                         convenor: chair, demo_project: main_projects.fetch(MobileFeedbackScenario::GROUP.fetch(:unit_code)),
                         peer_projects: peer_projects.fetch(MobileFeedbackScenario::GROUP.fetch(:unit_code)).first(2))
      create_submission_samples!
      create_feedback!(main_projects.fetch(PPI_UNIT_CODE), tutors.first)
      create_attention_examples!(main_projects.fetch(PPI_UNIT_CODE), tutors.first)
      students.each_with_index do |student, index|
        blueprints = if index.zero?
                       MobileFeedbackScenario::NOTIFICATIONS.reject { |item| item[:event] == 'portfolio_received' }
                     else
                       MobileFeedbackScenario::NOTIFICATIONS.select { |item| item[:event] == SendDueSoonRemindersJob::EVENT }
                     end
        create_notifications!(student, blueprints: blueprints)
      end
    end

    def create_user!(**attributes)
      super(**attributes).tap { |user| user.update!(email: "#{user.username}@example.invalid") }
    end

    def assign_tutorials!(unit, campus, tutors)
      tutorials = tutors.each_with_index.map do |tutor, index|
        role = unit.employ_staff(tutor, Role.tutor)
        Tutorial.create!(unit: unit, unit_role: role, campus: campus, abbreviation: "DEMO-T#{index + 1}",
                         meeting_day: 'Tuesday', meeting_time: '10:00', meeting_location: 'Synthetic demo room')
      end
      unit.active_projects.includes(:user).find_each do |project|
        number = project.student.username.delete_prefix('student_').to_i
        project.enrol_in(tutorials[(number - 1) % tutorials.length])
      end
    end

    def create_hub_content!(unit, author)
      local_start = reference_time.in_time_zone('Australia/Melbourne').change(hour: 10) + 2.days
      unit.unit_announcements.create!(author: author, title: "Welcome to #{unit.code}", body: MARKER,
                                      pinned: true, published_at: reference_time - 1.day)
      unit.unit_learning_sessions.create!(author: author, title: 'Demo HelpHub', description: 'A sample study session; no real meeting.',
                                          kind: 'helphub', start_at: local_start,
                                          end_at: local_start + 1.hour, timezone: 'Australia/Melbourne',
                                          location: 'Demo room', recurrence: 'weekly', recurrence_until: (reference_time + 6.weeks).to_date,
                                          published: true, cancelled: false)
    end

    def create_submission_samples!
      Task.where.not(file_uploaded_at: nil).includes(:task_definition, project: :user).find_each do |task|
        bytes = synthetic_pdf("Synthetic submission: #{task.project.student.username} / #{task.task_definition.abbreviation}")
        File.binwrite(task.final_pdf_path, bytes)
        File.binwrite(File.join(task.student_work_dir(:done), '001-Demo-document.pdf'), bytes)
        task.update!(submission_processing_state: 'ready', submission_processing_finished_at: reference_time)
      end
    end

    def create_feedback!(project, tutor)
      %w[AWAITING RESUBMIT REDO].each do |abbreviation|
        task = project.tasks.joins(:task_definition).find_by!(task_definitions: { abbreviation: abbreviation })
        task.add_text_comment(tutor, 'Synthetic feedback: explain your reasoning, check the example, then update your submission.')
      end
    end

    def create_attention_examples!(project, tutor)
      project.tasks.joins(:task_definition).find_by!(task_definitions: { abbreviation: 'OVERDUE' }).update!(task_status: TaskStatus.need_help)
      project.tasks.joins(:task_definition).find_by!(task_definitions: { abbreviation: 'AWAITING' }).update!(submission_date: reference_time - 10.days)
      task = project.tasks.joins(:task_definition).find_by!(task_definitions: { abbreviation: 'WORK' })
      task.update!(extensions: 1)
      ExtensionComment.create!(task: task, user: project.student, recipient: tutor, assessor: tutor,
                               content_type: :extension, comment: 'Synthetic approved extension example.',
                               extension_weeks: 1, extension_granted: true, date_extension_assessed: reference_time - 1.day,
                               extension_response: 'One additional week granted for this sample task.')
      pending = project.tasks.joins(:task_definition).find_by!(task_definitions: { abbreviation: 'DUE3' })
      ExtensionComment.create!(task: pending, user: project.student, recipient: tutor, content_type: :extension,
                               comment: 'Synthetic request awaiting a tutor response.', extension_weeks: 1)
    end

    # A tiny valid PDF produced without TeX, external commands or bundled real
    # submissions. Real uploads still use the normal submission worker.
    def synthetic_pdf(label)
      content = "BT /F1 14 Tf 50 750 Td (#{label}) Tj ET\n"
      objects = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
      ]
      pdf = +"%PDF-1.4\n"
      offsets = [0]
      objects.each_with_index do |object, index|
        offsets << pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      end
      start = pdf.bytesize
      pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
      offsets.drop(1).each { |offset| pdf << format('%010d 00000 n ', offset) << "\n" }
      pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{start}\n%%EOF\n"
    end
  end
end
