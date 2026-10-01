# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20261001000001_add_notification_channel_choices')

class NotificationChannelChoicesTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  setup do
    @user = create(:user, :student, receive_feedback_notifications: false)
  end

  test 'migration preserves historical channel and digest opt outs' do
    # Simulate rows from before the migration without invoking new callbacks.
    # rubocop:disable Rails/SkipsModelValidations
    @user.update_columns(receive_task_notifications: false, receive_feedback_notifications: false,
                         receive_portfolio_notifications: false, digest_frequency: 'weekly',
                         receive_feedback_email_notifications: true, receive_feedback_push_notifications: true)
    # rubocop:enable Rails/SkipsModelValidations
    opted_in = create(:user, :student, digest_frequency: 'daily')
    AddNotificationChannelChoices.new.suppress_messages { AddNotificationChannelChoices.new.backfill_notification_choices }
    @user.reload
    assert_not @user.receive_feedback_email_notifications
    assert_not @user.receive_feedback_push_notifications
    assert_not @user.receive_task_email_notifications
    assert_not @user.receive_portfolio_push_notifications
    assert_equal 'off', @user.digest_frequency
    assert_equal 'daily', opted_in.reload.digest_frequency
    assert opted_in.receive_feedback_email_notifications
  end

  test 'legacy opt out maps to both channels but preserves in app history' do
    assert_not @user.receive_feedback_email_notifications
    assert_not @user.receive_feedback_push_notifications
    assert NotificationService.deliver_to?(@user, 'feedback')
    assert_not NotificationService.deliver_to?(@user, 'feedback', channel: :email)
    assert_not NotificationService.deliver_to?(@user, 'feedback', channel: :push)
  end

  test 'own channel choices and cadence are independent and survive stale legacy fields' do
    add_auth_header_for(user: @user)
    put_json "/api/users/#{@user.id}", user: {
      receive_feedback_notifications: false,
      receive_feedback_email_notifications: false,
      receive_feedback_push_notifications: true,
      digest_frequency: 'daily', staff_digest_frequency: 'off'
    }
    assert_equal 200, last_response.status, last_response.body
    @user.reload
    assert_not NotificationService.deliver_to?(@user, 'feedback', channel: :email)
    assert NotificationService.deliver_to?(@user, 'feedback', channel: :push)
    assert_equal 'daily', @user.digest_frequency
    assert_not @user.receive_feedback_notifications, 'old app readers must also respect an external opt out'
  end

  test 'email remains enabled when push is off and the legacy flag is conservative' do
    @user.update!(receive_feedback_email_notifications: true, receive_feedback_push_notifications: false)
    assert_not @user.receive_feedback_notifications
    assert NotificationService.deliver_to?(@user, 'feedback', channel: :email)
    assert_not NotificationService.deliver_to?(@user, 'feedback', channel: :push)
    assert_difference -> { NotificationEmailJob.jobs.size }, 1 do
      assert_no_difference -> { PushNotificationDeliveryJob.jobs.size } do
        NotificationService.notify(user: @user, type: 'feedback', event: 'task_comment_created', message: 'Feedback is ready.')
      end
    end
  end

  test 'another student cannot change channels or cadence' do
    add_auth_header_for(user: create(:user, :student))
    put_json "/api/users/#{@user.id}", user: { receive_feedback_email_notifications: true, staff_digest_frequency: 'daily' }
    assert_equal 403, last_response.status
    assert_not @user.reload.receive_feedback_email_notifications
    assert_equal 'off', @user.staff_digest_frequency
  end

  test 'an administrator cannot opt another user into outgoing channels' do
    add_auth_header_for(user: create(:user, :admin))
    put_json "/api/users/#{@user.id}", user: { receive_feedback_email_notifications: true, staff_digest_frequency: 'daily' }
    assert_equal 200, last_response.status, last_response.body
    assert_not @user.reload.receive_feedback_email_notifications
    assert_equal 'off', @user.staff_digest_frequency
  end

  test 'student digest recipients use cadence independently of feedback opt out' do
    unit = create(:unit, student_count: 1, task_count: 1)
    student = unit.active_projects.first.student
    student.update!(receive_feedback_notifications: false, digest_frequency: 'daily')
    assert_includes SendDigestEmailsJob.new.send(:recipients, 'daily').pluck(:id), student.id
    student.update!(digest_frequency: 'off')
    assert_not_includes SendDigestEmailsJob.new.send(:recipients, 'daily').pluck(:id), student.id
  end
end
