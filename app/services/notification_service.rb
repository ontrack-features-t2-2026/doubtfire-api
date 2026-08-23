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
  def self.notify(user:, type:, event:, message:, link: nil, dedupe_key: nil)
    notification = reserve(
      user: user,
      type: type,
      event: event,
      message: message,
      link: link,
      dedupe_key: dedupe_key
    )

    deliver(notification)
  end

  # Persist a notification without running its delivery channels. Callers that
  # need a short eligibility lock can commit this reservation, release the
  # lock, and then call `deliver` without holding a row lock across network I/O.
  def self.reserve(user:, type:, event:, message:, link: nil, dedupe_key: nil)
    type = type.to_s
    return nil unless deliver_to?(user, type)

    create_notification(
      user: user,
      notification_type: type,
      event: event.to_s,
      message: message,
      link: link,
      dedupe_key: dedupe_key
    )
  end

  def self.deliver(notification)
    return nil if notification.nil?

    # Concurrent or retried fan-outs can reserve the same immutable event. A
    # lock on that notification (not on the student's project) serializes only
    # its channel delivery. If delivery raises, delivered_at remains nil and a
    # retry tries again. External channels are at-least-once: a process crash
    # after a provider accepts a message can repeat that message on retry.
    notification.with_lock do
      unless notification.delivered_at?
        deliver_email(notification)
        PushNotificationService.deliver(notification)
        notification.update!(delivered_at: Time.current)
      end
    end

    notification
  end

  # Whether the user's category preference allows this notification type.
  def self.deliver_to?(user, type)
    pref = Notification::PREFERENCE_FOR_TYPE[type.to_s]
    return true if pref.nil? # types without a preference are always sent

    user.public_send(pref)
  end

  # A non-null dedupe key is an immutable event identity. The unique database
  # index makes concurrent fan-out jobs race safely: exactly one insert wins.
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

  # Email channel. Best-effort: a mail failure must never block the in-app
  # notification, so errors are logged and swallowed here.
  #
  # Sent inline, rather than with deliver_later or a Sidekiq job.
  #
  # No Active Job queue adapter is configured, so deliver_later would run on
  # Active Job's in-process :async thread pool. That does execute, but only in
  # memory: anything still pending is lost when the container restarts, and it
  # shows up in no dashboard. A Sidekiq job would be worse in development, where
  # the stack starts Redis but runs no worker process at all, so perform_async
  # would queue to Redis and sit there forever without reporting an error.
  #
  # Known trade-off: this runs on the request path, and production delivers over
  # SMTP (config/environments/production.rb), so a slow mail server slows down
  # whatever action raised the notification. The rescue below cannot prevent that
  # latency, and it also swallows the failure without retrying. Moving this onto
  # a real queue is ticket EN-F03, which adds the worker service first.
  def self.deliver_email(notification)
    NotificationsMailer.single_notification(notification).deliver_now
  rescue StandardError => e
    Rails.logger.error "Failed to send notification email for user #{notification.user_id}: #{e.message}"
  end
  private_class_method :deliver_email
end
