class ModelsController < ApplicationController
  def index
    scope = Project.visible.model_projects.includes(project_fields: :field)
    if params[:q].present?
      query = "%#{Project.sanitize_sql_like(params[:q].strip)}%"
      scope = scope.where("projects.name ILIKE :query OR projects.url ILIKE :query", query: query)
    end
    if params[:keyword].present?
      scope = scope.where("EXISTS (SELECT 1 FROM unnest(projects.keywords) AS keyword WHERE lower(keyword) = ?)", params[:keyword].strip.downcase)
    end
    if params[:owner].present?
      scope = scope.where("lower(projects.repository->>'owner') = ?", params[:owner].strip.downcase)
    end
    @sort = %w[recently_synced science_score name].include?(params[:sort]) ? params[:sort] : "recently_synced"
    scope = case @sort
    when "name" then scope.order(:name, :id)
    when "science_score" then scope.order(Project.arel_table[:science_score].desc.nulls_last, id: :desc)
    else scope.order(Project.arel_table[:last_synced_at].desc.nulls_last, id: :desc)
    end
    @pagy, @projects = pagy(scope, limit: 20)
  end
end
