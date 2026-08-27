require 'test_helper'

# MN-C01: the front end reads the VAPID public key from /api/settings so it is
# configured in one place instead of being copied into the web repo and going
# stale the first time the keys are rotated.
#
# The endpoint itself takes no authentication. SettingsApi calls no
# authenticated? and ApiRoot has no before-filter that adds one, so anyone who
# can reach the host can GET it. The signed-in caller is the normal case and
# most of this file uses it, but the private key must stay out of the response
# for a caller with no credentials at all, which is what the anonymous test at
# the bottom pins down.
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

  setup do
    clear_auth_header
    add_auth_header_for
  end

  teardown do
    clear_auth_header
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

  # The browser needs the public key after sign-in. The private key must never
  # be in the response the signed-in front end receives.
  def test_the_private_key_is_never_published
    with_vapid_keys do
      get '/api/settings'

      assert_not_includes last_response.body, 'BTestPrivateKey'
      assert_not_includes last_response_body.keys, 'vapidPrivateKey'
    end
  end

  # The case that actually matters. This endpoint is reachable without
  # credentials, so the private key must not be served to a caller who has
  # none. Do not fold this into the test above by deleting the header clear:
  # asserting it only for a signed-in user proves nothing about an anonymous
  # one, and the endpoint answers both.
  def test_the_private_key_is_never_published_to_an_anonymous_caller
    clear_auth_header

    with_vapid_keys do
      get '/api/settings'

      assert_equal 200, last_response.status
      assert_equal 'BTestPublicKey', last_response_body['vapidPublicKey']
      assert_not_includes last_response.body, 'BTestPrivateKey'
      assert_not_includes last_response_body.keys, 'vapidPrivateKey'
    end
  end
end
