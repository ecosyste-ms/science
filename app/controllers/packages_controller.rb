class PackagesController < ApplicationController
  def index
    @pagy, @packages = pagy(Package.by_publisher_science_score, limit: 20)
    @packages = @packages.preload({ package_papers: :paper }, { published_by_project: { project_papers: :paper } })
  end
end
