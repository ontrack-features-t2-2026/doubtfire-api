# frozen_string_literal: true

class NotificationEmailJob
  include Sidekiq::Job

  # The queue carries only the stable Notification id. Message content,
  # recipient details and other student data remain in the database and are
  # loaded by the worker.
  sidekiq_options retry: 3

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return if notification.nil?

    NotificationsMailer.single_notification(notification).deliver_now
  end
end
