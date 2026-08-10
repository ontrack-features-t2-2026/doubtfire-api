# frozen_string_literal: true

class AggregatePeerProgressJob
  include Sidekiq::Job
  include Sidekiq::Status::Worker
  include LogHelper
  include ApplicationHelper

  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { [args.first] },
                  on_conflict: :reject,
                  retry: false

  def perform(unit_id = nil)
    logger.info 'Starting peer progress aggregation...'

    at(0)
    total(1)

    calculated_at = Time.zone.now

    if unit_id.present?
        aggregate_unit(Unit.find(unit_id), calculated_at)
    else
        Unit.active_units.find_each do |unit|
            aggregate_unit(unit, calculated_at)
        end
    end

    at(1)
    logger.info 'Completed peer progress aggregation!'
  rescue StandardError => e
    logger.error "Peer progress aggregation failed: #{e.class}: #{e.message}"
    raise
  end

  private

  def aggregate_unit(unit, calculated_at)
    unless unit.active?
      logger.info(
        "Skipping peer progress aggregation for inactive unit_id=#{unit.id}"
      )
      return
    end

    PeerProgressAggregationService.call(
      unit: unit,
      calculated_at: calculated_at
    )
  end
end
