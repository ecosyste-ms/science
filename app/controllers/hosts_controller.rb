class HostsController < ApplicationController
  before_action :find_host_by_id, only: [:show]

  def index
    @hosts = Host.order('repositories_count DESC')
  end

  def show
    @scope = @host.projects.visible.where('science_score > 0')

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'science_score')
      @scope = @scope.order(sort.public_send(sanitize_order).nulls_last)
    else
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end
end
