require 'test_helper'

class AcceptSubmissionJobTest < ActiveSupport::TestCase
  def test_pdf_regeneration_stops_before_submission_side_effects
    task = FactoryBot.create(:task)
    user = task.project.student
    states = []
    restored = false

    task.stub(:mark_submission_processing!, ->(state, **_options) { states << state }) do
      task.stub(:prepare_submission_regeneration!, -> { restored = true }) do
        task.stub(:convert_submission_to_pdf, true) do
          task.stub(:project, -> { raise 'submission side effects must not run' }) do
            Task.stub(:find, task) do
              User.stub(:find, user) do
                AcceptSubmissionJob.new.perform(task.id, user.id, false, false, 'regenerate_only')
              end
            end
          end
        end
      end
    end

    assert restored
    assert_equal %w[processing ready], states
  end
end
