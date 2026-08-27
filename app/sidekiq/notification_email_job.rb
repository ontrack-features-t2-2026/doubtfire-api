# frozen_string_literal: true

class NotificationEmailJob
  include Sidekiq::Job

  # The queue carries only the stable Notification id. Message content,
  # recipient details and other student data remain in the database and are
  # loaded by the worker.
  sidekiq_options retry: 3

  def perform(notification_id)
    # A producer may enqueue from inside a wider database transaction. Raising
    # on a not-yet-visible row makes Sidekiq retry after that transaction commits
    # instead of acknowledging and permanently dropping the delivery.
    notification = Notification.find(notification_id)
    NotificationsMailer.single_notification(notification).deliver_now
  end
end
