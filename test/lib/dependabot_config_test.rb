require 'minitest/autorun'
require 'yaml'

class DependabotConfigTest < Minitest::Test
  CONFIG_PATH = File.expand_path('../../.github/dependabot.yml', __dir__)

  def test_file_exists
    assert File.exist?(CONFIG_PATH), "dependabot.yml must exist in .github/"
  end

  def test_yaml_is_valid
    assert YAML.load_file(CONFIG_PATH), "dependabot.yml must be valid YAML"
  end

  def test_ecosystems_present
    content = File.read(CONFIG_PATH)
    assert_includes content, 'package-ecosystem: "github-actions"', "github-actions missing"
    assert_includes content, 'package-ecosystem: "bundler"', "bundler missing"
  end
end
