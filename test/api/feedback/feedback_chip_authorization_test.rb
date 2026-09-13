require 'test_helper'

class FeedbackChipAuthorizationTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  def app
    Rails.application
  end

  def global_chip
    outcome = FactoryBot.create(:learning_outcome, context_type: nil, context_id: nil)
    FactoryBot.create(:feedback_template_chip, learning_outcome_id: outcome.id)
  end

  def test_student_cannot_track_feedback_chip_usage
    chip = global_chip
    tutor_user = FactoryBot.create(:user, :tutor)
    student = FactoryBot.create(:user, :student, enrol_in: 1)

    add_auth_header_for user: student
    post "api/feedback_template_chip/#{chip.id}/track_usage", tutor_id: tutor_user.id

    assert_equal 403, last_response.status,
      "Expected 403 Forbidden - a student should not be able to track feedback chip usage."
  end

  def test_tutor_can_track_feedback_chip_usage
    chip = global_chip
    tutor_user = FactoryBot.create(:user, :tutor)
    marking_tutor = FactoryBot.create(:user, :tutor)

    add_auth_header_for user: marking_tutor
    post "api/feedback_template_chip/#{chip.id}/track_usage", tutor_id: tutor_user.id

    assert_equal 201, last_response.status,
      "Expected 201 Created - a tutor should be able to track feedback chip usage. " \
      "Response: #{last_response.body}"

    usage = Feedback::ChipUsage.find_by(feedback_chip: chip, tutor: tutor_user)
    assert_not_nil usage, "Expected a ChipUsage record to be created"
    assert_equal 1, usage.usage_count
  end

  def test_convenor_can_track_feedback_chip_usage
    chip = global_chip
    tutor_user = FactoryBot.create(:user, :tutor)
    convenor = FactoryBot.create(:user, :convenor)

    add_auth_header_for user: convenor
    post "api/feedback_template_chip/#{chip.id}/track_usage", tutor_id: tutor_user.id

    assert_equal 201, last_response.status
  end
end
