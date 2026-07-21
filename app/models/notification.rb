class Notification < ApplicationRecord
  belongs_to :user

  # Notification categories. The first three map onto the existing user
  # preference columns (receive_task/feedback/portfolio_notifications) so that a
  # single category toggle gates every delivery channel (in-app, email, push).
  TYPES = %w[task feedback portfolio extension general].freeze

  # Maps a notification type to the user preference column that gates it.
  # Types without an entry here are always delivered.
  PREFERENCE_FOR_TYPE = {
    'task' => :receive_task_notifications,
    'feedback' => :receive_feedback_notifications,
    'portfolio' => :receive_portfolio_notifications
  }.freeze

  validates :notification_type, presence: true, inclusion: { in: TYPES }
  validates :message, presence: true, length: { maximum: 500 }

  scope :unread, -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  def mark_read!
    update!(read_at: Time.zone.now) unless read?
  end
end
