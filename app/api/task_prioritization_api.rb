require 'grape'

class TaskPrioritizationApi < Grape::API
  helpers AuthenticationHelpers
  helpers AuthorisationHelpers
  helpers DbHelpers

  before do
    authenticated?
  end

  desc 'Get prioritized task recommendations for a student',
       detail: 'Returns a ranked list of tasks across all active enrolled units based on deadline, effort, and workload scoring.'

  params do
    optional :page, type: Integer, default: 1
    optional :per_page, type: Integer, default: 10, values: 1..50
  end

  get '/tasks/recommended' do
    page = params[:page]
    per_page = params[:per_page]

    tasks = fetch_active_tasks
    workload_score = calculate_workload_score(tasks)

    results = tasks.map { |task| build_task_response(task, workload_score) }
    sorted = results.sort_by { |t| -t[:priority_score] }

    # Pagination after sorting
    offset = (page - 1) * per_page
    paginated = sorted.slice(offset, per_page) || []

    {
      data: paginated,
      meta: {
        page: page,
        per_page: per_page,
        total_count: sorted.size,
        total_pages: (sorted.size / per_page.to_f).ceil
      }
    }
  rescue StandardError => e
    Rails.logger.error "TaskPrioritizationApi Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    error!({ error: 'An unexpected error occurred' }, 500)
  end

  helpers do
    # Fetch Active Tasks
    def fetch_active_tasks
      Task
        .joins(project: :unit)
        .joins(:task_definition)
        .where(projects: { user_id: current_user&.id, enrolled: true })
        .where(units: { active: true })
        .where.not(task_status_id: 2) # completed
    end

    # Build Response Object
    def build_task_response(task, workload_score)
      deadline = deadline_score(task)
      effort   = effort_score(task)

      priority = (0.5 * deadline) + (0.3 * effort) + (0.2 * workload_score)

      {
        task_id: task.id,
        task_name: task.task_definition.name,
        unit_id: task.project.unit_id,
        priority_score: priority.round(2)
      }
    end

    # Deadline Score
    def deadline_score(task)
      due_date = task.task_definition.due_date
      return 0 unless due_date

      days_left = (due_date.to_date - Time.zone.today).to_i

      return 100 if days_left <= 1
      return 80  if days_left <= 3
      return 60  if days_left <= 7
      return 40  if days_left <= 14

      20
    end

    # Effort Score (Temporary - to be replaced by AI Task Prioritisation Service)
    def effort_score(task)
      weighting = task.task_definition.weighting.to_f

      return 30 if weighting <= 10
      return 50 if weighting <= 20
      return 70 if weighting <= 40

      90
    end

    # Workload Score
    def calculate_workload_score(tasks)
      total_tasks = tasks.count

      avg_target_grade = Project
                         .where(user_id: current_user&.id, enrolled: true)
                         .average(:target_grade)
                         .to_f

      task_pressure_score =
        case total_tasks
        when 0..4 then 30
        when 5..9 then 60
        else 90
        end

      target_grade_score =
        case avg_target_grade.round
        when 3 then 90   # High Distinction
        when 2 then 75   # Distinction
        when 1 then 60   # Credit
        else 40          # Pass
        end

      ((0.6 * task_pressure_score) + (0.4 * target_grade_score)).round
    end
  end
end
