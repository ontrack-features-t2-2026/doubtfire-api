require 'grape'

class SettingsApi < Grape::API
  helpers AuthenticationHelpers

  before do
    authenticated?
  end

  desc 'Return authenticated feature configuration for the Doubtfire front end'
  get '/settings' do
    response = {
      overseerEnabled: Doubtfire::Application.config.overseer_enabled,
      tiiEnabled: TurnItIn.enabled?,
      d2lEnabled: D2lIntegration.enabled?
    }

    present response, with: Grape::Presenters::Presenter
  end
end
