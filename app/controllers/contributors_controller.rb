class ContributorsController < ApplicationController
  def index
    scope = Contributor.visible.display.order('last_synced_at DESC')
    @pagy, @contributors = pagy(scope)
  end

  def show
    @contributor = Contributor.visible.find(params[:id])
  end
end
