# frozen_string_literal: true

class PushNotificationDeliveryJob
  include Sidekiq::Job

  sidekiq_options retry: 3

  # Redis carries only the stable database id. The worker reloads the current
  # notification and subscription state immediately before delivery.
  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return if notification.nil?

    PushNotificationService.deliver(notification)
  end
end
