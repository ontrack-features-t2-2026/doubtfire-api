# frozen_string_literal: true

require 'grape'

class TaskPrioritizationApi < Grape::API
  helpers AuthenticationHelpers
  helpers AuthorisationHelpers
  helpers DbHelpers

  before do
    authenticated?
  end

  desc 'Get prioritized task recommendations for a student',
       detail: 'Returns the authenticated student\'s actionable tasks ranked by effective deadline, relative task size, and deadline workload.'

  get '/tasks/recommended' do
    recommendations = TaskPrioritizationService.new(current_user).call

    {
      data: recommendations,
      meta: {
        total_count: recommendations.length
      }
    }
  end
end
