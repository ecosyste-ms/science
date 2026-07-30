class ReleasesController < ApplicationController
  def index
    @releases = Release.joins(:project).merge(Project.visible).order('published_at DESC')

    if params[:project_id]
      @project = Project.visible.find(params[:project_id])
      @releases = @releases.where(project_id: params[:project_id])
    end

    @pagy, @releases = pagy_countless(@releases)
  end

  def show
    @release = Release.joins(:project).merge(Project.visible).find(params[:id])
  end
end
