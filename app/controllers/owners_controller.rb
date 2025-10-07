class OwnersController < ApplicationController
  def institutional
    scope = Owner.institutional.includes(:host).order('projects_count DESC')
    @pagy, @owners = pagy(scope)
  end

  def index
    @host = Host.find_by_name!(params[:host_id])
    scope = @host.owners.order('projects_count DESC')
    @pagy, @owners = pagy(scope)
  end

  def show
    @host = Host.find_by_name!(params[:host_id])
    @owner = params[:id]
    @owner_record = @host.owners.find_by('lower(login) = ?', @owner.downcase)
    raise ActiveRecord::RecordNotFound unless @owner_record

    @scope = Project.where(owner_record: @owner_record).where('science_score > 0')

    if params[:sort]
      @scope = @scope.order("#{params[:sort]} #{params[:order]}")
    else
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end
end
