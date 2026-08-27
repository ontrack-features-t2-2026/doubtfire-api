# Central entry point for raising a notification.
#
# Creates the in-app record and fans out to the enabled delivery channels
# (email through Sidekiq, push immediately). A single category toggle (the user's
# receive_*_notifications preference) gates every channel: if the category is
# off, the notification is suppressed entirely. Per-channel granularity
# (a type x channel matrix) is deferred to a future iteration.
#
# Usage:
#   NotificationService.notify(
#     user: project.student,
#     type: 'feedback',
#     event: 'task_comment_created',
#     message: "New feedback is ready for #{task_definition.name}.",
#     link: "/#/projects/#{project.id}"
#   )
class NotificationService
  # Raise a notification for a user. Returns the created Notification, or nil if
  # the user's preference suppresses this category.
  #
  # type  - the category the user's preference switches on, one of
  #         Notification::TYPES.
  # event - the specific thing that happened, e.g. 'task_comment_created'.
  #         Required, so every notification can be traced back to its source.
  def self.notify(user:, type:, event:, message:, link: nil)
    type = type.to_s
    return nil unless deliver_to?(user, type)

    notification = Notification.create!(
      user: user,
      notification_type: type,
      event: event.to_s,
      message: message,
      link: link
    )

    # The email is queued by Notification's after_commit hook, so the row is
    # committed before a worker can look for it.
    PushNotificationService.deliver(notification)

    notification
  end

  # Whether the user's category preference allows this notification type.
  def self.deliver_to?(user, type)
    pref = Notification::PREFERENCE_FOR_TYPE[type.to_s]
    return true if pref.nil? # types without a preference are always sent

    user.public_send(pref)
  end

  # Email channel. Called from Notification's after_commit hook, never directly
  # from notify, so the notification is committed before the job exists.
  #
  # Queue only the stable Notification id; message content, recipient details
  # and other student data remain in the database. Queue connection errors are
  # best-effort so the in-app record and push delivery are not blocked. Delivery
  # failures are raised by the job for Sidekiq to retry.
  def self.queue_email(notification)
    NotificationEmailJob.perform_async(notification.id)
  rescue StandardError => e
    Rails.logger.error(
      "Failed to queue notification email for Notification #{notification.id}: #{e.class}"
    )
  end
end
