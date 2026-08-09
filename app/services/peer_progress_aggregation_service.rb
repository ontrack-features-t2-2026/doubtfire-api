# frozen_string_literal: true

# Calculates and stores task-level peer-progress snapshots for one unit.
#
# This service stores aggregate values only. It does not authorise students,
# apply the small-cohort display threshold, or expose API response data.
class PeerProgressAggregationService
  def self.call(unit:, calculated_at: Time.zone.now)
    new(unit: unit, calculated_at: calculated_at).call
  end

  def initialize(unit:, calculated_at:)
    unless unit.is_a?(Unit) && unit.persisted?
      raise ArgumentError, 'unit must be a persisted Unit'
    end
    raise ArgumentError, 'calculated_at is required' if calculated_at.blank?

    @unit = unit
    @calculated_at = calculated_at
  end

  def call
    snapshots = []

    PeerProgressSnapshot.transaction do
      existing_snapshots = PeerProgressSnapshot.where(unit: unit).index_by do |snapshot|
        [snapshot.task_definition_id, snapshot.target_grade]
      end

      unit.grade_values.map(&:to_i).uniq.sort.each do |target_grade|
        cohort = unit.active_projects.where(target_grade: target_grade)
        cohort_size = cohort.count

        task_definitions = unit.task_definitions
                               .where('target_grade <= ?', target_grade)
                               .order(:id)

        submitted_counts = submitted_counts_for(
          cohort: cohort,
          task_definitions: task_definitions
        )

        task_definitions.each do |task_definition|
          key = [task_definition.id, target_grade]

          snapshot = existing_snapshots[key] || PeerProgressSnapshot.new(
            unit: unit,
            task_definition: task_definition,
            target_grade: target_grade
          )

          snapshot.assign_attributes(
            cohort_size: cohort_size,
            submitted_percentage: percentage(
              submitted_count: submitted_counts.fetch(task_definition.id, 0),
              cohort_size: cohort_size
            ),
            calculated_at: calculated_at
          )

          snapshot.save!
          snapshots << snapshot
        end
      end
    end

    snapshots
  end

  private

  attr_reader :unit, :calculated_at

  def submitted_counts_for(cohort:, task_definitions:)
    Task
      .where(
        project_id: cohort.select(:id),
        task_definition_id: task_definitions.select(:id)
      )
      .where.not(submission_date: nil)
      .group(:task_definition_id)
      .distinct
      .count(:project_id)
  end

  def percentage(submitted_count:, cohort_size:)
    return nil if cohort_size.zero?

    ((submitted_count * 100.0) / cohort_size).round(2)
  end
end
