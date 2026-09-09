require 'grape'

class CampusesPublicApi < Grape::API
  desc "Get a campus details"
  get '/campuses/:id' do
    campus = Campus.find(params[:id])
    present campus, with: Entities::CampusEntity
  end

  desc 'Get all the Campuses'
  get '/campuses' do
    if params.key?(:per_page) || params.key?(:page)
      per_page = params[:per_page].to_i > 0 ? [params[:per_page].to_i, 500].min : 50
      page = params[:page].to_i > 0 ? params[:page].to_i : 1
      result = Campus.limit(per_page).offset((page - 1) * per_page)
    else
      result = Campus.all
    end

    present result, with: Entities::CampusEntity
  end
end
