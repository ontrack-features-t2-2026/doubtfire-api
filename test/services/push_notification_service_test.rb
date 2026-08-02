require 'test_helper'

# MN-F02: the push channel actually sends.
#
# These tests go through the real web-push gem and stub the HTTP call to the
# push service, rather than stubbing WebPush itself. That is deliberate: the
# part most likely to be wired up wrong is the gem call and the payload, and a
# stub of WebPush.payload_send would prove neither.
class PushNotificationServiceTest < ActiveSupport::TestCase
  # A throwaway VAPID pair and a throwaway browser key pair, generated for these
  # tests. The p256dh has to be a real prime256v1 public key or the gem cannot
  # encrypt the payload, so it cannot be a made up string.
  VAPID_PUBLIC = 'BOs-KbIoHK7gUIX3i2_uEuDoouj-GKxB-mY9CRmLNmd4Wn-SSl254E1g6jR1ukL3e37p8uCpaMjOvfAB0BwzvSI='.freeze
  VAPID_PRIVATE = '_NFIWSUTdCdLJJFh87pf4ekQLmNYqsweZ4288NpVZaY='.freeze
  BROWSER_P256DH = 'BJy8RpjMkwOPDIIXSu-FTe7OosAwY9G86_evhrn0jJbPnoxXjBYpn7aPHEIaRh3GxCzFvwYXjKWvtu3FEMaBQMY='.freeze
  BROWSER_AUTH = 'CUkmaYqq8eINt1HTnFY65w=='.freeze

  ENDPOINT = 'https://fcm.googleapis.com/fcm/send/test-browser'.freeze

  setup do
    @user = FactoryBot.create(:user, :student)
    @notification = Notification.create!(
      user: @user,
      notification_type: 'feedback',
      event: 'task_comment_created',
      message: 'Andrew Cain commented on 1.1P in COS10001.',
      link: '/projects/2/dashboard/1.1P'
    )
  end

  # Set the keys for the block and put the environment back exactly as it was.
  #
  # Restoring rather than deleting matters: the development container now has
  # real values in its environment, so a test that deleted them would leave the
  # process different from how it found it, and a test that assumed they were
  # absent to begin with would pass in CI and fail on a developer's machine.
  def with_env(values)
    previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_keys(&)
    with_env({ 'DOUBTFIRE_VAPID_PUBLIC_KEY' => VAPID_PUBLIC, 'DOUBTFIRE_VAPID_PRIVATE_KEY' => VAPID_PRIVATE }, &)
  end

  def without_keys(&)
    with_env({ 'DOUBTFIRE_VAPID_PUBLIC_KEY' => nil, 'DOUBTFIRE_VAPID_PRIVATE_KEY' => nil }, &)
  end

  def create_subscription(endpoint: ENDPOINT)
    @user.push_subscriptions.create!(
      endpoint: endpoint,
      p256dh: BROWSER_P256DH,
      auth: BROWSER_AUTH
    )
  end

  def test_nothing_is_sent_when_the_vapid_keys_are_missing
    create_subscription

    # No WebMock stub is registered, so any outbound request would raise.
    without_keys do
      assert_not PushNotificationService.configured?
      assert_nothing_raised { PushNotificationService.deliver(@notification) }
    end
  end

  def test_a_notification_is_pushed_to_the_subscribed_browser
    create_subscription
    request = stub_request(:post, ENDPOINT).to_return(status: 201)

    with_keys { PushNotificationService.deliver(@notification) }

    assert_requested request
  end

  def test_every_subscribed_browser_is_pushed_to
    create_subscription(endpoint: "#{ENDPOINT}-one")
    create_subscription(endpoint: "#{ENDPOINT}-two")

    first = stub_request(:post, "#{ENDPOINT}-one").to_return(status: 201)
    second = stub_request(:post, "#{ENDPOINT}-two").to_return(status: 201)

    with_keys { PushNotificationService.deliver(@notification) }

    assert_requested first
    assert_requested second
  end

  def test_nothing_is_sent_when_the_user_has_no_browsers_registered
    with_keys { assert_nothing_raised { PushNotificationService.deliver(@notification) } }
  end

  def test_a_gone_subscription_is_deleted
    create_subscription
    stub_request(:post, ENDPOINT).to_return(status: 410)

    assert_difference 'PushSubscription.count', -1 do
      with_keys { PushNotificationService.deliver(@notification) }
    end
  end

  def test_a_not_found_subscription_is_deleted
    create_subscription
    stub_request(:post, ENDPOINT).to_return(status: 404)

    assert_difference 'PushSubscription.count', -1 do
      with_keys { PushNotificationService.deliver(@notification) }
    end
  end

  # A rate limit or an outage is temporary. Deleting on those would silently
  # unsubscribe people the first time a push service had a bad day.
  def test_a_temporary_push_service_failure_keeps_the_subscription
    create_subscription
    stub_request(:post, ENDPOINT).to_return(status: 429)

    assert_no_difference 'PushSubscription.count' do
      with_keys { assert_nothing_raised { PushNotificationService.deliver(@notification) } }
    end
  end

  def test_one_dead_browser_does_not_stop_the_others
    create_subscription(endpoint: "#{ENDPOINT}-dead")
    create_subscription(endpoint: "#{ENDPOINT}-alive")

    stub_request(:post, "#{ENDPOINT}-dead").to_return(status: 410)
    alive = stub_request(:post, "#{ENDPOINT}-alive").to_return(status: 201)

    with_keys { PushNotificationService.deliver(@notification) }

    assert_requested alive
    assert_equal ["#{ENDPOINT}-alive"], @user.push_subscriptions.reload.map(&:endpoint)
  end

  # Angular's ngsw-worker.js only displays a push if the payload has a top level
  # "notification" key. Anything else needs a hand written service worker.
  def test_the_payload_has_the_shape_angulars_service_worker_expects
    payload = JSON.parse(PushNotificationService.payload_for(@notification))

    assert payload.key?('notification'), 'ngsw-worker.js will ignore a payload without this key'

    body = payload['notification']

    assert_equal 'Andrew Cain commented on 1.1P in COS10001.', body['body']
    assert_equal '/projects/2/dashboard/1.1P', body.dig('data', 'link')
    assert_equal @notification.id, body.dig('data', 'notification_id')
    assert_not_nil body['title']
  end

  def test_a_long_message_is_trimmed_rather_than_rejected_by_the_push_service
    @notification.update!(message: 'a' * 500)

    body = JSON.parse(PushNotificationService.payload_for(@notification))['notification']['body']

    assert_operator body.length, :<=, PushNotificationService::MAX_BODY_LENGTH
  end

  # The whole point of MN-F02: the fan-out already calls this service, so an
  # event that sends an email now sends a push with no extra work.
  def test_raising_a_notification_through_the_hub_sends_a_push
    create_subscription
    request = stub_request(:post, ENDPOINT).to_return(status: 201)

    with_keys do
      NotificationService.notify(
        user: @user,
        type: 'feedback',
        event: 'task_comment_created',
        message: 'Raised through the hub.',
        link: '/projects/2/dashboard/1.1P'
      )
    end

    assert_requested request
  end
end
