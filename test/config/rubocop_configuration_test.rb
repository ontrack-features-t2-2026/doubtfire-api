require 'minitest/autorun'
require 'yaml'

class RubocopConfigurationTest < Minitest::Test
  CONFIG_PATH = File.expand_path('../../.rubocop.yml', __dir__)

  def rubocop_config
    YAML.safe_load_file(CONFIG_PATH, aliases: true)
  end

  def test_test_directory_is_linted_with_required_plugins
    config = rubocop_config
    exclusions = config.fetch('AllCops').fetch('Exclude')
    plugins = config.fetch('plugins')

    refute_includes exclusions, 'test/**/*',
                    'test/**/* must not be excluded from RuboCop'
    assert_includes plugins, 'rubocop-minitest',
                    'rubocop-minitest must be loaded'
    assert_includes plugins, 'rubocop-factory_bot',
                    'rubocop-factory_bot must be loaded'
  end

  def test_invalid_configuration_exposes_missing_test_linting
    invalid_config = {
      'AllCops' => { 'Exclude' => ['test/**/*'] },
      'plugins' => ['rubocop-rails']
    }

    exclusions = invalid_config.fetch('AllCops').fetch('Exclude')
    plugins = invalid_config.fetch('plugins')

    assert_includes exclusions, 'test/**/*'
    refute_includes plugins, 'rubocop-minitest'
    refute_includes plugins, 'rubocop-factory_bot'
  end
end
