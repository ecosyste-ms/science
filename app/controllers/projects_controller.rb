class ProjectsController < ApplicationController
  def show
    @project = Project.find(params[:id])
  end

  def index
    # Cache stats for 6 hours since they don't change that frequently
    # Use cache in all environments where it's configured (not just production)
    @stats = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch('homepage_stats', expires_in: 6.hours) do
        Project.stats_summary
      end
    else
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
      @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end

    @pagy, @projects = pagy(@scope)
  end

  def search
    @scope = Project.where('science_score > 0')

    if params[:q].present?
      @scope = @scope.where("url ILIKE ?", "%#{params[:q]}%")
    end

    if params[:keywords].present?
      @scope = @scope.keyword(params[:keywords])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))

    @pagy, @projects = pagy(@scope, limit: 20)
  end

  def lookup
    @query = params[:q]
    @results = ProjectSearch.new(@query, 20).search if @query.present?
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
    # Check for existing project first
    existing_project = Project.find_by(url: params[:project][:url].downcase)
    if existing_project
      redirect_to existing_project
    else
      @project = Project.new(project_params)
      if @project.save
        @project.sync_async
        redirect_to @project
      else
        render 'new'
      end
    end
  end

  def project_params
    params.require(:project).permit(:url, :name, :description)
  end

  def dependencies
    # Cache dependencies aggregation for 2 hours
    @dependencies = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch('dependencies_aggregation', expires_in: 2.hours) do
        Project.all.map(&:dependency_packages).flatten(1).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
      end
    else
      Project.all.map(&:dependency_packages).flatten(1).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
    end

    # Cache ecosystem counts for 2 hours
    @ecosystem_counts = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch('dependency_ecosystem_counts', expires_in: 2.hours) do
        Dependency.group(:ecosystem).count.sort_by{|k,v| v}.reverse
      end
    else
      Dependency.group(:ecosystem).count.sort_by{|k,v| v}.reverse
    end

    @dependency_records = Dependency.where('count > 1').includes(:project)
    @packages = []
  end

  def packages
    # Cache packages list for 2 hours
    @projects = if Rails.cache.respond_to?(:fetch)
      Rails.cache.fetch('packages_projects_list', expires_in: 2.hours) do
        Project.all.select{|p| p.packages.present? }.sort_by{|p| p.packages.sum{|p| p['downloads'] || 0 } }.reverse
      end
    else
      Project.all.select{|p| p.packages.present? }.sort_by{|p| p.packages.sum{|p| p['downloads'] || 0 } }.reverse
    end
  end

end