class HostsController < ApplicationController
  before_action :find_host_by_id, only: [:show]

  def index
    @hosts = Host.order('repositories_count DESC')
  end

  def show
    @scope = @host.projects.visible.scientific.includes(project_fields: :field)

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'science_score')
      @scope = @scope.order(sort.public_send(sanitize_order).nulls_last)
    else
      @scope = @scope.order(science_score: :desc, score: :desc)
    end

    @pagy, @projects = pagy_countless(@scope)
  end
end
