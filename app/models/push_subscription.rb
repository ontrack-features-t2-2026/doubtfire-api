# One browser registered to receive web push notifications.
#
# The endpoint is the URL the push service gave that browser. It identifies the
# browser, not the person, so it is unique across the whole table: if the same
# browser signs in as a different user the registration moves across instead of
# being duplicated. PushSubscriptionsApi does that move.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true, length: { maximum: 500 }
  validates :p256dh, presence: true, length: { maximum: 255 }
  validates :auth, presence: true, length: { maximum: 255 }
end
