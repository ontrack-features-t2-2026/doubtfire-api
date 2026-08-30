require 'test_helper'

class StudentImportConfigTest < ActiveSupport::TestCase
  CORRECT = 'DF_IMPORT_STUDENTS_WEEKS_BEFORE'.freeze
  MISSPELLED = 'DF_IMPORT_STUDENTS_WEEKS_BEFPRE'.freeze

  def teardown
    ENV.delete(CORRECT)
    ENV.delete(MISSPELLED)
  end

  def parse
    Doubtfire::Application.fetch_env_with_deprecated_alias(CORRECT, MISSPELLED, 1)
  end

  def test_reads_the_correctly_spelled_variable
    ENV[CORRECT] = '3'
    assert_equal '3', parse
  end

  def test_falls_back_to_the_misspelling_with_a_warning
    ENV[MISSPELLED] = '4'
    result = nil
    assert_output(nil, /DEPRECATION/) { result = parse }
    assert_equal '4', result
  end

  def test_correct_spelling_takes_precedence_over_the_misspelling
    ENV[CORRECT] = '3'
    ENV[MISSPELLED] = '9'
    assert_equal '3', parse
  end

  def test_uses_the_default_when_neither_is_set
    assert_equal 1, parse
  end
end
