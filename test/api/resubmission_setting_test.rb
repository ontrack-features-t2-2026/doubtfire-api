require 'test_helper'

class ResubmissionSettingTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  setup do
    @unit = FactoryBot.create(:unit, student_count: 1, task_count: 1, staff_count: 2)
    @definition = @unit.task_definitions.first
    @endpoint = "/api/units/#{@unit.id}/task_definitions/#{@definition.id}"
  end

  test 'convenor can disable and reenable one task with server controlled change attribution' do
    add_auth_header_for(user: @unit.main_convenor_user)
    put_json @endpoint, { task_def: { resubmission_extensions_enabled: false,
                                    resubmission_extensions_changed_by_id: @unit.active_projects.first.student.id } }
    assert_equal 200, last_response.status, last_response.body
    assert_not @definition.reload.resubmission_extensions_enabled
    assert_equal false, last_response_body['resubmission_extensions_enabled']
    assert_equal @unit.main_convenor_user.id, @definition.resubmission_extensions_changed_by_id
    assert_not_nil @definition.resubmission_extensions_changed_at
    original_time = @definition.resubmission_extensions_changed_at
    put_json @endpoint, { task_def: { resubmission_extensions_enabled: false } }
    assert_equal original_time, @definition.reload.resubmission_extensions_changed_at
    put_json @endpoint, { task_def: { resubmission_extensions_enabled: true } }
    assert_equal 200, last_response.status
    assert @definition.reload.resubmission_extensions_enabled
  end

  test 'student tutor and unrelated convenor cannot change the setting' do
    tutor = FactoryBot.create(:user, :tutor)
    FactoryBot.create(:unit_role, unit: @unit, user: tutor, role: Role.tutor)
    outsider = FactoryBot.create(:unit, student_count: 0, task_count: 0).main_convenor_user
    [@unit.active_projects.first.student, tutor, outsider].each do |user|
      add_auth_header_for(user: user)
      put_json @endpoint, { task_def: { resubmission_extensions_enabled: false } }
      assert_equal 403, last_response.status, "Unexpected result for #{user.id}: #{last_response.body}"
      assert @definition.reload.resubmission_extensions_enabled
      assert_nil @definition.resubmission_extensions_changed_by_id
    end
  end
end
