# frozen_string_literal: true

class PeerProgressSnapshot < ApplicationRecord
  belongs_to :unit,
             inverse_of: :peer_progress_snapshots

  belongs_to :task_definition,
             inverse_of: :peer_progress_snapshots

  validates :target_grade,
            presence: true,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0
            },
            uniqueness: {
              scope: %i[unit_id task_definition_id]
            }

  validates :submitted_percentage,
            numericality: {
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 100
            },
            allow_nil: true

  validates :cohort_size,
            presence: true,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0
            }

  validates :calculated_at,
            presence: true

  validate :task_definition_belongs_to_unit
  validate :target_grade_enabled_for_unit
  validate :target_grade_covers_task
  validate :percentage_requires_non_empty_cohort

  private

  def task_definition_belongs_to_unit
    return if unit.blank? || task_definition.blank?
    return if task_definition.unit_id == unit_id

    errors.add(
      :task_definition,
      'must belong to the same unit'
    )
  end

  def target_grade_enabled_for_unit
    return if unit.blank? || target_grade.nil?
    return if unit.grade_value?(target_grade)

    errors.add(
      :target_grade,
      'must be enabled for the unit'
    )
  end

  def target_grade_covers_task
    return if task_definition.blank? || target_grade.nil?
    return if target_grade >= task_definition.target_grade

    errors.add(
      :target_grade,
      'must be at least the task definition target grade'
    )
  end

  def percentage_requires_non_empty_cohort
    return if submitted_percentage.nil?
    return if cohort_size.nil?
    return if cohort_size.positive?

    errors.add(
      :submitted_percentage,
      'must be blank when cohort size is zero'
    )
  end
end
