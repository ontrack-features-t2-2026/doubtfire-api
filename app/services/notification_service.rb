# Central entry point for raising a notification.
#
# Creates the in-app record and fans out to the enabled delivery channels
# (email now, push in Stage 4). A single category toggle (the user's
# receive_*_notifications preference) gates every channel: if the category is
# off, the notification is suppressed entirely. Per-channel granularity
# (a type x channel matrix) is deferred to a future iteration.
#
# Usage:
#   NotificationService.notify(
#     user: project.student,
#     type: 'feedback',
#     message: "New feedback is ready for #{task_definition.name}.",
#     link: "/#/projects/#{project.id}"
#   )
class NotificationService
  # Raise a notification for a user. Returns the created Notification, or nil if
  # the user's preference suppresses this category.
  def self.notify(user:, type:, message:, link: nil)
    type = type.to_s
    return nil unless deliver_to?(user, type)

    notification = Notification.create!(
      user: user,
      notification_type: type,
      message: message,
      link: link
    )

    deliver_email(notification)
    PushNotificationService.deliver(notification)

    notification
  end

  # Whether the user's category preference allows this notification type.
  def self.deliver_to?(user, type)
    pref = Notification::PREFERENCE_FOR_TYPE[type.to_s]
    return true if pref.nil? # types without a preference are always sent

    user.public_send(pref)
  end

  # Email channel. Best-effort: a mail failure must never block the in-app
  # notification, so errors are logged and swallowed here.
  def self.deliver_email(notification)
    NotificationsMailer.single_notification(notification).deliver_later
  rescue StandardError => e
    Rails.logger.error "Failed to enqueue notification email for user #{notification.user_id}: #{e.message}"
  end
  private_class_method :deliver_email
end
