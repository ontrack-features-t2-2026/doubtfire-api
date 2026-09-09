require 'grape'

class ActivityTypesPublicApi < Grape::API
  desc "Get an activity type details"
  get '/activity_types/:id' do
    present ActivityType.find(params[:id]), with: Entities::ActivityTypeEntity
  end

  desc 'Get all the activity types'
  get '/activity_types' do
    if params.key?(:per_page) || params.key?(:page)
      per_page = params[:per_page].to_i > 0 ? [params[:per_page].to_i, 500].min : 50
      page = params[:page].to_i > 0 ? params[:page].to_i : 1
      result = ActivityType.limit(per_page).offset((page - 1) * per_page)
    else
      result = ActivityType.all
    end

    present result, with: Entities::ActivityTypeEntity
  end
end
