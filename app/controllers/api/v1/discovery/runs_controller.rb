class Api::V1::Discovery::RunsController < Api::V1::ApplicationController
  rescue_from ArgumentError, with: :invalid_parameters

  def index
    @pagy, @runs = pagy_countless(Jev::Run.order(id: :desc), limit: Jev::DiscoveryQuery.new(params).page_limit, limit_extra: false)
  end

  def show
    @run = Jev::Run.find(params[:id])
    @statistics = Rails.cache.fetch(["discovery-run-statistics", @run.id], expires_in: 1.minute) do
      @run.statistics.except(:last_error)
    end
  end

  def invalid_parameters(error)
    render json: { error: error.message }, status: :bad_request
  end
end
