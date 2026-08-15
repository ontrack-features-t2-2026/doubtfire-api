# frozen_string_literal: true

class NewTaskAvailableNotificationJob
  include Sidekiq::Job

  BATCH_SIZE = 100
  EVENT = 'new_task_available'
  TYPE = 'task'

  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { [args.first] },
                  on_conflict: :reject,
                  retry: 3

  def perform(task_definition_id)
    task_definition = TaskDefinition.find_by(id: task_definition_id)
    return if task_definition.nil?

    unit = task_definition.unit
    return unless unit.active

    failed_project_ids = []

    unit.projects
        .where(enrolled: true)
        .includes(:user)
        .find_each(batch_size: BATCH_SIZE) do |project|
      notify_project(project, task_definition)
    rescue StandardError => e
      failed_project_ids << project.id

      Rails.logger.error(
        "Failed new-task notification for TaskDefinition #{task_definition.id}, " \
        "Project #{project.id}: #{e.class} - #{e.message}"
      )
    end

    return if failed_project_ids.empty?

    raise "New-task notifications failed for projects: #{failed_project_ids.join(', ')}"
  end

  private

  def notify_project(project, task_definition)
    return if project.target_grade.nil?
    return if task_definition.target_grade > project.target_grade

    task = project.task_for_task_definition(task_definition)
    return if task.nil?

    # A newly created task is only available when the student's effective
    # start date has arrived. Task#local_start_date includes flexible,
    # grade-specific and student-specific date adjustments.
    return if task.local_start_date.to_date > Time.zone.today

    student = project.student
    link = "/projects/#{project.id}/dashboard/#{task_definition.abbreviation}"

    # Protect against the fan-out job being run more than once.
    return if Notification.exists?(
      user_id: student.id,
      notification_type: TYPE,
      event: EVENT,
      link: link
    )

    NotificationService.notify(
      user: student,
      type: TYPE,
      event: EVENT,
      message: "A new task is available: #{task_definition.abbreviation} in #{task_definition.unit.code}.",
      link: link
    )
  end
end
