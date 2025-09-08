class ProjectsController < ApplicationController
  def show
    @project = Project.find(params[:id])
  end

  def index
    @stats = Rails.cache.fetch('homepage_stats', expires_in: 1.hour) do
      Project.stats_summary
    end
    
    @scope = Project.where('science_score > 0')

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:owner].present?
      @scope = @scope.owner(params[:owner])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    if params[:sort]
      @scope = @scope.order("#{params[:sort]} #{params[:order]}")
    else
      @scope = @scope.order('score DESC nulls last')
    end

    @pagy, @projects = pagy(@scope)
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

  def lookup
    @project = Project.find_by(url: params[:url].downcase)
    if @project.nil?
      @project = Project.create(url: params[:url].downcase)
      @project.sync_async
    end
    redirect_to @project
  end

  def review
    @scope = Project.matching_criteria

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:owner].present?
      @scope = @scope.owner(params[:owner])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    if params[:sort]
      @scope = @scope.order("#{params[:sort]} #{params[:order]}")
    else
      @scope = @scope.order('created_at DESC')
    end

    @pagy, @projects = pagy(@scope)
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.valid?
      @project = Project.find_by(url: params[:project][:url].downcase)
      if @project.nil?

        @project = Project.new(project_params)

        if @project.save
          @project.sync_async
          redirect_to @project
        else
          render 'new'
        end
      else
        redirect_to @project
      end
    else
      render 'new'
    end
  end

  def project_params
    params.require(:project).permit(:url, :name, :description)
  end

  def dependencies
    @dependencies = Project.map(&:dependency_packages).flatten(1).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
    @dependency_records = Dependency.where('count > 1').includes(:project)
    @packages = []
  end

  def packages
    @projects = Project.select{|p| p.packages.present? }.sort_by{|p| p.packages.sum{|p| p['downloads'] || 0 } }.reverse
  end

  def images
    @projects = Project.select{|p| p.readme_image_urls.present? }
  end
end