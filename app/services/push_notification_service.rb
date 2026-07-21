# Web Push delivery channel.
#
# Stubbed until VAPID keys are provisioned in the deploy environment (Stage 4).
# It is safe to call now: deliver is a no-op until keys are configured, so the
# notification fan-out works today without push wired up.
#
# Stage 4 will:
#   1. add a push_subscriptions table (user_id, endpoint, p256dh, auth)
#   2. read DOUBTFIRE_VAPID_PUBLIC_KEY / DOUBTFIRE_VAPID_PRIVATE_KEY
#   3. iterate notification.user.push_subscriptions and send the payload via
#      the web-push gem (WebPush.payload_send)
class PushNotificationService
  def self.deliver(notification)
    return unless configured?

    # TODO(Stage 4): send to notification.user.push_subscriptions via web-push.
    Rails.logger.debug "Push channel not yet wired for notification #{notification.id}"
  end

  # True once VAPID keys are configured. Keeps the fan-out safe to call today.
  def self.configured?
    ENV['DOUBTFIRE_VAPID_PUBLIC_KEY'].present? && ENV['DOUBTFIRE_VAPID_PRIVATE_KEY'].present?
  end
end
