require 'test_helper'

class SubmissionProcessingStateTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  def setup
    @task = FactoryBot.create(:task)
  end

  def test_active_queue_becomes_finite_timed_out_state
    @task.update!(
      submission_processing_state: 'queued',
      submission_processing_started_at: 11.minutes.ago
    )

    @task.stub(:submission_pdf_ready?, false) do
      @task.stub(:submission_files_ready?, true) do
        snapshot = @task.submission_processing_snapshot

        assert_equal 'timed_out', snapshot[:processing_state]
        assert_not snapshot[:processing_pdf]
        assert snapshot[:retryable]
        assert snapshot[:submission_files_ready]
      end
    end
  end

  def test_ready_snapshot_reports_each_real_artifact_independently
    @task.update!(submission_processing_state: 'ready')

    @task.stub(:submission_pdf_ready?, true) do
      @task.stub(:submission_files_ready?, true) do
        snapshot = @task.submission_processing_snapshot

        assert_equal 'ready', snapshot[:processing_state]
        assert snapshot[:has_pdf]
        assert snapshot[:pdf_ready]
        assert snapshot[:submission_files_ready]
        assert_not snapshot[:retryable]
      end
    end
  end

  def test_previous_attempt_pdf_is_not_ready_for_a_new_attempt
    Dir.mktmpdir do |directory|
      pdf_path = File.join(directory, 'submission.pdf')
      File.write(pdf_path, 'old submission')
      old_time = 5.minutes.ago
      File.utime(old_time.to_time, old_time.to_time, pdf_path)
      @task.update!(submission_processing_started_at: Time.current)

      @task.stub(:final_pdf_path, pdf_path) do
        assert_not @task.submission_pdf_ready?
      end
    end
  end

  def test_current_attempt_pdf_completes_a_stale_rolling_deploy_state
    @task.update!(
      submission_processing_state: 'queued',
      submission_processing_started_at: 1.minute.ago
    )

    @task.stub(:submission_pdf_ready?, true) do
      @task.stub(:processing_pdf?, false) do
        assert_equal 'ready', @task.effective_submission_processing_state
      end
    end
  end

  def test_marking_a_new_attempt_clears_failure_and_increments_attempts
    @task.update!(
      submission_processing_state: 'failed',
      submission_processing_error_code: 'conversion_failed',
      submission_processing_attempts: 1
    )

    @task.mark_submission_processing!('queued', now: Time.zone.parse('2026-08-31 10:00:00'))
    @task.reload

    assert_equal 'queued', @task.submission_processing_state
    assert_equal 2, @task.submission_processing_attempts
    assert_nil @task.submission_processing_error_code
    assert_nil @task.submission_processing_finished_at
    assert_equal Time.zone.parse('2026-08-31 10:00:00'), @task.submission_processing_started_at
  end

  def test_retry_requeues_only_the_preserved_submission_archive
    user = @task.project.student
    queued = false

    @task.stub(:submission_processing_retryable?, true) do
      @task.stub(:folder_exists_in_new?, false) do
        @task.stub(:folder_exists_in_process?, false) do
          @task.stub(:submission_files_ready?, true) do
            AcceptSubmissionJob.stub(:perform_async, lambda { |task_id, user_id, _tii, _test, processing_mode|
              queued = task_id == @task.id && user_id == user.id && processing_mode == 'retry_archive'
              'job-id'
            }) do
              @task.retry_submission_processing!(user)
            end
          end
        end
      end
    end

    assert queued
    assert_equal 'queued', @task.reload.submission_processing_state
  end

  def test_timed_out_unprocessed_upload_can_requeue_its_staged_files
    user = @task.project.student
    queued_without_regeneration = false

    @task.stub(:submission_processing_retryable?, true) do
      @task.stub(:folder_exists_in_new?, true) do
        @task.stub(:folder_exists_in_process?, false) do
          AcceptSubmissionJob.stub(:perform_async, lambda { |_task_id, _user_id, _tii, _test, processing_mode|
            queued_without_regeneration = processing_mode == 'process'
            'job-id'
          }) do
            @task.retry_submission_processing!(user)
          end
        end
      end
    end

    assert queued_without_regeneration
  end

  def test_queue_conflict_rolls_back_retry_state
    user = @task.project.student
    @task.update!(
      submission_processing_state: 'failed',
      submission_processing_error_code: 'conversion_failed',
      submission_processing_attempts: 2
    )

    @task.stub(:submission_processing_retryable?, true) do
      @task.stub(:folder_exists_in_new?, true) do
        @task.stub(:folder_exists_in_process?, false) do
          AcceptSubmissionJob.stub(:perform_async, nil) do
            assert_raises(ArgumentError) { @task.retry_submission_processing!(user) }
          end
        end
      end
    end

    @task.reload
    assert_equal 'failed', @task.submission_processing_state
    assert_equal 2, @task.submission_processing_attempts
    assert_equal 'conversion_failed', @task.submission_processing_error_code
  end

  def test_failed_archive_extraction_preserves_existing_work_directories
    Dir.mktmpdir do |directory|
      new_path = File.join(directory, 'new', @task.id.to_s)
      in_process_path = File.join(directory, 'in_process', @task.id.to_s)
      zip_path = File.join(directory, 'submission.zip')
      FileUtils.mkdir_p(new_path)
      FileUtils.mkdir_p(in_process_path)
      File.write(File.join(new_path, 'new-marker'), 'new')
      File.write(File.join(in_process_path, 'processing-marker'), 'processing')
      File.write(zip_path, 'not a zip archive')

      work_dir = lambda do |type, _create = true|
        type == :new ? "#{new_path}/" : "#{in_process_path}/"
      end

      @task.stub(:zip_file_path_for_done_task, zip_path) do
        @task.stub(:student_work_dir, work_dir) do
          assert_raises(Zip::Error) { @task.prepare_submission_regeneration! }
        end
      end

      assert File.file?(File.join(new_path, 'new-marker'))
      assert File.file?(File.join(in_process_path, 'processing-marker'))
    end
  end

  def test_group_member_uses_the_submitter_as_processing_identity
    unit = FactoryBot.create(
      :unit,
      group_sets: 1,
      groups: [{ gs: 0, students: 2 }],
      student_count: 2,
      unenrolled_student_count: 0,
      part_enrolled_student_count: 0,
      inactive_student_count: 0,
      task_count: 0
    )
    task_definition = FactoryBot.create(
      :task_definition,
      unit: unit,
      group_set: unit.group_sets.first
    )
    group = unit.groups.first
    submitter_project, member_project = group.projects.first(2)
    submitter = submitter_project.task_for_task_definition(task_definition)
    member = member_project.task_for_task_definition(task_definition)
    group_submission = GroupSubmission.create!(
      group: group,
      task_definition: task_definition,
      submitted_by_project: submitter_project
    )
    submitter.update!(group_submission: group_submission)
    member.update!(group_submission: group_submission)

    assert_equal submitter.id, member.submission_processing_task.id
    assert_equal group.id, member.submission_processing_lock_target.id

    member.mark_submission_processing!('queued', now: Time.zone.parse('2026-08-31 12:00:00'))

    [submitter, member].each do |task|
      task.reload
      assert_equal 'queued', task.submission_processing_state
      assert_equal 1, task.submission_processing_attempts
      assert_equal Time.zone.parse('2026-08-31 12:00:00'), task.submission_processing_started_at
    end
  end

  def test_submission_job_uses_the_dedicated_queue
    assert_equal :submissions, AcceptSubmissionJob.get_sidekiq_options['queue']
  end
end
