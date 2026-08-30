require 'test_helper'

# Covers POST /units/:id/similarity/scan, the on-demand plagiarism rescan.
class UnitsSimilarityScanApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  # A tutor is not one of the roles granted :run_similarity_scan, so the endpoint
  # must refuse before it queues anything.
  def test_tutor_cannot_run_similarity_scan
    unit = FactoryBot.create(:unit, with_students: false, task_count: 0)
    tutor = FactoryBot.create(:user, :tutor)
    unit.employ_staff(tutor, Role.tutor)

    add_auth_header_for(user: tutor)
    post "/api/units/#{unit.id}/similarity/scan"

    assert_equal 403, last_response.status, last_response_body
  end

  # A scan recorded in the last 30 minutes puts the unit inside the cooldown, so a
  # convenor's request is rate limited rather than queuing a second scan.
  def test_similarity_scan_is_rate_limited_within_the_cooldown
    unit = FactoryBot.create(:unit, with_students: false, task_count: 0)
    unit.update_column(:last_plagarism_scan, Time.zone.now)

    add_auth_header_for(user: unit.main_convenor_user)
    post "/api/units/#{unit.id}/similarity/scan"

    assert_equal 429, last_response.status, last_response_body
  end
end
