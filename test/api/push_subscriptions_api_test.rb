require 'test_helper'

# MN-F01: storing a browser's push registration.
class PushSubscriptionsApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  setup do
    @user = FactoryBot.create(:user, :student)
    @other = FactoryBot.create(:user, :student)
  end

  # A plausible subscription. Real endpoints are long, which is the whole reason
  # the column is not a default varchar(255).
  def subscription_params(endpoint: 'https://fcm.googleapis.com/fcm/send/abc123')
    {
      endpoint: endpoint,
      p256dh: 'BExampleBrowserPublicKeyValue',
      auth: 'ExampleAuthSecret'
    }
  end

  def test_a_user_can_register_a_browser
    add_auth_header_for(user: @user)

    assert_difference 'PushSubscription.count', 1 do
      post '/api/push_subscriptions', subscription_params
    end

    assert_equal 201, last_response.status

    subscription = PushSubscription.last

    assert_equal @user, subscription.user
    assert_equal 'https://fcm.googleapis.com/fcm/send/abc123', subscription.endpoint
  end

  def test_the_response_does_not_leak_the_browser_keys
    add_auth_header_for(user: @user)
    post '/api/push_subscriptions', subscription_params

    json = JSON.parse(last_response.body)

    assert_equal 'https://fcm.googleapis.com/fcm/send/abc123', json['endpoint']
    assert_not json.key?('p256dh'), 'the browser public key must not be sent back'
    assert_not json.key?('auth'), 'the browser auth secret must not be sent back'
  end

  def test_registering_the_same_browser_twice_updates_instead_of_duplicating
    add_auth_header_for(user: @user)
    post '/api/push_subscriptions', subscription_params

    assert_no_difference 'PushSubscription.count' do
      post '/api/push_subscriptions', subscription_params.merge(p256dh: 'BRotatedPublicKey')
    end

    assert_equal 'BRotatedPublicKey', PushSubscription.last.p256dh
  end

  # Shared machine. The endpoint belongs to the browser, so the registration has
  # to move to whoever signed in last rather than blowing up on the unique index.
  def test_registering_a_browser_another_user_had_moves_it_across
    subscription = @other.push_subscriptions.create!(subscription_params)

    add_auth_header_for(user: @user)

    assert_no_difference 'PushSubscription.count' do
      post '/api/push_subscriptions', subscription_params
    end

    assert_equal @user, subscription.reload.user
    assert_empty @other.push_subscriptions.reload
  end

  def test_a_user_only_sees_their_own_registrations
    @user.push_subscriptions.create!(subscription_params(endpoint: 'https://push.example.com/mine'))
    @other.push_subscriptions.create!(subscription_params(endpoint: 'https://push.example.com/theirs'))

    add_auth_header_for(user: @user)
    get '/api/push_subscriptions'

    assert_equal 200, last_response.status

    json = JSON.parse(last_response.body)

    assert_equal 1, json.length
    assert_equal 'https://push.example.com/mine', json.first['endpoint']
  end

  def test_a_user_can_remove_their_own_registration
    @user.push_subscriptions.create!(subscription_params)

    add_auth_header_for(user: @user)

    assert_difference 'PushSubscription.count', -1 do
      delete '/api/push_subscriptions', endpoint: subscription_params[:endpoint]
    end

    assert_equal 200, last_response.status
  end

  def test_a_user_cannot_remove_someone_elses_registration
    @other.push_subscriptions.create!(subscription_params)

    add_auth_header_for(user: @user)

    assert_no_difference 'PushSubscription.count' do
      delete '/api/push_subscriptions', endpoint: subscription_params[:endpoint]
    end

    assert_equal 404, last_response.status
  end

  def test_an_unauthenticated_request_is_rejected
    clear_auth_header

    assert_no_difference 'PushSubscription.count' do
      post '/api/push_subscriptions', subscription_params
    end

    assert_equal 419, last_response.status
  end

  def test_a_registration_missing_the_browser_keys_is_rejected
    add_auth_header_for(user: @user)

    assert_no_difference 'PushSubscription.count' do
      post '/api/push_subscriptions', endpoint: 'https://push.example.com/incomplete'
    end

    assert_equal 400, last_response.status
  end

  # Firefox and Safari endpoints run past the 255 characters a default string
  # column would give us. If this ever fails the migration has regressed.
  def test_a_long_endpoint_is_stored_whole
    long_endpoint = "https://updates.push.services.mozilla.com/wpush/v2/#{'a' * 300}"

    add_auth_header_for(user: @user)
    post '/api/push_subscriptions', subscription_params(endpoint: long_endpoint)

    assert_equal 201, last_response.status
    assert_equal long_endpoint, PushSubscription.last.endpoint
  end

  def test_deleting_the_user_deletes_their_registrations
    @user.push_subscriptions.create!(subscription_params)

    assert_difference 'PushSubscription.count', -1 do
      @user.destroy!
    end
  end
end
