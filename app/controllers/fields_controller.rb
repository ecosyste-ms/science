class FieldsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :render_404
  def index
    @fields = Field.all
    
    # Calculate project counts and average confidence for each field
    @field_stats = {}
    @fields.each do |field|
      project_count = field.project_fields.count
      @field_stats[field.id] = {
        project_count: project_count,
        avg_confidence: project_count > 0 ? field.project_fields.average(:confidence_score)&.round(2) : nil
      }
    end
    
    # Sort fields by domain and then by project count (descending) within each domain
    @fields = @fields.sort_by { |f| [f.domain, -@field_stats[f.id][:project_count]] }
  end

  def show
    @field = Field.find(params[:id])
    
    # Get projects in this field with their confidence scores
    @pagy, @project_fields = pagy(@field.project_fields
                                        .includes(:project)
                                        .order(confidence_score: :desc), 
                                  items: 20)
    
    # Calculate field statistics
    @stats = {
      total_projects: @field.project_fields.count,
      avg_confidence: @field.project_fields.average(:confidence_score)&.round(2),
      high_confidence_count: @field.project_fields.where('confidence_score >= ?', 0.7).count,
      medium_confidence_count: @field.project_fields.where('confidence_score >= ? AND confidence_score < ?', 0.5, 0.7).count,
      low_confidence_count: @field.project_fields.where('confidence_score < ?', 0.5).count
    }
    
    # Get top keywords from projects in this field (if there are any)
    @top_keywords = []
    if @field.project_fields.any?
      keyword_counts = Hash.new(0)
      @field.projects.limit(100).each do |project|
        if project.keywords.present? && project.keywords.is_a?(Array)
          project.keywords.each do |keyword|
            keyword_counts[keyword.to_s] += 1 if keyword.present?
          end
        end
      end
      @top_keywords = keyword_counts.sort_by { |_, count| -count }.first(20)
    end
  end
  
  private
  
  def render_404
    render plain: "Not found", status: :not_found
  end
end