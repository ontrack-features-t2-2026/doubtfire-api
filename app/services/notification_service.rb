# Central entry point for raising a notification.
#
# Creates the in-app record and fans out to the enabled delivery channels
# (email and push through Sidekiq). A single category toggle (the user's
# receive_*_notifications preference) gates every channel: if the category is
# off, the notification is suppressed entirely. A category listed in
# Notification::CHANNEL_PREFERENCES_FOR_TYPE (so far only unit_hub) also has
# its own email and push opt-ins, checked when those channels are queued and
# again when their jobs run.
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
  #         Optional, so an existing caller and a general notification both
  #         still work. Supplying it is what lets the notification be cleared
  #         when the user reads the thing it was about.
  def self.notify(user:, type:, event:, message:, link: nil, dedupe_key: nil, notifiable: nil)
    notification = reserve(
      user: user,
      type: type,
      event: event,
      message: message,
      link: link,
      dedupe_key: dedupe_key,
      notifiable: notifiable
    )

    deliver(notification)
  end

  # Persist a notification without running its delivery channels. Callers that
  # need a short eligibility lock can commit this reservation, release the
  # lock, and then call `deliver` without holding a row lock across network I/O.
  def self.reserve(user:, type:, event:, message:, link: nil, dedupe_key: nil, notifiable: nil)
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

  def self.deliver(notification)
    return nil if notification.nil?

    # Concurrent or retried fan-outs can reserve the same immutable event. A
    # lock on that notification (not on the student's project) serializes only
    # its push hand-off. Email is queued once by Notification's after_commit
    # hook, so it cannot be consumed before an enclosing transaction commits
    # and a dedupe retry cannot queue it twice. delivered_at tracks the async
    # push hand-off; a failed hand-off stays retryable.
    notification.with_lock do
      unless notification.delivered_at?
        push_queued = queue_push(notification)
        notification.update!(delivered_at: Time.current) if push_queued
      end
    end

    notification
  end

  # Whether the user's category preference allows this notification type.
  #
  # channel - nil for the category as a whole (the in-app record), or :email or
  #         :push. A channel is only asked about for categories listed in
  #         Notification::CHANNEL_PREFERENCES_FOR_TYPE, and the category itself
  #         has to be on first.
  def self.deliver_to?(user, type, channel: nil)
    pref = Notification::PREFERENCE_FOR_TYPE[type.to_s]
    return false unless pref.nil? || user.public_send(pref)

    channel.nil? || channel_enabled?(user, type, channel)
  end

  # Whether the user opted in to one delivery channel for a category. True for
  # categories that have no per-channel columns.
  def self.channel_enabled?(user, type, channel)
    column = Notification::CHANNEL_PREFERENCES_FOR_TYPE.dig(type.to_s, channel.to_sym)
    column.nil? || user.public_send(column)
  end

  # A non-null dedupe key is an immutable event identity. The unique database
  # index makes concurrent fan-out jobs race safely: exactly one insert wins,
  # and only that winner runs the after_commit hook that queues the email.
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

  # Email channel. Called from Notification's after_commit hook, never directly
  # from notify or deliver, so the notification is committed before the job exists.
  #
  # Queue only the stable Notification id; message content, recipient details
  # and other student data remain in the database. Queue connection errors are
  # best-effort so the in-app record and push delivery are not blocked. Delivery
  # failures are raised by the job for Sidekiq to retry.
  def self.queue_email(notification)
    # A category with its own email opt-in skips the job entirely when the
    # recipient has not opted in, so a cohort-wide announcement does not queue
    # hundreds of jobs that would only return early. The job asks again anyway.
    return false unless channel_enabled?(notification.user, notification.notification_type, :email)

    NotificationEmailJob.perform_async(notification.id)
  rescue StandardError => e
    Rails.logger.error(
      "Failed to queue notification email for Notification #{notification.id}: #{e.class}"
    )
    false
  end

  # Push channel. Queue only the stable Notification id so no student or
  # notification content is copied into Redis. A failed hand-off leaves
  # delivered_at unset, allowing the existing availability retry to try the
  # push hand-off again without duplicating the after-commit email.
  def self.queue_push(notification)
    # Nothing to hand off when the recipient has not opted in to push for this
    # category. Counts as handed off, so a retry does not try again.
    return true unless channel_enabled?(notification.user, notification.notification_type, :push)

    PushNotificationDeliveryJob.perform_async(notification.id)
  rescue StandardError => e
    Rails.logger.error(
      "Failed to queue notification push for Notification #{notification.id}: #{e.class}"
    )
    false
  end
  private_class_method :queue_push
end
