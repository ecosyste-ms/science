class HomeController < ApplicationController
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
end
