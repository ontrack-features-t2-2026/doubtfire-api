# frozen_string_literal: true

require 'grape'

class TaskPrioritizationApi < Grape::API
  helpers AuthenticationHelpers
  helpers AuthorisationHelpers
  helpers DbHelpers

  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 50

  before do
    authenticated?
  end

  desc 'Get prioritized task recommendations for a student',
       detail: 'Returns the authenticated student\'s active tasks ranked by deadline, effort, and workload.'

  params do
    optional :page, type: Integer, default: 1, values: ->(value) { value.positive? }
    optional :per_page, type: Integer, default: DEFAULT_PER_PAGE, values: 1..MAX_PER_PAGE
  end

  get '/tasks/recommended' do
    tasks = recommendation_tasks.to_a
    workload_score = calculate_workload_score(tasks.length)
    recommendations = tasks
                      .map { |task| build_task_response(task, workload_score) }
                      .sort_by { |recommendation| [-recommendation[:priority_score], recommendation[:task_id]] }

    offset = (params[:page] - 1) * params[:per_page]

    {
      data: recommendations.slice(offset, params[:per_page]) || [],
      meta: {
        page: params[:page],
        per_page: params[:per_page],
        total_count: recommendations.length,
        total_pages: (recommendations.length / params[:per_page].to_f).ceil
      }
    }
  end

  helpers do
    def recommendation_tasks
      Task
        .joins(project: :unit)
        .joins(:task_definition)
        .includes(:task_definition, project: :unit)
        .where(projects: { user_id: current_user.id, enrolled: true })
        .where(units: { active: true })
        .where.not(task_status_id: TaskStatus.complete.id)
        .where('task_definitions.target_grade <= projects.target_grade')
    end

    def build_task_response(task, workload_score)
      priority_score = (0.5 * deadline_score(task)) +
                       (0.3 * effort_score(task)) +
                       (0.2 * workload_score)

      {
        task_id: task.id,
        task_name: task.task_definition.name,
        project_id: task.project_id,
        unit_id: task.project.unit_id,
        priority_score: priority_score.round(2)
      }
    end

    def deadline_score(task)
      due_date = task.local_due_date
      return 0 unless due_date

      days_left = (due_date.to_date - Time.zone.today).to_i

      return 100 if days_left <= 1
      return 80 if days_left <= 3
      return 60 if days_left <= 7
      return 40 if days_left <= 14

      20
    end

    def effort_score(task)
      weighting = task.task_definition.weighting.to_f

      return 30 if weighting <= 10
      return 50 if weighting <= 20
      return 70 if weighting <= 40

      90
    end

    def calculate_workload_score(total_tasks)
      average_target_grade = Project
                             .for_user(current_user, false)
                             .average(:target_grade)
                             .to_f

      task_pressure_score =
        case total_tasks
        when 0..4 then 30
        when 5..9 then 60
        else 90
        end

      target_grade_score =
        case average_target_grade.round
        when 3 then 90
        when 2 then 75
        when 1 then 60
        else 40
        end

      ((0.6 * task_pressure_score) + (0.4 * target_grade_score)).round
    end
  end
end
