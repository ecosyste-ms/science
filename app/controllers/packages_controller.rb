class PackagesController < ApplicationController
  def index
    scope = Package.by_publisher_science_score
      .preload({ package_papers: :paper }, { published_by_project: { project_papers: :paper } })
    @pagy, @packages = pagy_countless(scope, limit: 20)
  end
end
