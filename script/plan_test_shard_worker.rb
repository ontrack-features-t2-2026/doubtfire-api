#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require_relative 'test_shard'

repository_root = File.expand_path('..', __dir__)
test_root = File.join(repository_root, 'test')
shard_count = TestShard.positive_integer('TEST_SHARD_COUNT')
worker_count = TestShard.positive_integer('TEST_SHARD_WORKER_COUNT')
worker_number = TestShard.positive_integer('TEST_SHARD_WORKER_NUMBER')
abort "TEST_SHARD_WORKER_NUMBER must be between 1 and #{worker_count}" if worker_number > worker_count

shards = TestShard.build(test_root: test_root, shard_count: shard_count)
workers = TestShard.worker_assignments(shards: shards, worker_count: worker_count)
logical_shards = workers.fetch(worker_number - 1).fetch(:shard_numbers)
manifest_dir = ENV.fetch('TEST_SHARD_MANIFEST_DIR', File.join(repository_root, 'tmp/test-shard-manifests'))
plan_path = ENV.fetch('TEST_SHARD_WORKER_PLAN', File.join(repository_root, 'tmp/test-shard-worker-plan.tsv'))
github_output_path = ENV.fetch('TEST_SHARD_GITHUB_OUTPUT', nil)
cache_writers = TestShard.cache_writer_shards(shards)

FileUtils.mkdir_p(manifest_dir)
FileUtils.mkdir_p(File.dirname(plan_path))
plan_rows = logical_shards.each_with_index.map do |shard_number, lane_index|
  shard = shards.fetch(shard_number - 1)
  runnables = shard.fetch(:runnables).sort
  services = TestShard.required_services(runnables)
  TestShard.write_manifest(File.join(manifest_dir, "shard-#{shard_number}.txt"), runnables)
  [shard_number, lane_index, services.fetch(:texlive), services.fetch(:jplag)]
end

jplag_shards = plan_rows.select { |row| row.fetch(3) }.map(&:first)
if jplag_shards.length > 1
  abort "Worker #{worker_number} assigned multiple JPlag shards: #{jplag_shards.join(', ')}"
end

plan_contents = plan_rows.map { |row| row.join("\t") }.join("\n")
File.write(plan_path, "#{plan_contents}\n")
unless github_output_path.to_s.empty?
  File.open(github_output_path, 'a') do |output|
    %i[texlive jplag].each_with_index do |service, service_index|
      service_column = service_index + 2
      output.puts "needs_#{service}=#{plan_rows.any? { |row| row.fetch(service_column) }}"
      output.puts "writes_#{service}_cache=#{logical_shards.include?(cache_writers.fetch(service))}"
    end
    output.puts "logical_shards=#{logical_shards.join(',')}"
    bake_targets = TestShard.image_build_targets(
      shards: shards,
      logical_shards: logical_shards,
      api_cache_writer: worker_number == 1
    )
    output.puts "bake_targets=#{bake_targets.join(',')}"
  end
end

puts "Test worker #{worker_number}/#{worker_count}: logical shards #{logical_shards.join(', ')}; " \
     "estimated combined weight #{workers.fetch(worker_number - 1).fetch(:weight).round(1)}"
