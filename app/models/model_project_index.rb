class ModelProjectIndex
  SORT_OPTIONS = [["Recently synced", "recently_synced"], ["Science Score", "science_score"], ["Name", "name"]].freeze
  SORTS = {
    "recently_synced" => "projects.last_synced_at DESC NULLS LAST, projects.id DESC",
    "science_score" => "projects.science_score DESC NULLS LAST, projects.id DESC",
    "name" => "lower(COALESCE(NULLIF(projects.name, ''), projects.repository->>'full_name', projects.url)) ASC, projects.id ASC"
  }.freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  def selected_sort
    SORTS.key?(params[:sort]) ? params[:sort] : "recently_synced"
  end

  def scope
    # A registry ID lets PostgreSQL use its package count when planning.
    registry_ids = PackageRegistry.where("lower(purl_type) = ?", "huggingface").pluck(:id)
    publishers = Package.where(package_registry_id: registry_ids).where.not(published_by_project_id: nil)
    projects = Project.visible.where(id: publishers.select(:published_by_project_id))
      .where("repository->'metadata'->>'model_package_purl' IS NOT NULL")
      .includes(project_fields: :field)
    if params[:q].present?
      query = "%#{Project.sanitize_sql_like(params[:q].strip)}%"
      projects = projects.where("projects.name ILIKE :query OR projects.url ILIKE :query", query: query)
    end
    if params[:keyword].present?
      projects = projects.where("EXISTS (SELECT 1 FROM unnest(projects.keywords) AS keyword WHERE lower(keyword) = ?)", params[:keyword].strip.downcase)
    end
    if params[:owner].present?
      projects = projects.where("lower(projects.repository->>'owner') = ?", params[:owner].strip.downcase)
    end
    projects.order(Arel.sql(SORTS.fetch(selected_sort)))
  end
end
