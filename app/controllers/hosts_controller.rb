class HostsController < ApplicationController
  def index
    @hosts = Host.order('repositories_count DESC')
  end

  def show
    @host = Host.find_by_name!(params[:id])
    @projects = @host.projects.order('science_score DESC NULLS LAST').limit(100)
  end
end
