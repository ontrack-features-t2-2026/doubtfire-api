require_all 'lib/helpers'

namespace :db do
  desc 'Create a small, deterministic sample dataset for testing the Peer Progress Indicator dashboard'
  task ppi_sample_data: [:skip_prod, :environment] do
    Rails.logger.level = :info

    # ---- configuration -------------------------------------------------
    num_units = 2
    classes_per_unit = 2
    students_per_grade = 4
    grade_labels = { 0 => 'Pass', 1 => 'Credit', 2 => 'Distinction', 3 => 'HighDistinction' }.freeze
    grades = grade_labels.keys.freeze # [0, 1, 2, 3]
    num_tasks = 7 # within the requested 5-10 range
    weekdays = %w[Monday Tuesday Wednesday Thursday Friday].freeze

    # ---- helpers ---------------------------------------------------------

    # Finds or creates a user with a fixed, deterministic username - safe to re-run.
    def ppi_find_or_create_user(username, first_name, last_name, role_id)
      existing = User.find_by(username: username)
      return existing if existing

      profile = {
        first_name: first_name,
        last_name: last_name,
        nickname: username,
        role_id: role_id,
        email: "#{username}@doubtfire.com",
        username: username
      }
      unless AuthenticationHelpers.aaf_auth?
        profile[:password] = 'password'
        profile[:password_confirmation] = 'password'
      end
      User.create!(profile)
    end

    campus = Campus.first || Campus.create!(name: 'Online', mode: 'timetable', abbreviation: 'C', active: true)
    convenor = ppi_find_or_create_user('ppi_convenor', 'Peer', 'Convenor', Role.convenor_id)

    (1..num_units).each do |unit_num|
      code = "PPI100#{unit_num}"
      unit = Unit.find_by(code: code) || Unit.create!(
        code: code,
        name: "PPI Sample Unit #{unit_num}",
        description: 'Deterministic sample data for testing the Peer Progress Indicator dashboard. Not a real unit.',
        start_date: Time.zone.now - 6.weeks,
        end_date: Time.zone.now + 7.weeks
      )

      unit.employ_staff(convenor, Role.convenor)

      # All tasks are assigned regardless of a student's target grade (target_grade: 0 = Pass),
      # so every student in the unit has the same task list - needed to compare % completion
      # meaningfully across target-grade bands.
      task_defs = (1..num_tasks).map do |t|
        unit.task_definitions.find_by(abbreviation: "T#{t}") || TaskDefinition.create!(
          unit_id: unit.id,
          name: "Task #{t}",
          abbreviation: "T#{t}",
          description: "Sample task #{t} for PPI dashboard testing.",
          weighting: BigDecimal('1'),
          target_grade: 0,
          start_date: unit.start_date,
          target_date: unit.start_date + t.weeks,
          upload_requirements: [{ key: 'file0', name: 'Document', type: 'document' }]
        )
      end

      (1..classes_per_unit).each do |class_num|
        tutor_username = "ppi_tutor_u#{unit_num}c#{class_num}"
        tutor = ppi_find_or_create_user(tutor_username, "Tutor#{unit_num}#{class_num}", 'PPI', Role.tutor_id)
        unit.employ_staff(tutor, Role.tutor)

        tutorial_abbrev = "PPI-U#{unit_num}-C#{class_num}"
        tutorial = unit.tutorials.find_by(abbreviation: tutorial_abbrev) || unit.add_tutorial(
          weekdays[class_num - 1],
          '10:00',
          "EN1-0#{class_num}",
          tutor,
          campus,
          students_per_grade * grades.length,
          tutorial_abbrev
        )

        student_index = 0

        grades.each do |target_grade|
          students_per_grade.times do |i|
            student_index += 1
            username = "ppi_u#{unit_num}c#{class_num}s#{student_index.to_s.rjust(2, '0')}"
            student = ppi_find_or_create_user(username, "Student#{student_index}", grade_labels[target_grade], Role.student_id)

            project = unit.enrol_student(student, campus)
            project.update!(target_grade: target_grade)
            project.enrol_in(tutorial)

            # Vary completion so percentages differ meaningfully both between tasks
            # and between target-grade bands:
            #  - higher target grade -> higher base completion rate
            #  - later tasks -> lower completion rate (fewer students have reached them)
            #  - a small per-student jitter spreads the 4 students within a grade band
            task_defs.each_with_index do |td, td_idx|
              task = project.task_for_task_definition(td)
              next unless task.task_status_id == TaskStatus.not_started.id # skip on re-run

              base_completion = (target_grade + 1) / grades.length.to_f # 0.25, 0.5, 0.75, 1.0
              task_decay = 1.0 - ((td_idx.to_f / task_defs.length) * 0.4)
              student_jitter = (i - ((students_per_grade - 1) / 2.0)) * 0.05
              completion_chance = ((base_completion * task_decay) + student_jitter).clamp(0.05, 0.98)

              seed = (student_index * 13) + (td_idx * 7) + (unit_num * 31) + (class_num * 17)
              roll = (seed % 100) / 100.0

              if roll < completion_chance
                complete_date = [unit.start_date + (td_idx + 1).weeks + rand(0..3).days, Time.zone.now].min
                DatabasePopulator.assess_task(project, task, tutor, TaskStatus.complete, complete_date)
              elsif roll < completion_chance + 0.15
                DatabasePopulator.assess_task(project, task, tutor, TaskStatus.working_on_it, Time.zone.now)
              end
              # otherwise left as not_started (the Task.create! default)
            end

            project.update_task_stats
          end
        end
      end

      puts "-> #{unit.code}: #{unit.tutorials.count} classes, #{unit.projects.count} students, #{task_defs.count} tasks"
    end

    puts 'PPI sample dashboard data ready.'
  end
end
