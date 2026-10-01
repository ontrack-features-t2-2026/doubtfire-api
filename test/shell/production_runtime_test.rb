# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class ProductionRuntimeTest < Minitest::Test
  REPOSITORY_ROOT = File.expand_path('../..', __dir__)
  ENVIRONMENT_WRITER = File.join(
    REPOSITORY_ROOT,
    'lib/shell/write_cron_environment.sh'
  )
  PDFGEN_ENTRY_POINT = File.join(
    REPOSITORY_ROOT,
    'lib/shell/pdfgen_entry_point.sh'
  )
  SIDEKIQ_ENTRY_POINT = File.join(
    REPOSITORY_ROOT,
    'lib/shell/sidekiq_entry_point.sh'
  )

  def test_cron_environment_is_private_filtered_and_shell_safe
    Dir.mktmpdir do |directory|
      environment_file = File.join(directory, 'container.env')
      marker_file = File.join(directory, 'must-not-exist')
      secret_value = "line one\nline two ' \" $(touch #{marker_file})"
      File.write(environment_file, 'stale environment')
      File.chmod(0o644, environment_file)
      environment = {
        'BUNDLE_APP_CONFIG' => '/usr/local/bundle',
        'DF_SECRET_KEY_BASE' => secret_value,
        'DOCKER_AUTH_CONFIG' => 'must-not-be-persisted-docker-auth',
        'DOCKER_HOST' => 'tcp://docker-socket-proxy:2375',
        'DOCKER_TLS_VERIFY' => '1',
        'PATH' => ENV.fetch('PATH'),
        'RAILS_ENV' => 'production',
        'RAILS_MASTER_KEY' => 'rails-master-key',
        'UNRELATED_SECRET' => 'must-not-be-persisted'
      }

      stdout, stderr, status = Open3.capture3(
        environment,
        '/bin/bash',
        ENVIRONMENT_WRITER,
        environment_file,
        unsetenv_others: true
      )

      assert status.success?, stderr
      assert_empty stdout
      assert_equal 0o600, File.stat(environment_file).mode & 0o777

      contents = File.read(environment_file)
      assert_includes contents, 'DF_SECRET_KEY_BASE'
      assert_includes contents, 'DOCKER_HOST'
      assert_includes contents, 'DOCKER_TLS_VERIFY'
      assert_equal false, contents.include?('DOCKER_AUTH_CONFIG')
      assert_equal false, contents.include?('must-not-be-persisted-docker-auth')
      assert_equal false, contents.include?('UNRELATED_SECRET')
      assert_equal false, contents.include?('must-not-be-persisted')

      restore_command = [
        'source "$1"',
        'printf "%s\\0%s\\0%s\\0%s" "$DF_SECRET_KEY_BASE" "$RAILS_ENV" ' \
        '"$RAILS_MASTER_KEY" "$BUNDLE_APP_CONFIG"'
      ].join('; ')
      restored, restore_stderr, restore_status = Open3.capture3(
        {},
        '/bin/bash',
        '-c',
        restore_command,
        'restore-cron-environment',
        environment_file,
        unsetenv_others: true
      )

      assert restore_status.success?, restore_stderr
      expected = [
        secret_value,
        'production',
        'rails-master-key',
        '/usr/local/bundle'
      ].join("\0")
      assert_equal expected, restored
      assert_equal false, File.exist?(marker_file), 'sourcing the escaped value executed shell syntax'
    end
  end

  def test_entry_points_use_exec_and_do_not_print_the_environment_file
    pdfgen_entry_point = File.read(PDFGEN_ENTRY_POINT)
    sidekiq_entry_point = File.read(SIDEKIQ_ENTRY_POINT)

    assert_match(/^exec cron -f$/, pdfgen_entry_point)
    assert_equal false, %r{\bcat\s+/container\.env\b}.match?(pdfgen_entry_point)
    assert_equal false, /declare\s+-p/.match?(pdfgen_entry_point)
    assert_match(/^exec bundle exec sidekiq$/, sidekiq_entry_point)
  end

  def test_runtime_shell_scripts_have_valid_bash_syntax
    scripts = [ENVIRONMENT_WRITER, PDFGEN_ENTRY_POINT, SIDEKIQ_ENTRY_POINT]

    scripts.each do |script|
      _stdout, stderr, status = Open3.capture3('/bin/bash', '-n', script)
      assert status.success?, "#{script}: #{stderr}"
    end
  end

  def test_worker_image_restores_executable_permissions_after_copying_windows_archives
    dockerfile = File.read(File.join(REPOSITORY_ROOT, 'deployAppSvr.Dockerfile'))
    copy_position = dockerfile.index('COPY . ./')
    permission_position = dockerfile.index('chmod 0755 /doubtfire/lib/shell/*.sh')

    refute_nil copy_position
    refute_nil permission_position
    assert_operator permission_position, :>, copy_position
  end

  def test_tex_helper_stages_assets_into_its_isolated_compilation_directory
    Dir.mktmpdir do |directory|
      job = File.join(directory, 'sample-job')
      FileUtils.mkdir_p(File.join(job, 'assets'))
      File.write(File.join(job, 'input.tex'), 'Synthetic input')
      File.write(File.join(job, 'jupynotex.py'), '# synthetic helper')
      File.write(File.join(job, 'assets/source.pdf'), '%PDF-source')
      engine = File.join(directory, 'lualatex')
      File.write(engine, <<~SH)
        #!/bin/sh
        test "$(cat assets/source.pdf)" = '%PDF-source' || exit 4
        printf 'staged' > input.log
        printf '%%PDF-result' > input.pdf
      SH
      File.chmod(0o755, engine)
      environment = { 'TEXLIVE_WORK_ROOT' => directory, 'PATH' => "#{directory}:#{ENV.fetch('PATH')}" }
      _stdout, stderr, status = Open3.capture3(environment, '/bin/sh',
                                               File.join(REPOSITORY_ROOT, 'lib/shell/latex_build.sh'), 'sample-job')
      assert status.success?, stderr
      assert_equal '%PDF-result', File.read(File.join(job, 'input.pdf'))
      assert_equal false, File.exist?(File.join(job, 'work'))
    end
  end
end
