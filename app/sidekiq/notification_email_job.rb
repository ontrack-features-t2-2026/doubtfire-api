# frozen_string_literal: true

class NotificationEmailJob
  include Sidekiq::Job

  # The queue carries only the stable Notification id. Message content,
  # recipient details and other student data remain in the database and are
  # loaded by the worker.
  #
  # Student facing email runs on its own queue so it does not wait behind a
  # multi minute PDF build or CSV export on the default queue. A worker has to
  # be listening on `mailers` for any of this to be picked up.
  sidekiq_options queue: :mailers, retry: 3

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return if notification.nil?

    # The category preference was checked when the notification was raised, but
    # a retried job can run hours later. Ask again so a preference the user has
    # switched off in the meantime stays off.
    return unless NotificationService.deliver_to?(notification.user, notification.notification_type)

    NotificationsMailer.single_notification(notification).deliver_now
  end
end
