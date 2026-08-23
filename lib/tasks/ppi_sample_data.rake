require_all 'lib/helpers'

namespace :db do
  desc 'Create deterministic, privacy-threshold-ready demo data for the Peer Progress Indicator dashboard'
  task ppi_sample_data: [:skip_prod, :environment] do
    Rails.logger.level = :info

    # ---- configuration -------------------------------------------------
    num_units = 2
    classes_per_unit = 2
    legacy_students_per_grade = 4
    grade_labels = { 0 => 'Pass', 1 => 'Credit', 2 => 'Distinction', 3 => 'HighDistinction' }.freeze
    grades = grade_labels.keys.freeze # [0, 1, 2, 3]
    num_tasks = 7 # within the requested 5-10 range
    weekdays = %w[Monday Tuesday Wednesday Thursday Friday].freeze

    # ---- helpers ---------------------------------------------------------

    def ppi_positive_integer_env!(name)
      value = Integer(ENV.fetch(name), 10)
      raise ArgumentError unless value.positive?

      value
    rescue KeyError, ArgumentError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    # Finds or creates a user with a fixed, deterministic username - safe to re-run.
    def ppi_find_or_create_user(username, first_name, last_name, role_id)
      existing = User.find_by(username: username)
      if existing
        existing.update!(role_id: role_id) if existing.role_id != role_id
        return existing
      end

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

    minimum_cohort_size = ppi_positive_integer_env!('DF_PPI_MINIMUM_COHORT_SIZE')
    stale_after_hours = ppi_positive_integer_env!('DF_PPI_STALE_AFTER_HOURS')
    if minimum_cohort_size < PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE
      raise ArgumentError,
            "DF_PPI_MINIMUM_COHORT_SIZE must be at least #{PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE}"
    end

    # Round up per class so the combined exact-grade cohort meets any valid
    # configured threshold. Local development uses 11 + 11 = 22 for a floor of 21.
    students_per_grade = minimum_cohort_size.fdiv(classes_per_unit).ceil
    baseline_students_per_grade = PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE.fdiv(classes_per_unit).ceil
    sample_start_date = Time.zone.now - 6.weeks
    sample_end_date = Time.zone.now + 7.weeks

    campus = Campus.first || Campus.create!(name: 'Online', mode: 'timetable', abbreviation: 'C', active: true)
    convenor = ppi_find_or_create_user('ppi_convenor', 'Peer', 'Convenor', Role.convenor_id)

    (1..num_units).each do |unit_num|
      code = "PPI100#{unit_num}"
      unit = Unit.find_or_initialize_by(code: code)
      unit.update!(
        name: "PPI Sample Unit #{unit_num}",
        description: 'Deterministic sample data for testing the Peer Progress Indicator dashboard. Not a real unit.',
        start_date: sample_start_date,
        end_date: sample_end_date,
        active: true,
        allow_flexible_dates: false,
        peer_progress_enabled: true
      )

      unless grades.all? { |target_grade| unit.grade_value?(target_grade) }
        raise "#{unit.code} must retain the four standard target grades for the PPI demo"
      end

      unit.employ_staff(convenor, Role.convenor)

      # All tasks are assigned regardless of a student's target grade (target_grade: 0 = Pass),
      # so every student in the unit has the same task list - needed to compare % completion
      # meaningfully across target-grade bands.
      task_defs = (1..num_tasks).map do |t|
        task_definition = unit.task_definitions.find_or_initialize_by(abbreviation: "T#{t}")
        task_definition.update!(
          name: "Task #{t}",
          description: "Sample task #{t} for PPI dashboard testing.",
          weighting: BigDecimal('1'),
          target_grade: 0,
          start_date: unit.start_date,
          target_date: unit.start_date + t.weeks,
          upload_requirements: [{ key: 'file0', name: 'Document', type: 'document' }]
        )
        task_definition
      end

      seeded_projects = []
      seeded_tasks = []

      (1..classes_per_unit).each do |class_num|
        tutor_username = "ppi_tutor_u#{unit_num}c#{class_num}"
        tutor = ppi_find_or_create_user(tutor_username, "Tutor#{unit_num}#{class_num}", 'PPI', Role.tutor_id)
        unit.employ_staff(tutor, Role.tutor)

        tutorial_abbrev = "PPI-U#{unit_num}-C#{class_num}"
        tutorial_capacity = students_per_grade * grades.length
        tutorial = unit.tutorials.find_by(abbreviation: tutorial_abbrev) || unit.add_tutorial(
          weekdays[class_num - 1],
          '10:00',
          "EN1-0#{class_num}",
          tutor,
          campus,
          tutorial_capacity,
          tutorial_abbrev
        )
        grades.each do |target_grade|
          students_per_grade.times do |i|
            # Keep the original four-per-grade usernames assigned to their
            # existing grade when this task repairs a previously seeded DB.
            if i < legacy_students_per_grade
              student_index = (target_grade * legacy_students_per_grade) + i + 1
              username = "ppi_u#{unit_num}c#{class_num}s#{student_index.to_s.rjust(2, '0')}"
            elsif i < baseline_students_per_grade
              legacy_total = grades.length * legacy_students_per_grade
              baseline_added_per_grade = baseline_students_per_grade - legacy_students_per_grade
              student_index = legacy_total + (target_grade * baseline_added_per_grade) +
                              (i - legacy_students_per_grade) + 1
              username = "ppi_u#{unit_num}c#{class_num}s#{student_index.to_s.rjust(2, '0')}"
            else
              student_index = 100 + (target_grade * 100) + i + 1
              username = "ppi_u#{unit_num}c#{class_num}g#{target_grade}s#{(i + 1).to_s.rjust(2, '0')}"
            end
            student = ppi_find_or_create_user(username, "Student#{student_index}", grade_labels[target_grade], Role.student_id)

            project = unit.enrol_student(student, campus)
            project.update!(target_grade: target_grade)
            project.enrol_in(tutorial)
            seeded_projects << project

            # Vary completion so percentages differ meaningfully both between tasks
            # and between target-grade bands:
            #  - higher target grade -> higher base completion rate
            #  - later tasks -> lower completion rate (fewer students have reached them)
            #  - a small per-student jitter spreads students within a grade band
            task_defs.each_with_index do |td, td_idx|
              task = project.task_for_task_definition(td)
              seeded_tasks << task
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

        repaired_capacity = [tutorial_capacity, tutorial.num_students].max
        tutorial.update!(capacity: repaired_capacity) if tutorial.capacity != repaired_capacity
      end

      cohort_sizes = grades.index_with do |target_grade|
        unit.active_projects.where(target_grade: target_grade).count
      end
      unless cohort_sizes.values.all? { |size| size >= minimum_cohort_size }
        raise "#{unit.code} PPI cohorts are below the configured threshold: #{cohort_sizes.inspect}"
      end

      expected_project_count = classes_per_unit * grades.length * students_per_grade
      unless unit.active? && unit.peer_progress_enabled? &&
             seeded_projects.uniq.count == expected_project_count &&
             seeded_projects.all? { |project| project.enrolled? && project.user.role_id == Role.student_id }
        raise "#{unit.code} PPI demo projects are not active student enrolments"
      end

      expected_task_count = expected_project_count * task_defs.length
      tasks_released = seeded_tasks.uniq.count == expected_task_count && seeded_tasks.all? do |task|
        task.local_start_date.present? &&
          task.local_start_date <= Time.zone.now &&
          task.task_definition.target_grade <= task.project.target_grade
      end
      unless task_defs.all? { |task_definition| task_definition.target_grade.zero? } && tasks_released
        raise "#{unit.code} PPI demo tasks are not released at the pass target grade"
      end

      snapshots = PeerProgressAggregationService.call(unit: unit)
      task_definition_ids = task_defs.map(&:id)
      demo_snapshots = snapshots.select do |snapshot|
        task_definition_ids.include?(snapshot.task_definition_id) && grades.include?(snapshot.target_grade)
      end
      expected_snapshot_count = task_defs.length * grades.length
      latest_grade_changes = grades.index_with do |target_grade|
        unit.active_projects.where(target_grade: target_grade).maximum(:target_grade_changed_at)
      end
      fresh_after = stale_after_hours.hours.ago

      snapshots_valid = demo_snapshots.count == expected_snapshot_count &&
                        demo_snapshots.map { |snapshot| [snapshot.task_definition_id, snapshot.target_grade] }.uniq.count == expected_snapshot_count &&
                        demo_snapshots.all? do |snapshot|
                          latest_change = latest_grade_changes.fetch(snapshot.target_grade)
                          snapshot.cohort_size == cohort_sizes.fetch(snapshot.target_grade) &&
                            !snapshot.submitted_percentage.nil? &&
                            snapshot.calculated_at >= fresh_after &&
                            (latest_change.nil? || snapshot.calculated_at >= latest_change)
                        end
      raise "#{unit.code} PPI demo snapshots failed post-seed validation" unless snapshots_valid

      puts "-> #{unit.code}: #{unit.tutorials.count} classes, #{unit.projects.count} students, " \
           "#{task_defs.count} tasks, cohorts #{cohort_sizes.inspect}, #{demo_snapshots.count} demo snapshots"
    end

    puts 'PPI sample dashboard data ready.'
  end
end
