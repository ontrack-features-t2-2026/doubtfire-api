class Notification < ApplicationRecord
  belongs_to :user

  # What the notification is about: the comment, the task, or whatever record
  # the event happened to. Optional, because a `general` notification points at
  # nothing and because every row raised before this column existed has no
  # target. Polymorphic, because portfolio and extension events do not point at
  # a task.
  belongs_to :notifiable, polymorphic: true, optional: true

  # Notification categories. The first three map onto the existing user
  # preference columns (receive_task/feedback/portfolio_notifications) so that a
  # single category toggle gates every delivery channel (in-app, email, push).
  TYPES = %w[task feedback portfolio extension general].freeze

  # `notification_type` is the category the user's preferences switch on.
  # `event` is the specific thing that happened within that category, e.g.
  # 'task_comment_created'. It is free text so a new event ticket does not have
  # to edit this model, but it is required so every notification can be traced
  # back to the code that raised it.

  # Maps a notification type to the user preference column that gates it.
  # Types without an entry here are always delivered.
  PREFERENCE_FOR_TYPE = {
    'task' => :receive_task_notifications,
    'feedback' => :receive_feedback_notifications,
    'portfolio' => :receive_portfolio_notifications
  }.freeze

  validates :notification_type, presence: true, inclusion: { in: TYPES }
  validates :event, presence: true, length: { maximum: 255 }
  validates :message, presence: true, length: { maximum: 500 }
  validates :dedupe_key, length: { maximum: 191 }, allow_nil: true

  # Queue the email only once the transaction that created the notification has
  # committed. Several callers raise notifications from inside a transaction,
  # for example a tutorial enrolment being destroyed removes the student from
  # their group, and a worker that picked the job up before the commit could not
  # see the row yet.
  after_commit :queue_email_delivery, on: :create

  scope :unread, -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  def mark_read!
    update!(read_at: Time.zone.now) unless read?
  end

  PROJECT_LINK = %r{\A/projects/(\d+)(?:/|\z)}
  TASK_LINK = %r{\A/projects/\d+/dashboard/([^/]+)}

  TARGET_KEYS = %i[
    unit_id project_id student_id task_definition_id task_definition_abbr task_id comment_id group_id
  ].freeze

  # The ids a client needs to open the page this notification is about.
  #
  # Worked out when the notification is read, not stored, so a notification
  # raised before these fields existed still gets them, and a record deleted
  # since then comes back as nil rather than as an id that points at nothing.
  # The notifiable is used first, and the link fills in whatever it cannot
  # say, for example the project behind a group change or a new task.
  def target_ids
    @target_ids ||= resolve_target_ids
  end

  private

  def resolve_target_ids
    ids = TARGET_KEYS.index_with { nil }

    comment = notifiable if notifiable.is_a?(TaskComment)
    task = comment ? comment.task : (notifiable if notifiable.is_a?(Task))
    group = notifiable if notifiable.is_a?(Group)
    project = notifiable if notifiable.is_a?(Project)
    project ||= task&.project
    project ||= Project.find_by(id: Regexp.last_match(1)) if link.to_s =~ PROJECT_LINK

    ids[:comment_id] = comment&.id
    ids[:group_id] = group&.id
    return ids if project.nil?

    ids[:project_id] = project.id
    ids[:unit_id] = project.unit_id
    ids[:student_id] = project.user_id

    task_definition = task&.task_definition
    if task_definition.nil? && link.to_s =~ TASK_LINK
      abbreviation = CGI.unescape(Regexp.last_match(1))
      task_definition = project.unit.task_definitions.find_by(abbreviation: abbreviation)
    end
    return ids if task_definition.nil?

    ids[:task_definition_id] = task_definition.id
    ids[:task_definition_abbr] = task_definition.abbreviation
    ids[:task_id] = task&.id || project.tasks.where(task_definition_id: task_definition.id).pick(:id)
    ids
  end

  def queue_email_delivery
    NotificationService.queue_email(self)
  end
end
