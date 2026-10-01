# frozen_string_literal: true

# Account-local teaching attention. No student names, feedback or submission
# content leave this summary; the existing inbox authorises every drill-down.
class StaffAttentionService
  COUNT_KEYS = %i[awaiting_feedback_count help_requested_count extension_requested_count overdue_feedback_count].freeze

  def initialize(user)
    @user = user
  end

  def call
    units = @user.unit_roles.includes(unit: { teaching_period: :breaks }).filter_map do |unit_role|
      unit = unit_role.unit
      next unless unit.active && !unit_role.observer_only
      next unless unit_role.is_tutor? || unit_role.is_convenor?
      next unless AuthorisationHelpers.authorise?(@user, unit, :get_students)

      summary(unit, unit_role)
    end
    units.uniq! { |row| row[:unit_id] }
    totals = COUNT_KEYS.index_with { |key| units.sum { |row| row[key] } }
    totals[:oldest_wait_days] = units.map { |row| row[:oldest_wait_days] }.max || 0
    { units: units, totals: totals }
  end

  private

  def summary(unit, unit_role)
    tasks = unit.student_tasks
    unless unit_role.is_convenor?
      # Match this task's tutorial stream, not every task of a student taught
      # by this tutor in a different stream. Tutors without assignments see 0.
      tasks = tasks.joins(project: { tutorial_enrolments: :tutorial })
                   .where(tutorials: { unit_role_id: unit_role.id })
                   .where('tutorials.tutorial_stream_id = task_definitions.tutorial_stream_id OR tutorials.tutorial_stream_id IS NULL')
    end
    task_ids = tasks.distinct.select('tasks.id')
    visible_tasks = Task.where(id: task_ids)
    waiting = visible_tasks.where(task_status_id: TaskStatus.ready_for_feedback.id)
                           .includes(project: { unit: { teaching_period: :breaks } }).to_a
    waits = waiting.map(&:days_awaiting_feedback)
    threshold = unit.feedback_warning_threshold_days.to_i
    {
      unit_id: unit.id,
      unit_code: unit.code,
      unit_name: unit.name,
      queue_scope: unit_role.is_convenor? ? 'all' : 'mine',
      awaiting_feedback_count: waiting.length,
      help_requested_count: visible_tasks.where(task_status_id: TaskStatus.need_help.id).count,
      extension_requested_count: ExtensionComment.where(task_id: task_ids, date_extension_assessed: nil).distinct.count(:task_id),
      oldest_wait_days: waits.max || 0,
      overdue_feedback_count: waits.count { |days| days >= threshold },
      feedback_warning_threshold_days: threshold
    }
  end
end
