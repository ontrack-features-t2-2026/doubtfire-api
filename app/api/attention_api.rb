# frozen_string_literal: true

class AttentionApi < Grape::API
  helpers AuthenticationHelpers

  before { authenticated? }

  desc 'Get the authenticated teaching staff member\'s assigned attention summary'
  get '/attention/staff' do
    header 'Cache-Control', 'private, no-store'
    StaffAttentionService.new(current_user).call
  end
end
