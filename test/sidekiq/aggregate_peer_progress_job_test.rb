# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class AggregatePeerProgressJobTest < ActiveSupport::TestCase
  def setup
    @active_unit = create_minimal_unit(active: true)
    @inactive_unit = create_minimal_unit(active: false)
    @calculated_at = Time.zone.parse('2026-08-10 23:45:00')
  end

  def test_aggregates_the_requested_active_unit
    calls = []

    travel_to @calculated_at do
      PeerProgressAggregationService.stub(
        :call,
        lambda do |unit:, calculated_at:|
          calls << {
            unit: unit,
            calculated_at: calculated_at
          }
          []
        end
      ) do
        AggregatePeerProgressJob.new.perform(@active_unit.id)
      end
    end

    assert_equal 1, calls.length
    assert_equal @active_unit, calls.first[:unit]
    assert_equal @calculated_at, calls.first[:calculated_at]
  end

  def test_aggregates_all_active_units_when_no_unit_id_is_given
    expected_unit_ids = Unit.active_units.order(:id).pluck(:id)
    calls = []

    travel_to @calculated_at do
      PeerProgressAggregationService.stub(
        :call,
        lambda do |unit:, calculated_at:|
          calls << {
            unit_id: unit.id,
            calculated_at: calculated_at
          }
          []
        end
      ) do
        AggregatePeerProgressJob.new.perform
      end
    end

    actual_unit_ids = calls.map { |call| call[:unit_id] }.sort
    calculated_times = calls.map { |call| call[:calculated_at] }.uniq

    assert_equal expected_unit_ids, actual_unit_ids
    assert_equal [@calculated_at], calculated_times
    assert_not_includes expected_unit_ids, @inactive_unit.id
  end

  def test_skips_a_requested_inactive_unit
    calls = []

    PeerProgressAggregationService.stub(
      :call,
      lambda do |unit:, calculated_at:|
        calls << [unit, calculated_at]
        []
      end
    ) do
      AggregatePeerProgressJob.new.perform(@inactive_unit.id)
    end

    assert_empty calls
  end

  def test_raises_when_requested_unit_does_not_exist
    missing_unit_id = Unit.maximum(:id).to_i + 10_000

    assert_raises(ActiveRecord::RecordNotFound) do
      AggregatePeerProgressJob.new.perform(missing_unit_id)
    end
  end

  def test_reraises_aggregation_errors
    PeerProgressAggregationService.stub(
      :call,
      lambda do |**_kwargs|
        raise StandardError, 'aggregation failed'
      end
    ) do
      error = assert_raises(StandardError) do
        AggregatePeerProgressJob.new.perform(@active_unit.id)
      end

      assert_equal 'aggregation failed', error.message
    end
  end

  def test_enqueues_only_the_unit_id
    assert_difference -> { AggregatePeerProgressJob.jobs.size }, 1 do
      AggregatePeerProgressJob.perform_async(@active_unit.id)
    end

    queued_job = AggregatePeerProgressJob.jobs.last

    assert_equal [@active_unit.id], queued_job['args']
  end

  private

  def create_minimal_unit(active:)
    create(
      :unit,
      active: active,
      with_students: false,
      task_count: 0,
      stream_count: 0,
      tutorials: 0,
      staff_count: 0,
      outcome_count: 0
    )
  end
end
