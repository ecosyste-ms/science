class OwnersController < ApplicationController
  before_action :find_host, only: [:index, :show]

  def institutional
    scope = Owner.institutional.includes(:host).order('projects_count DESC')
    @pagy, @owners = pagy(scope)
  end

  def index
    scope = @host.owners.visible.order('projects_count DESC')
    @pagy, @owners = pagy(scope)
  end

  def show
    @owner = params[:id]
    @owner_record = @host.owners.find_by('lower(login) = ?', @owner.downcase)
    raise ActiveRecord::RecordNotFound if @owner_record.nil? || @owner_record.hidden?

    @scope = Project.visible.where(owner_record: @owner_record).where('science_score > 0')

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'science_score')
      @scope = @scope.order(sort.public_send(sanitize_order).nulls_last)
    else
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end
end
