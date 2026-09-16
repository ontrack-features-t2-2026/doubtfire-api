namespace :mailer do
  # CADENCE picks which students are in scope: it must match their chosen
  # digest_frequency. Defaults to weekly, which is what cron has always run.
  task send_status_emails: :environment do
    summary_stats = {}

    cadence = ENV.fetch('CADENCE', 'weekly')
    raise ArgumentError, "CADENCE must be one of #{User::DIGEST_FREQUENCIES.join(', ')}" unless User::DIGEST_FREQUENCIES.include?(cadence)

    summary_stats[:cadence] = cadence

    summary_stats[:week_end] = Time.zone.now
    summary_stats[:week_start] = summary_stats[:week_end] - { 'daily' => 1.day, 'weekly' => 7.days, 'monthly' => 1.month }.fetch(cadence, 7.days)
    summary_stats[:weeks_comments] = TaskComment.where("created_at >= :start AND created_at < :end", start: summary_stats[:week_start], end: summary_stats[:week_end]).count
    summary_stats[:weeks_engagements] = TaskEngagement.where("engagement_time >= :start AND engagement_time < :end", start: summary_stats[:week_start], end: summary_stats[:week_end]).count

    Unit.where(active: true).find_each do |unit|
      next unless summary_stats[:week_end] > unit.start_date && summary_stats[:week_start] < unit.end_date

      unit.send_weekly_status_emails(summary_stats)
    end
  end
end
