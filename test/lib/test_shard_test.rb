# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require Rails.root.join('script/test_shard').to_s

class TestShardTest < ActiveSupport::TestCase
  def test_build_is_deterministic_balanced_and_assigns_every_file_once
    Dir.mktmpdir do |test_root|
      line_counts = [90, 70, 50, 30, 20, 10]
      expected_files = line_counts.each_with_index.map do |line_count, index|
        path = File.join(test_root, "file_#{index}_test.rb")
        File.write(path, "# test line\n" * line_count)
        path
      end

      first = TestShard.build(test_root: test_root, shard_count: 3)
      second = TestShard.build(test_root: test_root, shard_count: 3)
      assigned_files = first.flat_map { |shard| shard.fetch(:files) }
      shard_weights = first.map { |shard| shard.fetch(:line_count) }

      assert_equal first, second
      assert_equal expected_files.sort, assigned_files.sort
      assert_equal expected_files.length, assigned_files.uniq.length
      assert(first.all? { |shard| shard.fetch(:files).any? })
      assert_operator shard_weights.max - shard_weights.min, :<=, line_counts.max
    end
  end

  def test_write_manifest_creates_an_exact_newline_delimited_file_list
    Dir.mktmpdir do |directory|
      manifest_path = File.join(directory, 'nested', 'shard-1.txt')
      selected_files = %w[test/api/projects_api_test.rb test/models/project_test.rb]

      TestShard.write_manifest(manifest_path, selected_files)

      assert_equal "#{selected_files.join("\n")}\n", File.read(manifest_path)
    end
  end
end
