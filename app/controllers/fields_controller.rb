class FieldsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :render_404
  def index
    # Cache field stats for 1 hour since they change infrequently
    @field_stats = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch('field_index_stats', expires_in: 1.hour) do
        calculate_field_stats
      end
    else
      calculate_field_stats
    end

    @fields = Field.all.sort_by { |f| [f.domain, -@field_stats[f.id][:project_count]] }
  end

  def show
    @field = Field.find(params[:id])

    # Get projects in this field with their confidence scores
    @pagy, @project_fields = pagy(@field.project_fields
                                        .includes(:project)
                                        .order(confidence_score: :desc),
                                  items: 20)

    # Cache field statistics for 30 minutes
    @stats = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch("field_#{@field.id}_stats", expires_in: 30.minutes) do
        calculate_field_show_stats(@field)
      end
    else
      calculate_field_show_stats(@field)
    end

    # Cache top keywords for 1 hour
    @top_keywords = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch("field_#{@field.id}_keywords", expires_in: 1.hour) do
        calculate_top_keywords(@field)
      end
    else
      calculate_top_keywords(@field)
    end
  end
  
  private

  def calculate_field_stats
    # Use a single query to get counts and averages for all fields
    # This is more efficient than N+1 queries
    field_stats = {}

    # Get counts per field
    counts = ProjectField.group(:field_id).count
    # Get averages per field
    averages = ProjectField.group(:field_id).average(:confidence_score)

    Field.all.each do |field|
      project_count = counts[field.id] || 0
      field_stats[field.id] = {
        project_count: project_count,
        avg_confidence: project_count > 0 ? averages[field.id]&.round(2) : nil
      }
    end

    field_stats
  end

  def calculate_field_show_stats(field)
    {
      total_projects: field.project_fields.count,
      avg_confidence: field.project_fields.average(:confidence_score)&.round(2),
      high_confidence_count: field.project_fields.where('confidence_score >= ?', 0.7).count,
      medium_confidence_count: field.project_fields.where('confidence_score >= ? AND confidence_score < ?', 0.5, 0.7).count,
      low_confidence_count: field.project_fields.where('confidence_score < ?', 0.5).count
    }
  end

  def calculate_top_keywords(field)
    return [] unless field.project_fields.any?

    keyword_counts = Hash.new(0)
    field.projects.limit(100).each do |project|
      if project.keywords.present? && project.keywords.is_a?(Array)
        project.keywords.each do |keyword|
          keyword_counts[keyword.to_s] += 1 if keyword.present?
        end
      end
    end
    keyword_counts.sort_by { |_, count| -count }.first(20)
  end

  def render_404
    render plain: "Not found", status: :not_found
  end
end