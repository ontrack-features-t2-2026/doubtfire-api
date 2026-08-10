# frozen_string_literal: true

require 'test_helper'

class PeerProgressAggregationServiceTest < ActiveSupport::TestCase
  def setup
    @unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0,
      tutorials: 0,
      staff_count: 0,
      outcome_count: 0
    )

    @pass_task = create(
      :task_definition,
      unit: @unit,
      target_grade: 0,
      outcome_count: 0
    )

    @credit_task = create(
      :task_definition,
      unit: @unit,
      target_grade: 1,
      outcome_count: 0
    )

    @calculated_at = Time.zone.parse('2026-08-10 10:00:00')
  end

  def test_calculates_percentage_for_enrolled_projects_in_the_same_target_grade
    projects = create_list(
      :project,
      4,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    projects.first(3).each do |project|
      create_submitted_task(
        project: project,
        task_definition: @pass_task
      )
    end

    other_grade = create(
      :project,
      unit: @unit,
      target_grade: 1,
      enrolled: true
    )

    create_submitted_task(
      project: other_grade,
      task_definition: @pass_task
    )

    withdrawn = create(
      :project,
      unit: @unit,
      target_grade: 0,
      enrolled: false
    )

    create_submitted_task(
      project: withdrawn,
      task_definition: @pass_task
    )

    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal 4, snapshot.cohort_size
    assert_equal 75.0, snapshot.submitted_percentage.to_f
    assert_equal @calculated_at, snapshot.calculated_at
  end

  def test_returns_a_genuine_zero_when_the_cohort_exists_but_nobody_has_submitted
    create_list(
      :project,
      4,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal 4, snapshot.cohort_size
    assert_equal 0.0, snapshot.submitted_percentage.to_f
  end

  def test_returns_nil_percentage_when_the_cohort_is_empty
    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 3
    )

    assert_equal 0, snapshot.cohort_size
    assert_nil snapshot.submitted_percentage
  end

  def test_only_creates_snapshots_for_tasks_applicable_to_the_target_grade
    create(
      :project,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    create(
      :project,
      unit: @unit,
      target_grade: 1,
      enrolled: true
    )

    run_service

    assert PeerProgressSnapshot.exists?(
      unit: @unit,
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_not PeerProgressSnapshot.exists?(
      unit: @unit,
      task_definition: @credit_task,
      target_grade: 0
    )

    assert PeerProgressSnapshot.exists?(
      unit: @unit,
      task_definition: @pass_task,
      target_grade: 1
    )

    assert PeerProgressSnapshot.exists?(
      unit: @unit,
      task_definition: @credit_task,
      target_grade: 1
    )
  end

  def test_counts_uploads_regardless_of_the_current_task_status
    statuses = [
      TaskStatus.ready_for_feedback,
      TaskStatus.complete,
      TaskStatus.redo,
      TaskStatus.fix_and_resubmit
    ]

    projects = create_list(
      :project,
      statuses.length,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    projects.zip(statuses).each do |project, status|
      create_submitted_task(
        project: project,
        task_definition: @pass_task,
        task_status: status
      )
    end

    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal statuses.length, snapshot.cohort_size
    assert_equal 100.0, snapshot.submitted_percentage.to_f
  end

  def test_does_not_mix_projects_or_submissions_from_another_unit
    local_projects = create_list(
      :project,
      2,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    create_submitted_task(
      project: local_projects.first,
      task_definition: @pass_task
    )

    other_unit = create(
      :unit,
      with_students: false,
      task_count: 0,
      stream_count: 0,
      tutorials: 0,
      staff_count: 0,
      outcome_count: 0
    )

    other_task = create(
      :task_definition,
      unit: other_unit,
      target_grade: 0,
      outcome_count: 0
    )

    other_projects = create_list(
      :project,
      4,
      unit: other_unit,
      target_grade: 0,
      enrolled: true
    )

    other_projects.each do |project|
      create_submitted_task(
        project: project,
        task_definition: other_task
      )
    end

    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal 2, snapshot.cohort_size
    assert_equal 50.0, snapshot.submitted_percentage.to_f
    assert_not PeerProgressSnapshot.exists?(unit: other_unit)
  end

  def test_does_not_create_missing_task_rows
    create_list(
      :project,
      2,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    assert_no_difference('Task.count') do
      run_service
    end
  end

  def test_updates_existing_snapshots_without_creating_duplicates
    projects = create_list(
      :project,
      2,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    run_service
    snapshot_count = PeerProgressSnapshot.count

    create_submitted_task(
      project: projects.first,
      task_definition: @pass_task
    )

    PeerProgressAggregationService.call(
      unit: @unit,
      calculated_at: @calculated_at + 1.hour
    )

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal snapshot_count, PeerProgressSnapshot.count
    assert_equal 50.0, snapshot.submitted_percentage.to_f
    assert_equal @calculated_at + 1.hour, snapshot.calculated_at
  end

  def test_rounds_percentages_to_two_decimal_places
    projects = create_list(
      :project,
      3,
      unit: @unit,
      target_grade: 0,
      enrolled: true
    )

    create_submitted_task(
      project: projects.first,
      task_definition: @pass_task
    )

    run_service

    snapshot = find_snapshot(
      task_definition: @pass_task,
      target_grade: 0
    )

    assert_equal 33.33, snapshot.submitted_percentage.to_f
  end

  def run_service
    PeerProgressAggregationService.call(
      unit: @unit,
      calculated_at: @calculated_at
    )
  end

  def find_snapshot(task_definition:, target_grade:)
    PeerProgressSnapshot.find_by!(
      unit: @unit,
      task_definition: task_definition,
      target_grade: target_grade
    )
  end

  def create_submitted_task(
    project:,
    task_definition:,
    task_status: TaskStatus.ready_for_feedback
  )
    create(
      :task,
      project: project,
      task_definition: task_definition,
      task_status: task_status,
      submission_date: @calculated_at - 1.hour
    )
  end
end
