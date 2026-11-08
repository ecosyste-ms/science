class Api::V1::Discovery::CandidatesController < Api::V1::ApplicationController
  rescue_from ArgumentError, with: :invalid_parameters

  def index
    query = Jev::DiscoveryQuery.new(params)
    @pagy, @candidates = pagy_countless(query.scope, limit: query.page_limit, limit_extra: false)
  end

  def show
    @candidate = Jev::Discovery.publicly_accessible.includes(:screen_request, :enrich_request).find(params[:id])
  end

  def invalid_parameters(error)
    render json: { error: error.message }, status: :bad_request
  end
end
