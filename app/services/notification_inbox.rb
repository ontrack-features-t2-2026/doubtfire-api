# frozen_string_literal: true

# A bounded view of one recipient's history. Unit filtering follows the same
# task/comment/project and Unit Hub targets as Notification#target_ids, including
# older notifications which only stored a /projects/:id link. Resolve the unit in
# SQL so a filter never loads the recipient's entire history into Ruby.
class NotificationInbox
  UNIT_ID_SQL = <<~SQL.squish.freeze
    CASE notifications.notifiable_type
      WHEN 'UnitAnnouncement' THEN inbox_announcements.unit_id
      WHEN 'UnitLearningSession' THEN inbox_sessions.unit_id
      ELSE COALESCE(inbox_projects.unit_id, inbox_link_projects.unit_id)
    END
  SQL

  TARGET_JOINS = <<~SQL.squish.freeze
    LEFT JOIN tasks inbox_tasks
      ON notifications.notifiable_type = 'Task' AND inbox_tasks.id = notifications.notifiable_id
    LEFT JOIN task_comments inbox_comments
      ON notifications.notifiable_type = 'TaskComment' AND inbox_comments.id = notifications.notifiable_id
    LEFT JOIN tasks inbox_comment_tasks ON inbox_comment_tasks.id = inbox_comments.task_id
    LEFT JOIN projects inbox_projects
      ON inbox_projects.id = COALESCE(inbox_tasks.project_id, inbox_comment_tasks.project_id,
        CASE WHEN notifications.notifiable_type = 'Project' THEN notifications.notifiable_id END)
    LEFT JOIN projects inbox_link_projects
      ON inbox_projects.id IS NULL
      AND notifications.link REGEXP '^/projects/[0-9]+(/|$)'
      AND inbox_link_projects.id = CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(notifications.link, '/', 3), '/', -1) AS UNSIGNED)
    LEFT JOIN unit_announcements inbox_announcements
      ON notifications.notifiable_type = 'UnitAnnouncement' AND inbox_announcements.id = notifications.notifiable_id
    LEFT JOIN unit_learning_sessions inbox_sessions
      ON notifications.notifiable_type = 'UnitLearningSession' AND inbox_sessions.id = notifications.notifiable_id
  SQL

  def initialize(user, options)
    @history = user.notifications
    @options = options.symbolize_keys
  end

  def page
    # Capture the confirmation boundary before selecting rows. Arrivals after
    # this request cannot be included in a subsequent "Delete all" operation.
    through_id = @history.maximum(:id)
    scope = filtered(@history.where('notifications.id <= ?', through_id || 0))
    total = scope.count
    last_page = [((total - 1) / per_page) + 1, 1].max
    page_number = @options.fetch(:page, 1).clamp(1, last_page)
    {
      notifications: scope.order(created_at: :desc, id: :desc).offset((page_number - 1) * per_page).limit(per_page),
      total_count: total,
      page: page_number,
      per_page: per_page,
      unread_count: @history.unread.count,
      through_id: through_id,
      events: @history.distinct.order(:event).pluck(:event),
      units: units
    }
  end

  private

  def per_page
    @options.fetch(:per_page, 20)
  end

  def filtered(scope)
    scope = scope.unread if @options[:unread_only]
    scope = scope.where(notification_type: @options[:notification_type]) if @options[:notification_type].present?
    scope = scope.where(event: @options[:event]) if @options[:event].present?
    return scope if @options[:unit_id].blank?

    scope.joins(TARGET_JOINS).where("#{UNIT_ID_SQL} = ?", @options[:unit_id])
  end

  def units
    unit_ids = @history.joins(TARGET_JOINS).select(Arel.sql(UNIT_ID_SQL)).distinct
    Unit.where(id: unit_ids).order(:code, :id).pluck(:id, :code, :name).map do |id, code, name|
      { id: id, code: code, name: name }
    end
  end
end
