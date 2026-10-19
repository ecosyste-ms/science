class Api::V1::PackagesController < Api::V1::ApplicationController
  def repositories
    relationships = PackageRepositoryRelationships.new(Package.find(params[:id]))
    @pagy, projects = pagy(relationships.scope.order(:id), limit_max: 100)
    render json: relationships.for_projects(projects)
  end

  def bulk_lookup
    @packages = Package.bulk_lookup(params[:purls])
    render :index
  rescue ArgumentError => error
    render json: { error: error.message }, status: :bad_request
  end

  def index
    @pagy, @packages = pagy(Package.by_publisher_science_score)
  end
end
