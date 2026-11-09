class OwnersController < ApplicationController
  before_action :find_host, only: [:index, :show]

  def research_organizations
    scope = Owner.institutional.includes(:host).order('projects_count DESC')
    @pagy, @owners = pagy(scope)
    load_catalogue_counts
  end

  def index
    scope = @host.owners.visible.order('projects_count DESC')
    @pagy, @owners = pagy(scope)
    load_catalogue_counts
  end

  def show
    @owner = params[:id]
    @owner_record = @host.owners.find_by('lower(login) = ?', @owner.downcase)
    raise ActiveRecord::RecordNotFound if @owner_record.nil? || @owner_record.hidden?

    @scope = Project.visible.where(owner_record: @owner_record).in_catalogue

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'science_score')
      @scope = @scope.order(sort.public_send(sanitize_order).nulls_last)
    else
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end

  def load_catalogue_counts
    @catalogue_counts = Project.visible.in_catalogue.where(owner_id: @owners.map(&:id)).group(:owner_id).count
  end
end
