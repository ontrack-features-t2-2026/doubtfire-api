# frozen_string_literal: true

require 'test_helper'

class UnitSimilarityCleanupTest < ActiveSupport::TestCase
  def test_jplag_cleanup_preserves_another_units_workspace
    unit = FactoryBot.create(:unit, with_students: false, task_count: 0)
    current_root = Rails.root.join('tmp', 'jplag', "#{unit.code}-#{unit.id}")
    tasks_dir = current_root.join('task-definition')
    other_root = Rails.root.join('tmp', 'jplag', "other-unit-#{SecureRandom.hex(6)}")
    sentinel = other_root.join('in-progress.sentinel')

    FileUtils.mkdir_p(tasks_dir)
    FileUtils.mkdir_p(other_root)
    FileUtils.touch(sentinel)

    unit.stub(:system, true) do
      unit.send(
        :run_jplag_on_done_files,
        jplag_task_definition,
        tasks_dir,
        [],
        Rails.root.join('tmp/jplag-results/report.jplag').to_s
      )
    end

    assert_not Dir.exist?(tasks_dir), 'the completed task workspace should be removed'
    assert File.exist?(sentinel), "another unit's in-progress workspace must survive cleanup"
  ensure
    FileUtils.rm_rf(current_root) if current_root
    FileUtils.rm_rf(other_root) if other_root
  end

  def test_jplag_cleanup_runs_when_the_container_command_fails
    unit = FactoryBot.create(:unit, with_students: false, task_count: 0)
    current_root = Rails.root.join('tmp', 'jplag', "#{unit.code}-#{unit.id}")
    tasks_dir = current_root.join('task-definition')
    other_root = Rails.root.join('tmp', 'jplag', "other-unit-#{SecureRandom.hex(6)}")
    sentinel = other_root.join('in-progress.sentinel')

    FileUtils.mkdir_p(tasks_dir)
    FileUtils.mkdir_p(other_root)
    FileUtils.touch(sentinel)

    system_calls = 0
    run_command = lambda do |_command|
      system_calls += 1
      system_calls < 3
    end

    error = assert_raises(RuntimeError) do
      unit.stub(:system, run_command) do
        unit.send(
          :run_jplag_on_done_files,
          jplag_task_definition,
          tasks_dir,
          [],
          Rails.root.join('tmp/jplag-results/report.jplag').to_s
        )
      end
    end

    assert_equal 'Failed to run JPlag similarity check', error.message
    assert_not Dir.exist?(tasks_dir), 'the failed task workspace should be removed'
    assert File.exist?(sentinel), "another unit's in-progress workspace must survive failed cleanup"
  ensure
    FileUtils.rm_rf(current_root) if current_root
    FileUtils.rm_rf(other_root) if other_root
  end

  def test_jplag_unit_root_cleanup_runs_after_a_top_level_failure
    unit = FactoryBot.create(:unit, with_students: false, task_count: 0)
    current_root = Rails.root.join('tmp', 'jplag', "#{unit.code}-#{unit.id}")
    other_root = Rails.root.join('tmp', 'jplag', "other-unit-#{SecureRandom.hex(6)}")
    sentinel = other_root.join('in-progress.sentinel')

    FileUtils.mkdir_p(current_root)
    FileUtils.mkdir_p(other_root)
    FileUtils.touch(sentinel)

    failing_definitions = Object.new
    failing_definitions.define_singleton_method(:each) { raise 'simulated scan setup failure' }

    error = assert_raises(RuntimeError) do
      unit.stub(:task_definitions, failing_definitions) do
        unit.check_jplag_similarity(force: true)
      end
    end

    assert_equal 'simulated scan setup failure', error.message
    assert_not Dir.exist?(current_root), 'the failed unit workspace should be removed'
    assert File.exist?(sentinel), "another unit's in-progress workspace must survive unit cleanup"
  ensure
    FileUtils.rm_rf(current_root) if current_root
    FileUtils.rm_rf(other_root) if other_root
  end

  private

  def jplag_task_definition
    task_definition = Struct.new(:plagiarism_warn_pct, :upload_requirements, :similarity_language)
                            .new(50, [], 'java')
    task_definition.define_singleton_method(:has_task_resources?) { false }
    task_definition
  end
end
