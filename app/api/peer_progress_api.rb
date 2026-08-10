# frozen_string_literal: true

require 'grape'

class PeerProgressApi < Grape::API
  helpers AuthenticationHelpers

  UNAVAILABLE_MESSAGE = 'Peer progress is currently unavailable.'
  NOT_FOUND_MESSAGE = 'Peer progress is unavailable for this project or task.'
  CONFIG_ERROR_MESSAGE = 'Peer progress is not configured.'

  before do
    authenticated?
  end

  helpers do
    def peer_progress_not_found!
      error!({ error: PeerProgressApi::NOT_FOUND_MESSAGE }, 404)
    end

    def positive_integer_env!(name)
      value = Integer(ENV.fetch(name), 10)
      raise ArgumentError unless value.positive?

      value
    rescue KeyError, ArgumentError
      error!({ error: PeerProgressApi::CONFIG_ERROR_MESSAGE }, 503)
    end

    def peer_progress_payload(
      project:,
      task_definition:,
      snapshot: nil,
      submitted_percentage: nil,
      is_suppressed: false,
      is_stale: false,
      is_feature_enabled: true,
      unavailable_message: ''
    )
      {
        task_definition_id: task_definition.id,
        unit_id: project.unit_id,
        target_grade: project.target_grade,
        submitted_percentage: submitted_percentage,
        is_suppressed: is_suppressed,
        is_stale: is_stale,
        is_feature_enabled: is_feature_enabled,
        last_updated_at: snapshot&.calculated_at&.iso8601,
        unavailable_message: unavailable_message
      }
    end

    def peer_progress_result(project:, task_definition:)
      unit = project.unit

      unless unit.peer_progress_enabled?
        return peer_progress_payload(
          project: project,
          task_definition: task_definition,
          is_feature_enabled: false,
          unavailable_message: PeerProgressApi::UNAVAILABLE_MESSAGE
        )
      end

      target_grade = project.target_grade
      unless target_grade.present? && unit.grade_value?(target_grade)
        return peer_progress_payload(
          project: project,
          task_definition: task_definition,
          unavailable_message: PeerProgressApi::UNAVAILABLE_MESSAGE
        )
      end

      snapshot = unit.peer_progress_snapshots.find_by(
        task_definition_id: task_definition.id,
        target_grade: target_grade
      )

      if snapshot.nil? || snapshot.cohort_size.zero? ||
         snapshot.submitted_percentage.nil?
        return peer_progress_payload(
          project: project,
          task_definition: task_definition,
          snapshot: snapshot,
          unavailable_message: PeerProgressApi::UNAVAILABLE_MESSAGE
        )
      end

      minimum_cohort_size = positive_integer_env!(
        'DF_PPI_MINIMUM_COHORT_SIZE'
      )
      stale_after_hours = positive_integer_env!(
        'DF_PPI_STALE_AFTER_HOURS'
      )

      if snapshot.cohort_size < minimum_cohort_size
        return peer_progress_payload(
          project: project,
          task_definition: task_definition,
          snapshot: snapshot,
          is_suppressed: true,
          unavailable_message: PeerProgressApi::UNAVAILABLE_MESSAGE
        )
      end

      if snapshot.calculated_at < stale_after_hours.hours.ago
        return peer_progress_payload(
          project: project,
          task_definition: task_definition,
          snapshot: snapshot,
          is_stale: true,
          unavailable_message: PeerProgressApi::UNAVAILABLE_MESSAGE
        )
      end

      peer_progress_payload(
        project: project,
        task_definition: task_definition,
        snapshot: snapshot,
        submitted_percentage: snapshot.submitted_percentage.to_f
      )
    end
  end

  desc 'Get anonymous task-level peer progress for the authenticated student',
       tags: ['peer_progress'],
       summary: 'Get anonymous task-level peer progress'
  params do
    requires :id,
             type: Integer,
             desc: 'The authenticated student project ID'
    requires :task_definition_id,
             type: Integer,
             desc: 'The task definition ID'
  end
  get '/projects/:id/task_def_id/:task_definition_id/peer_progress' do
    peer_progress_not_found! if current_user.role.id != Role.student_id

    project = Project.for_user(current_user, false)
                     .includes(:unit)
                     .find_by(id: params[:id])
    peer_progress_not_found! if project.nil?

    unit = project.unit
    task_definition = unit.task_definitions.find_by(
      id: params[:task_definition_id]
    )
    peer_progress_not_found! if task_definition.nil?

    released = task_definition.start_date.present? &&
               task_definition.start_date <= Time.zone.now
    peer_progress_not_found! unless released

    target_grade = project.target_grade
    if target_grade.present? && unit.grade_value?(target_grade) &&
       task_definition.target_grade > target_grade
      peer_progress_not_found!
    end

    header 'Cache-Control', 'private, no-store'

    present peer_progress_result(
      project: project,
      task_definition: task_definition
    ), with: Grape::Presenters::Presenter
  end
end
