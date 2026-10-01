# frozen_string_literal: true

require 'test_helper'

class NotificationInboxApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper

  def app
    Rails.application
  end

  setup do
    @user = FactoryBot.create(:user, :student)
    @other = FactoryBot.create(:user, :student)
    add_auth_header_for(user: @user)
  end

  def inbox(**options)
    get '/api/notifications', { paginated: true }.merge(options)
    assert_equal 200, last_response.status, last_response.body
    JSON.parse(last_response.body)
  end

  def test_pages_are_bounded_and_ties_have_a_stable_order
    records = FactoryBot.create_list(:notification, 5, user: @user, created_at: 1.hour.ago)
    FactoryBot.create(:notification, user: @other, event: 'private_other_event')

    first = inbox(per_page: 2)
    second = inbox(per_page: 2, page: 2)

    assert_equal(records.reverse.first(2).map(&:id), first['notifications'].map { |row| row['id'] })
    assert_equal(records.reverse.drop(2).first(2).map(&:id), second['notifications'].map { |row| row['id'] })
    assert_equal 5, first['total_count']
    assert_equal 5, first['unread_count']
    assert_equal records.last.id, first['through_id']
    assert_equal ['general_event'], first['events']
    assert_equal 2, first['per_page']
    assert_equal 2, second['page']
  end

  def test_filters_combine_but_unread_and_delete_boundary_remain_account_wide
    chosen = FactoryBot.create(:notification, :feedback, user: @user, event: 'task_comment_created')
    FactoryBot.create(:notification, :feedback, :read, user: @user, event: 'task_comment_created')
    FactoryBot.create(:notification, :feedback, user: @user, event: 'task_status_changed')
    boundary = FactoryBot.create(:notification, :task, user: @user, event: 'task_comment_created')

    result = inbox(notification_type: 'feedback', event: 'task_comment_created', unread_only: true)

    assert_equal([chosen.id], result['notifications'].map { |row| row['id'] })
    assert_equal 1, result['total_count']
    assert_equal 3, result['unread_count']
    assert_equal boundary.id, result['through_id']
  end

  def test_unit_filter_handles_typed_targets_and_legacy_links_without_other_users_facets
    project = FactoryBot.create(:project, user: @user)
    task = project.task_for_task_definition(project.unit.task_definitions.first)
    typed = FactoryBot.create(:notification, user: @user, notifiable: task)
    legacy = FactoryBot.create(:notification, user: @user, link: "/projects/#{project.id}/dashboard/1.1P")
    other_project = FactoryBot.create(:project, user: @other)
    FactoryBot.create(:notification, user: @other, notifiable: other_project, event: 'private_event')
    FactoryBot.create(:notification, user: @user, link: 'https://example.invalid/projects/999/dashboard')

    result = inbox(unit_id: project.unit_id)

    assert_equal [typed.id, legacy.id].sort, result['notifications'].map { |row| row['id'] }.sort
    assert_equal([project.unit_id], result['units'].map { |unit| unit['id'] })
    assert_not_includes result['events'], 'private_event'
    assert_empty inbox(unit_id: other_project.unit_id)['notifications']
  end

  def test_unit_filter_matches_comment_project_and_unit_hub_targets
    project = FactoryBot.create(:project, user: @user)
    task = project.task_for_task_definition(project.unit.task_definitions.first)
    comment = task.add_text_comment(@user, 'Synthetic question')
    announcement = project.unit.unit_announcements.create!(
      title: 'Synthetic announcement', body: 'Synthetic content', author: project.unit.main_convenor_user, published_at: nil
    )
    targets = [comment, project, announcement]
    records = targets.map { |target| FactoryBot.create(:notification, user: @user, notifiable: target) }

    result = inbox(unit_id: project.unit_id)

    assert_equal records.map(&:id).sort, result['notifications'].map { |row| row['id'] }.sort
    assert_equal project.unit_id, result['units'].first['id']
  end

  def test_removed_targets_and_empty_pages_have_truthful_counts
    FactoryBot.create(:notification, user: @user, link: '/projects/999999999/dashboard/1.1P')
    result = inbox(page: 99)
    assert_equal 1, result['page']
    assert_equal 1, result['total_count']
    assert_empty result['units']

    @user.notifications.delete_all
    empty = inbox
    assert_equal 0, empty['total_count']
    assert_nil empty['through_id']
    assert_empty empty['notifications']
  end

  def test_pagination_rejects_unbounded_and_invalid_inputs
    [{ per_page: 101 }, { per_page: 0 }, { page: 0 }, { unit_id: -1 }, { notification_type: 'unknown' }].each do |options|
      get '/api/notifications', { paginated: true }.merge(options)
      assert_equal 400, last_response.status, options.inspect
    end
  end

  def test_delete_boundary_retains_a_notification_that_arrives_after_loading
    FactoryBot.create(:notification, user: @user)
    snapshot = inbox
    arrived_later = FactoryBot.create(:notification, user: @user)
    delete '/api/notifications', through_id: snapshot['through_id']
    assert_equal 200, last_response.status
    assert_equal [arrived_later.id], @user.notifications.pluck(:id)
  end

  def test_inbox_requires_authentication
    clear_auth_header
    get '/api/notifications', paginated: true
    assert_includes [401, 403, 419], last_response.status
  end
end
