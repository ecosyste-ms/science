class SwhidsController < ApplicationController
  def index
    @stats = SwhidStats.read
    render status: :service_unavailable unless @stats
  end
end
