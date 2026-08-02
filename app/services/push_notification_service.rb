# Web Push delivery channel.
#
# NotificationService calls this for every notification it creates, straight
# after the email. Two properties make that safe:
#
#   * without VAPID keys it is a no-op, so the app behaves exactly as it did
#     before push existed for anyone who has not configured them
#   * one browser failing never stops the others and never reaches the caller,
#     so a push problem cannot block an in-app notification or an email
#
# Because the fan-out already calls this, every event that sends an email now
# sends a push too, with no per-event work.
#
# Key generation and setup: docs/notifications/push-setup.md.
class PushNotificationService
  # Push services reject a payload much over 4KB once encrypted. Nothing here
  # comes close, but the message is user-facing text assembled from names and
  # task titles, so it is trimmed rather than trusted.
  MAX_BODY_LENGTH = 400

  def self.deliver(notification)
    return unless configured?

    subscriptions = notification.user.push_subscriptions.to_a
    return if subscriptions.empty?

    payload = payload_for(notification)

    subscriptions.each { |subscription| deliver_to(subscription, payload) }
  end

  # The shape Angular's own ngsw-worker.js understands. It looks for a top level
  # "notification" key and displays the notification itself, which is why none of
  # this needs a hand written service worker. Use any other shape and somebody
  # has to write one.
  #
  # data.link is what MN-C03 reads to decide where to send the user on click.
  def self.payload_for(notification)
    {
      notification: {
        title: Doubtfire::Application.config.institution[:product_name],
        body: notification.message.to_s.truncate(MAX_BODY_LENGTH),
        data: {
          notification_id: notification.id,
          link: notification.link
        }
      }
    }.to_json
  end

  def self.deliver_to(subscription, payload)
    WebPush.payload_send(
      message: payload,
      endpoint: subscription.endpoint,
      p256dh: subscription.p256dh,
      auth: subscription.auth,
      vapid: vapid_details
    )
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
    # 410 or 404. The browser has thrown this registration away, or it was never
    # valid. Nothing will ever reach it again, so drop the row rather than retry
    # it on every notification from here to the end of time.
    Rails.logger.info "Removing dead push subscription #{subscription.id}: #{e.class}"
    subscription.destroy
  rescue StandardError => e
    # Rate limits, the push service being down, a rejected payload. Somebody
    # else's outage, and not a reason to fail the notification. Log and move on
    # to the next browser.
    Rails.logger.error "Failed to push to subscription #{subscription.id}: #{e.class}: #{e.message}"
  end

  def self.vapid_details
    {
      subject: vapid_subject,
      public_key: ENV.fetch('DOUBTFIRE_VAPID_PUBLIC_KEY'),
      private_key: ENV.fetch('DOUBTFIRE_VAPID_PRIVATE_KEY')
    }
  end

  # Push services want a way to contact whoever is sending, as a mailto: or a
  # URL. They reject the request outright if it is missing.
  def self.vapid_subject
    ENV['DOUBTFIRE_VAPID_SUBJECT'].presence ||
      Doubtfire::Application.config.institution[:host].presence ||
      'mailto:noreply@doubtfire.local'
  end

  # True once VAPID keys are configured. Keeps the fan-out safe to call today.
  def self.configured?
    ENV['DOUBTFIRE_VAPID_PUBLIC_KEY'].present? && ENV['DOUBTFIRE_VAPID_PRIVATE_KEY'].present?
  end

  private_class_method :deliver_to, :vapid_details, :vapid_subject
end
