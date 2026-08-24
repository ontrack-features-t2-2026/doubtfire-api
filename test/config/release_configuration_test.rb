# frozen_string_literal: true

require 'test_helper'

class ReleaseConfigurationTest < Minitest::Test
  RUBY_BASE = 'ruby:3.4.8-bookworm@sha256:414d93f64867bcb587aefa61cb77141a2464f0bb9cff30a05044c6341c0a9450'

  def test_production_application_images_are_pinned_and_daemon_free
    api = read('deployApi.Dockerfile')
    worker = read('deployAppSvr.Dockerfile')

    assert_match(/^FROM #{Regexp.escape(RUBY_BASE)}$/m, api)
    assert_match(/^FROM #{Regexp.escape(RUBY_BASE)}$/m, worker)
    assert_match(
      /^FROM docker:28\.5\.2-cli@sha256:[0-9a-f]{64} AS docker_cli$/m,
      worker
    )

    [api, worker].each do |dockerfile|
      assert_equal false, /\b(?:docker-ce|containerd\.io)\b/.match?(dockerfile)
      assert_equal false, /^\s*redis\s*\\?$/m.match?(dockerfile)
      assert_match(/bundle config set deployment true/, dockerfile)
    end

    assert_equal false, /db:migrate/.match?(api)
    assert_match(
      /CMD \["bundle", "exec", "rails", "server", "-b", "0\.0\.0\.0"\]/,
      api
    )
  end

  def test_docker_build_context_excludes_local_credentials
    dockerignore = read('.dockerignore').lines.map(&:strip)
    required_patterns = %w[
      .docker
      .bundle
      .env
      .env.*
      .npmrc
      .gem/credentials
      .ssh
      .aws
      .config/gcloud
      config/master.key
      config/credentials
      config/credentials.yml.enc
      **/*.key
      **/*.pem
      **/*.p12
      **/*.pfx
      **/*.jks
      **/*.keystore
    ]

    required_patterns.each { |pattern| assert_includes dockerignore, pattern }
    assert_includes dockerignore, '!.env.example'
  end

  def test_helper_images_pin_bases_and_verify_downloads
    texlive = read('texlive.Dockerfile')
    jplag = read('jplag.Dockerfile')

    texlive.scan(/^FROM (\S+)/).flatten.each do |base|
      assert_match(/@sha256:[0-9a-f]{64}\z/, base)
    end
    assert_includes texlive, '/historic/systems/texlive/2025/tlnet-final'
    assert_includes texlive, 'sha512sum --check'
    assert_includes texlive, 'tlmgr --repository "$TL_MIRROR" install'
    assert_includes texlive, 'pdfmanagement-testphase'
    assert_equal false, /^\s*pdfmanagement\s*\\$/m.match?(texlive)
    assert_includes texlive, 'kpsewhich pdfmanagement-testphase.sty'
    assert_includes texlive, '--jobname=pdfmanagement-smoke'

    assert_match(/^FROM alpine:3\.23\.3@sha256:[0-9a-f]{64}$/m, jplag)
    assert_includes jplag, 'JPLAG_SHA256='
    assert_includes jplag, 'sha256sum -c -'
  end

  def test_development_compose_has_no_literal_institution_credential
    compose = read('docker-compose.yml')

    assert_match(/DF_SECRET_KEY_AAF:\s*\$\{DF_SECRET_KEY_AAF:-\}/, compose)
    assert_equal false, %r{https?://[^\s$]*(?:aaf\.edu\.au|deakin\.edu\.au)}i.match?(compose)
  end

  def test_production_image_workflow_actions_are_immutable
    workflows = [
      read('.github/workflows/production-images.yml'),
      read('.github/workflows/deployment.yml')
    ]

    workflows.each do |workflow|
      workflow.each_line.grep(/^\s*uses:/).each do |line|
        assert_match(/@[0-9a-f]{40}(?:\s+#.*)?$/, line)
      end
    end

    release_workflow = workflows.last
    assert_operator release_workflow.scan(/^\s*sbom:\s*true$/).length, :>=, 2
    assert_operator release_workflow.scan(/^\s*provenance:\s*mode=max$/).length, :>=, 2
    assert_equal 3, release_workflow.scan(/^\s*push:\s*false$/).length
    assert_equal false, release_workflow.include?('docker/login-action')
    assert_equal false, release_workflow.include?('DOCKERHUB_TOKEN')

    validation_workflow = workflows.first
    %w[deployApi.Dockerfile deployAppSvr.Dockerfile texlive.Dockerfile jplag.Dockerfile].each do |dockerfile|
      assert_includes validation_workflow, dockerfile
    end
    assert_equal false, validation_workflow.include?('paths:')
  end

  private

  def read(path)
    Rails.root.join(path).read
  end
end
