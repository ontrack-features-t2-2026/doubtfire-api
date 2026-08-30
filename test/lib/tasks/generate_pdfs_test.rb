require "test_helper"

class GeneratePdfsRakeTest < ActiveSupport::TestCase
  def setup
    load Rails.root.join("lib", "tasks", "generate_pdfs.rake").to_s unless defined?(is_process_running?)
  end

  test "is_process_running? returns false for pid 0 instead of raising" do
    assert_equal false, is_process_running?(0)
  end
end
