# Central entry point for raising a notification.
#
# Creates the in-app record. A single category toggle (the user's
# receive_*_notifications preference) gates the notification: if the category
# is off, it is suppressed entirely. Email and push delivery are added as
# separate channels on top of this record.
#
# Usage:
#   NotificationService.notify(
#     user: project.student,
#     type: 'feedback',
#     event: 'task_comment_created',
#     message: "New feedback is ready for #{task_definition.name}.",
#     link: "/projects/#{project.id}"
#   )
class NotificationService
  # Raise a notification for a user. Returns the created Notification, or nil if
  # the user's preference suppresses this category.
  #
  # type  - the category the user's preference switches on, one of
  #         Notification::TYPES.
  # event - the specific thing that happened, e.g. 'task_comment_created'.
  #         Required, so every notification can be traced back to its source.
  # notifiable - the record the event happened to, e.g. the comment or the task.
  #         Optional, so a general notification still works. Supplying it is
  #         what lets the notification be cleared when the user reads the thing
  #         it was about.
  # dedupe_key - optional identity for one event, so a retried caller cannot
  #         raise it twice for the same user.
  def self.notify(user:, type:, event:, message:, link: nil, dedupe_key: nil, notifiable: nil)
    type = type.to_s
    return nil unless deliver_to?(user, type)

    create_notification(
      user: user,
      notification_type: type,
      event: event.to_s,
      message: message,
      link: link,
      dedupe_key: dedupe_key,
      notifiable: notifiable
    )
  end

  # Whether the user's category preference allows this notification type.
  def self.deliver_to?(user, type)
    pref = Notification::PREFERENCE_FOR_TYPE[type.to_s]
    return true if pref.nil? # types without a preference are always sent

    user.public_send(pref)
  end

  # A non-null dedupe key is an immutable event identity. The unique database
  # index makes concurrent callers race safely: exactly one insert wins and the
  # others get the row it created.
  def self.create_notification(**attributes)
    Notification.transaction(requires_new: true) do
      Notification.create!(**attributes)
    end
  rescue ActiveRecord::RecordNotUnique
    raise if attributes[:dedupe_key].blank?

    Notification.find_by!(
      user: attributes.fetch(:user),
      dedupe_key: attributes.fetch(:dedupe_key)
    )
  end
  private_class_method :create_notification
end
