class HostsController < ApplicationController
  before_action :find_host_by_id, only: [:show]

  def index
    @hosts = Host.order('repositories_count DESC')
  end

  def show
    @scope = @host.projects.where('science_score > 0')

    if params[:sort]
      @scope = @scope.order("#{params[:sort]} #{params[:order]}")
    else
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end
end
