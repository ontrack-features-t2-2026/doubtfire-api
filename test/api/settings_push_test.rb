require 'test_helper'

# MN-C01: the front end reads the VAPID public key from /api/settings so it is
# configured in one place instead of being copied into the web repo and going
# stale the first time the keys are rotated.
#
# Separate from settings_test.rb on purpose. That file predates rubocop's style
# rules and already carries 17 offenses; adding to it would either add more or
# mean reformatting a file this ticket has no business touching.
class SettingsPushTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  # Restores whatever was there rather than deleting. The development container
  # really does have these set, so a test that assumed they were absent would
  # pass in CI and fail on a developer's machine.
  def with_env(values)
    previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_vapid_keys(&)
    with_env({ 'DOUBTFIRE_VAPID_PUBLIC_KEY' => 'BTestPublicKey', 'DOUBTFIRE_VAPID_PRIVATE_KEY' => 'BTestPrivateKey' }, &)
  end

  def without_vapid_keys(&)
    with_env({ 'DOUBTFIRE_VAPID_PUBLIC_KEY' => nil, 'DOUBTFIRE_VAPID_PRIVATE_KEY' => nil }, &)
  end

  def test_the_public_key_is_published_when_push_is_configured
    with_vapid_keys do
      get '/api/settings'

      assert_equal 200, last_response.status
      assert_equal true, last_response_body['pushEnabled']
      assert_equal 'BTestPublicKey', last_response_body['vapidPublicKey']
    end
  end

  # Without keys the client must not offer the opt-in. Subscribing would fail in
  # the browser with nothing on screen to explain why.
  def test_push_is_reported_unavailable_without_keys
    without_vapid_keys do
      get '/api/settings'

      assert_equal 200, last_response.status
      assert_equal false, last_response_body['pushEnabled']
      assert_nil last_response_body['vapidPublicKey']
    end
  end

  # The public key is safe to publish. The private key is not, and this endpoint
  # needs no authentication at all.
  def test_the_private_key_is_never_published
    with_vapid_keys do
      get '/api/settings'

      assert_not_includes last_response.body, 'BTestPrivateKey'
      assert_not_includes last_response_body.keys, 'vapidPrivateKey'
    end
  end
end
