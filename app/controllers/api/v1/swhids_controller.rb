class Api::V1::SwhidsController < Api::V1::ApplicationController
  def index
    stats = SwhidStats.read
    if stats
      render json: stats
    else
      render json: { error: "SWHID stats are not available yet" }, status: :service_unavailable
    end
  end
end
