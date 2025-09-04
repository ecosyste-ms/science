class Api::V1::ProjectsController < Api::V1::ApplicationController
  def index
    @projects = Project.all.where.not(last_synced_at: nil)


    if params[:sort].present? || params[:order].present?
      sort = params[:sort].presence || 'projects.updated_at'
      if params[:order] == 'asc'
        @projects = @projects.order(Arel.sql(sort).asc.nulls_last)
      else
        @projects = @projects.order(Arel.sql(sort).desc.nulls_last)
      end
    end

    @pagy, @projects = pagy_countless(@projects)
  end

  def show
    @project = Project.find(params[:id])
  end

  def lookup
    @project = Project.find_by(url: params[:url].downcase)
    if @project.nil?
      @project = Project.create(url: params[:url].downcase)
      @project.sync_async
    end
    @project.sync_async if @project.last_synced_at.nil? || @project.last_synced_at < 1.day.ago
  end

  def ping
    @project = Project.find(params[:id])
    @project.sync_async
    render json: { message: 'pong' }
  end

  def packages
    @projects = Project.active.select{|p| p.packages.present? }.sort_by{|p| p.packages.sum{|p| p['downloads'] || 0 } }.reverse
  end

  def search
    @scope = Project
    
    if params[:q].present?
      @scope = @scope.where("url ILIKE ?", "%#{params[:q]}%")
    end
    
    if params[:keywords].present?
      @scope = @scope.keyword(params[:keywords])
    end
    
    if params[:language].present?
      @scope = @scope.language(params[:language])
    end
    
    @pagy, @projects = pagy(@scope, limit: 20)
  end
end