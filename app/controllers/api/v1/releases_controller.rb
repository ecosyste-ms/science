class Api::V1::ReleasesController < Api::V1::ApplicationController
  def index
    @project = Project.visible.find(params[:project_id])
    @pagy, @releases = pagy_countless(@project.releases.recent)
  end

  def show
    @project = Project.visible.find(params[:project_id])
    @release = @project.releases.find(params[:id])
  end
end
