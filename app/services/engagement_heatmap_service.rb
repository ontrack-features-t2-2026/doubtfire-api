class EngagementHeatmapService
  WINDOW_DAYS = 84

  def self.build(project:)
    new(project).build
  end

  def initialize(project)
    @project = project
  end

  def build
    end_date = Time.zone.today
    start_date = end_date - (WINDOW_DAYS - 1).days

    scoped_engagements = TaskEngagement
                         .joins(:task)
                         .where(tasks: { project_id: project.id })
                         .where(engagement_time: start_date.beginning_of_day..end_date.end_of_day)

    daily_counts_raw = scoped_engagements
                       .group("DATE(task_engagements.engagement_time)")
                       .count

    daily_counts = normalize_daily_count_keys(daily_counts_raw)

    days = (start_date..end_date).map do |date|
      date_str = date.strftime('%Y-%m-%d')
      {
        date: date_str,
        activity_count: daily_counts[date_str] || 0
      }
    end

    {
      project_id: project.id,
      unit_id: project.unit_id,
      range: {
        start_date: start_date.strftime('%Y-%m-%d'),
        end_date: end_date.strftime('%Y-%m-%d'),
        days: WINDOW_DAYS
      },
      days: days,
      summary: {
        tasks_completed: tasks_completed_count(scoped_engagements),
        active_days: days.count { |entry| entry[:activity_count] > 0 },
        current_streak: current_streak(days, start_date, end_date)
      }
    }
  end

  private

  attr_reader :project

  # Grouped DATE(...) keys vary by adapter (Date, String, Time). Normalize to
  # 'YYYY-MM-DD' strings so lookups match the day loop regardless of DB return type.
  def normalize_daily_count_keys(raw)
    raw.each_with_object(Hash.new(0)) do |(key, count), memo|
      memo[canonical_date_string(key)] += count
    end
  end

  def canonical_date_string(key)
    case key
    when Date
      key.strftime('%Y-%m-%d')
    when Time, ActiveSupport::TimeWithZone
      key.in_time_zone.to_date.strftime('%Y-%m-%d')
    else
      Date.parse(key.to_s).strftime('%Y-%m-%d')
    end
  end

  def tasks_completed_count(scoped_engagements)
    scoped_engagements
      .where(engagement: TaskStatus.complete.name)
      .distinct
      .count(:task_id)
  end

  def current_streak(days, start_date, end_date)
    counts_by_date = days.to_h { |entry| [Date.parse(entry[:date]), entry[:activity_count]] }
    streak_day = counts_by_date[end_date].to_i > 0 ? end_date : end_date - 1.day
    streak = 0

    while streak_day >= start_date && counts_by_date[streak_day].to_i > 0
      streak += 1
      streak_day -= 1.day
    end

    streak
  end
end
