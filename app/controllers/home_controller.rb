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
  end
end
