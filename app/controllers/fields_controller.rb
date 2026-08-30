class FieldsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :render_404

  def index
    @fields = Field.open_alex.order(:domain, :name).to_a
    @domains = @fields.group_by(&:domain_display_name).map do |domain_name, fields|
      {
        slug: domain_name.parameterize,
        name: domain_name,
        fields: fields,
      }
    end
    classifications = visible_classifications
    @field_stats = classifications.group(:field_id).distinct.count(:project_id)
    @classified_projects_count = classifications.distinct.count(:project_id)
    @multi_field_projects_count = classifications
      .group(:project_id)
      .having("COUNT(DISTINCT project_fields.field_id) > 1")
      .count
      .length
    @active_topic_count = OpenAlexTopic.active.count
  end

  def show
    field_slug = params[:slug].to_s
    @field = Field.open_alex.to_a.find { |field| field.to_param == field_slug }
    raise ActiveRecord::RecordNotFound unless @field

    classifications = @field.project_fields
      .joins(:project)
      .merge(Project.visible)
      .merge(Project.scientific)
    @pagy, @project_fields = pagy(
      classifications
        .includes(project: { project_fields: :field })
        .order(confidence_score: :desc),
      limit: 20
    )
    @stats = {
      total_projects: classifications.count,
      average_score: classifications.average(:confidence_score),
    }
    topics = OpenAlexTopic.active.where(field_id: @field.openalex_id)
    @domain_slug = @field.domain_display_name.parameterize
    @topic_count = topics.count
    @subfields = topics.distinct.order(:subfield_name)
      .pluck(:subfield_id, :subfield_name)
    @top_keywords = calculate_top_keywords(@field)
    @related_fields = Field.open_alex.where(domain: @field.domain)
      .where.not(id: @field.id)
      .order(:name)
    @related_field_counts = visible_classifications
      .where(field_id: @related_fields.select(:id))
      .group(:field_id)
      .distinct
      .count(:project_id)
  end

  def domain
    domain_slug = params[:slug].to_s
    domain = OpenAlexTopic.active.distinct
      .pluck(:domain_id, :domain_name)
      .find { |_domain_id, domain_name| domain_name.parameterize == domain_slug }
    raise ActiveRecord::RecordNotFound unless domain

    @domain_openalex_id, @domain_name = domain
    topics = OpenAlexTopic.active.where(domain_id: @domain_openalex_id)

    field_openalex_ids = topics.distinct.pluck(:field_id)
    @fields = Field.open_alex.where(openalex_id: field_openalex_ids).order(:name).to_a
    classifications = visible_classifications.where(field_id: @fields.map(&:id))
    @field_stats = classifications.group(:field_id).distinct.count(:project_id)
    @stats = {
      total_fields: @fields.length,
      total_projects: classifications.distinct.count(:project_id),
      total_topics: topics.count,
    }

    ranked_classification_ids = classifications
      .select("DISTINCT ON (project_fields.project_id) project_fields.id")
      .reorder(Arel.sql(
        "project_fields.project_id, project_fields.confidence_score DESC, project_fields.id"
      ))
    @pagy, @project_fields = pagy(
      ProjectField.where(id: ranked_classification_ids)
        .includes(:field, project: { project_fields: :field })
        .order(confidence_score: :desc, id: :asc),
      limit: 20
    )
  end

  def visible_classifications
    ProjectField.joins(:project, :field)
      .merge(Project.visible)
      .merge(Project.scientific)
      .merge(Field.open_alex)
  end

  def calculate_top_keywords(field)
    keyword_counts = Hash.new(0)
    field.projects.merge(Project.visible).limit(100).pluck(:keywords).each do |keywords|
      Array(keywords).each do |keyword|
        keyword_counts[keyword.to_s] += 1 if keyword.present?
      end
    end
    keyword_counts.sort_by { |keyword, count| [-count, keyword] }.first(20)
  end

  def render_404
    render plain: "Not found", status: :not_found
  end
end
