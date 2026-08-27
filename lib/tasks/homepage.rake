namespace :homepage do
  desc 'refresh cached homepage stats'
  task refresh: :environment do
    stats = Project.stats_summary
    raise "Failed to cache homepage stats" unless Rails.cache.write('homepage_stats', stats)

    puts "Cached homepage stats for #{stats.fetch(:total_projects)} projects"
  end
end
