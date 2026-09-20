class ReleasesController < ApplicationController
  def index
    @releases = Release.joins(:project).merge(Project.visible).includes(:project).recent

    if params[:project_id]
      @project = Project.visible.find(params[:project_id])
      @releases = @releases.where(project_id: params[:project_id])
    end

    @pagy, @releases = pagy_countless(@releases)
  end

  def show
    @project = Project.visible.find(params[:project_id])
    @release = @project.releases.find(params[:id])
  end
end
