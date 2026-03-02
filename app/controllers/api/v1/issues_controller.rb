class Api::V1::IssuesController < Api::V1::ApplicationController
  def index
    scope = Issue.where(pull_request: false, state: 'open').includes(:project)
    scope = scope.joins(:project).good_first_issue

    # Apply filters if provided
    scope = scope.joins(:project).where(projects: { category: params[:category] }) if params[:category].present?
    scope = scope.joins(:project).merge(Project.language(params[:language])) if params[:language].present?
    scope = scope.joins(:project).merge(Project.keyword(params[:keyword])) if params[:keyword].present?

    scope = scope.where('issues.created_at > ?', 1.day.ago) if params[:recent].present?

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Issue.sortable_columns, default: 'created_at')
      if params[:order] == 'asc'
        scope = scope.order(sort.asc.nulls_last)
      else
        scope = scope.order(sort.desc.nulls_last)
      end
    else
      scope = scope.order('issues.created_at DESC')
    end

    @pagy, @issues = pagy(scope)
  end
end