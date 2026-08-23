require 'test_helper'

class PeerProgressSnapshotTest < ActiveSupport::TestCase
  setup do
    @unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0
    )

    @task_definition = create(
      :task_definition,
      unit: @unit,
      target_grade: 0,
      outcome_count: 0
    )
  end

  test 'is valid with the required aggregate fields' do
    assert build_snapshot.valid?
  end

  test 'belongs to its unit and task definition' do
    snapshot = create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition
    )

    assert_equal @unit, snapshot.unit
    assert_equal @task_definition, snapshot.task_definition
  end

  test 'requires a calculation timestamp' do
    snapshot = build_snapshot(calculated_at: nil)

    assert_not snapshot.valid?

    assert_includes(
      snapshot.errors[:calculated_at],
      "can't be blank"
    )
  end

  test 'accepts a genuine zero percentage for a non-empty cohort' do
    snapshot = build_snapshot(
      submitted_percentage: 0,
      cohort_size: 10
    )

    assert snapshot.valid?
  end

  test 'accepts a nil percentage for unavailable or suppressed data' do
    suppressed = build_snapshot(
      submitted_percentage: nil,
      cohort_size: 3
    )

    unavailable = build_snapshot(
      submitted_percentage: nil,
      cohort_size: 0
    )

    assert suppressed.valid?
    assert unavailable.valid?
  end

  test 'rejects percentages outside zero to one hundred' do
    below_zero = build_snapshot(
      submitted_percentage: -0.01
    )

    above_one_hundred = build_snapshot(
      submitted_percentage: 100.01
    )

    assert_not below_zero.valid?
    assert_not above_one_hundred.valid?
  end

  test 'requires a non-negative integer cohort size' do
    negative = build_snapshot(cohort_size: -1)
    decimal = build_snapshot(cohort_size: 2.5)

    assert_not negative.valid?
    assert_not decimal.valid?
  end

  test 'does not allow a percentage when cohort size is zero' do
    snapshot = build_snapshot(
      submitted_percentage: 0,
      cohort_size: 0
    )

    assert_not snapshot.valid?

    assert_includes(
      snapshot.errors[:submitted_percentage],
      'must be blank when cohort size is zero'
    )
  end

  test 'requires the task definition to belong to the same unit' do
    other_unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0
    )

    snapshot = build_snapshot(unit: other_unit)

    assert_not snapshot.valid?

    assert_includes(
      snapshot.errors[:task_definition],
      'must belong to the same unit'
    )
  end

  test 'requires a target grade enabled for the unit' do
    snapshot = build_snapshot(target_grade: 99)

    assert_not snapshot.valid?

    assert_includes(
      snapshot.errors[:target_grade],
      'must be enabled for the unit'
    )
  end

  test 'requires the cohort grade to cover the task target grade' do
    higher_grade_task = create(
      :task_definition,
      unit: @unit,
      target_grade: 2,
      outcome_count: 0
    )

    snapshot = build_snapshot(
      task_definition: higher_grade_task,
      target_grade: 1
    )

    assert_not snapshot.valid?

    assert_includes(
      snapshot.errors[:target_grade],
      'must be at least the task definition target grade'
    )
  end

  test 'enforces one snapshot per unit task and target grade' do
    create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition,
      target_grade: 0
    )

    duplicate = build_snapshot(target_grade: 0)

    assert_not duplicate.valid?

    assert_includes(
      duplicate.errors[:target_grade],
      'has already been taken'
    )
  end

  test 'allows another target grade for the same unit and task' do
    create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition,
      target_grade: 0
    )

    second_grade = build_snapshot(target_grade: 1)

    assert second_grade.valid?,
           second_grade.errors.full_messages.to_sentence
  end

  test 'database index rejects duplicate aggregate keys' do
    snapshot = create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition,
      target_grade: 0
    )

    duplicate = snapshot.dup

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test 'destroying a task definition destroys its snapshots' do
    snapshot = create(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition
    )

    snapshot_id = snapshot.id

    @task_definition.destroy!

    assert_not PeerProgressSnapshot.exists?(snapshot_id)
  end

  private

  def build_snapshot(**overrides)
    build(
      :peer_progress_snapshot,
      unit: @unit,
      task_definition: @task_definition,
      **overrides
    )
  end
end
