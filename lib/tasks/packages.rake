namespace :packages do
  desc "Sync package registries from packages.ecosyste.ms"
  task sync_registries: :environment do
    result = PackageRegistry.sync_from_ecosystems!
    puts "Package registries: #{result.inspect}"
  end

  desc "Resolve project dependencies to packages (LIMIT=1000 RETRY_ERRORS=false)"
  task resolve_dependencies: :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch("RETRY_ERRORS", "false")
    )
    result = ProjectDependencyResolver.resolve_batch!(
      limit: ENV.fetch("LIMIT", ProjectDependencyResolver::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Package resolution: #{result.inspect}"
  end
end
