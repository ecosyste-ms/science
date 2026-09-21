class Api::V1::PackageVersionsController < Api::V1::ApplicationController
  def index
    @package = Package.where(published_by_project_id: Project.visible.select(:id)).find(params[:package_id])
    @pagy, @package_versions = pagy_countless(@package.package_versions.recent)
  end

  def show
    @package = Package.where(published_by_project_id: Project.visible.select(:id)).find(params[:package_id])
    @package_version = @package.package_versions.find(params[:id])
  end
end
