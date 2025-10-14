class ContributorsController < ApplicationController
  def index
    scope = Contributor.display.order('last_synced_at DESC')
    @pagy, @contributors = pagy(scope)
  end

  def show
    @contributor = Contributor.find(params[:id])
  end
end