# frozen_string_literal: true

require 'test_helper'
require 'sidekiq_unique_jobs/testing'

class TiiCheckProgressJobTest < ActiveSupport::TestCase
  def test_jobs_are_scheduled
    # Clear fake jobs and any unique-job locks left by an earlier test run.
    Sidekiq::Job.clear_all
    Sidekiq::Cron::Job.destroy_all!
    Sidekiq::Cron::Job.load_from_hash!(
      YAML.load_file(Rails.root.join('config/schedule.yml'))
    )

    jobs = Sidekiq::Cron::Job.all
    peer_progress_job =
      jobs.find { |job| job.name == 'aggregate_peer_progress' }

    assert_equal 17, jobs.count, jobs.map(&:name)
    assert_not_nil peer_progress_job
    assert_equal 'AggregatePeerProgressJob', peer_progress_job.klass
    %w[send_daily_staff_attention send_weekly_staff_attention].each do |name|
      staff_job = jobs.find { |job| job.name == name }
      assert_not_nil staff_job, "Missing opted-in teaching summary schedule: #{name}"
      assert_equal 'SendStaffAttentionSummariesJob', staff_job.klass
    end

    # Sidekiq::Cron::Job.all returns an Array, not an ActiveRecord relation.
    jobs.each(&:enqueue!)

    assert_equal 1, TiiRegisterWebHookJob.jobs.count
    assert_equal 1, TiiCheckProgressJob.jobs.count
    assert_equal 1, ClearAccessTokensJob.jobs.count
    assert_equal 1, RefreshModerationFeedbackTimestampsJob.jobs.count
    assert_equal 1, AggregatePeerProgressJob.jobs.count
    assert_equal 1, AggregateTaskCompletionStatsJob.jobs.count
    assert_equal 1, PollCommunicationSetSchedulesJob.jobs.count
    assert_equal 1, SendNewTaskAvailableNotificationsJob.jobs.count
    assert_equal 1, SendDueSoonRemindersJob.jobs.count
    assert_equal 1, CheckUnitSimilarityJob.jobs.count
    assert_equal 1, SyncTeamsAnnouncementsJob.jobs.count
    assert_equal 1, SendUnitSessionRemindersJob.jobs.count
    # One student digest run per cadence a student can choose.
    assert_equal %w[daily monthly weekly], SendDigestEmailsJob.jobs.map { |job| job['args'].first }.sort
    # Teaching summaries have their own explicit opt-in and cadence choices.
    assert_equal %w[daily weekly], SendStaffAttentionSummariesJob.jobs.map { |job| job['args'].first }.sort
    # assert_equal 1, ArchiveOldUnitsJob.jobs.count
  end
end
