class Api::V1::SoftwareController < Api::V1::ApplicationController
  rescue_from ArgumentError do |error|
    render json: { error: error.message }, status: :bad_request
  end

  def lookup
    render json: SoftwareSearch.results(**query_options, kind: params.fetch(:kind, "name"))
  end

  def search
    render json: SoftwareSearch.results(**query_options, search: true)
  end

  def query_options
    { query: params[:q], limit: params.fetch(:limit, 10), after_id: params.fetch(:after_id, 0) }
  end
end
