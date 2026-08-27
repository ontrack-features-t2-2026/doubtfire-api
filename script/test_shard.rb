#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Split the Rails test files into deterministic, approximately even shards.
#
# File line count is used as a stable runtime proxy. Assigning the largest files
# first to the lightest shard avoids a hard-coded manifest, so new *_test.rb
# files are included automatically.
# Preview a shard without running Rails by passing --dry-run.
# Set TEST_SHARD_MANIFEST to write the selected repository-relative file list.
module TestShard
  module_function

  def build(test_root:, shard_count:)
    test_files = Dir.glob(File.join(test_root, '**', '*_test.rb'))
    abort "No test files found under #{test_root}" if test_files.empty?
    abort "TEST_SHARD_COUNT cannot exceed the #{test_files.length} discovered test files" if shard_count > test_files.length

    weighted_files = test_files.map do |path|
      [path, File.foreach(path).count]
    end

    shards = Array.new(shard_count) { { line_count: 0, files: [] } }

    weighted_files.sort_by { |path, line_count| [-line_count, path] }.each do |path, line_count|
      shard_index = shards.each_index.min_by { |index| [shards[index][:line_count], index] }
      shards[shard_index][:files] << path
      shards[shard_index][:line_count] += line_count
    end

    assigned_files = shards.flat_map { |shard| shard[:files] }
    unless assigned_files.length == test_files.length &&
           assigned_files.uniq.length == test_files.length &&
           assigned_files.sort == test_files.sort
      abort 'Internal error: test sharding did not assign every test file exactly once'
    end

    shards
  end

  def positive_integer(name)
    value = Integer(ENV.fetch(name, ''), exception: false)
    abort "#{name} must be a positive integer" unless value&.positive?

    value
  end

  def write_manifest(path, selected_files)
    return if path.to_s.empty?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{selected_files.join("\n")}\n")
  end

  def run(argv)
    unknown_arguments = argv - ['--dry-run']
    abort "Unknown argument(s): #{unknown_arguments.join(' ')}" unless unknown_arguments.empty?

    shard_count = positive_integer('TEST_SHARD_COUNT')
    shard_number = positive_integer('TEST_SHARD_NUMBER')
    abort "TEST_SHARD_NUMBER must be between 1 and #{shard_count}" if shard_number > shard_count

    repository_root = File.expand_path('..', __dir__)
    shards = build(test_root: File.join(repository_root, 'test'), shard_count: shard_count)
    selected_shard = shards.fetch(shard_number - 1)
    selected_files = selected_shard[:files].sort.map do |path|
      path.delete_prefix("#{repository_root}/")
    end

    puts "Test shard #{shard_number}/#{shard_count}: " \
         "#{selected_files.length} of #{shards.sum { |shard| shard[:files].length }} files, " \
         "#{selected_shard[:line_count]} of #{shards.sum { |shard| shard[:line_count] }} lines"
    selected_files.each { |path| puts "  #{path}" }
    write_manifest(ENV.fetch('TEST_SHARD_MANIFEST', nil), selected_files)

    return if argv.include?('--dry-run')

    $stdout.flush
    Dir.chdir(repository_root) do
      exec('bundle', 'exec', 'rails', 'test', *selected_files)
    end
  end
end

TestShard.run(ARGV) if $PROGRAM_NAME == __FILE__
