# frozen_string_literal: true

class AggregatePeerProgressJob
  include Sidekiq::Job
  include Sidekiq::Status::Worker
  include LogHelper
  include ApplicationHelper

  sidekiq_options lock: :until_executed,
                  lock_args_method: lambda { |args|
                    [args.first || 'all-active-units']
                  },
                  on_conflict: :reject,
                  retry: 3

  def perform(unit_id = nil)
    return enqueue_active_units if unit_id.blank?

    aggregate_unit(Unit.find(unit_id))
  rescue StandardError => e
    logger.error(
      "Peer progress aggregation failed: #{e.class}: #{e.message}"
    )
    raise
  end

  private

  def enqueue_active_units
    logger.info(
      'Queueing peer progress aggregation for active units...'
    )

    Unit.active_units.find_each do |unit|
      self.class.perform_async(unit.id)
    end

    logger.info(
      'Queued peer progress aggregation jobs.'
    )
  end

  def aggregate_unit(unit)
    unless unit.active?
      logger.info(
        "Skipping peer progress aggregation for inactive unit_id=#{unit.id}"
      )
      return
    end

    logger.info(
      "Starting peer progress aggregation for unit_id=#{unit.id}..."
    )

    at(0)
    total(1)

    PeerProgressAggregationService.call(
      unit: unit,
      calculated_at: Time.zone.now
    )

    at(1)

    logger.info(
      "Completed peer progress aggregation for unit_id=#{unit.id}."
    )
  end
end
