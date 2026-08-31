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

  desc "Sync package metadata from packages.ecosyste.ms (LIMIT=100 RETRY_STOPPED=false)"
  task sync_metadata: :environment do
    retry_stopped = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch("RETRY_STOPPED", "false")
    )
    result = PackageMetadataSync.sync_batch!(
      limit: ENV.fetch("LIMIT", PackageMetadataSync::DEFAULT_LIMIT),
      retry_stopped: retry_stopped
    )
    puts "Package metadata: #{result.inspect}"
  end

  desc "Match package repository URLs to projects (LIMIT=500)"
  task match_projects: :environment do
    result = PackagePublicationMatcher.match_batch!(
      limit: ENV.fetch("LIMIT", PackagePublicationMatcher::DEFAULT_LIMIT)
    )
    puts "Package project matching: #{result.inspect}"
  end

  desc "Refresh stale zero-score package projects (LIMIT=25, maximum 25)"
  task refresh_projects: :environment do
    enqueued = PackageProjectRefreshEnqueuer.new(
      limit: ENV.fetch("LIMIT", PackageProjectRefreshEnqueuer::DEFAULT_LIMIT)
    ).enqueue
    puts "Enqueued #{enqueued} package project refresh jobs"
  rescue ArgumentError => error
    abort error.message
  end

  desc "Normalize cached package ranking metadata (LIMIT=1000)"
  task normalize_rankings: :environment do
    result = PackageRankingMetadataNormalizer.normalize_batch!(
      limit: ENV.fetch(
        "LIMIT",
        PackageRankingMetadataNormalizer::DEFAULT_LIMIT
      )
    )
    puts "Package ranking normalization: #{result.inspect}"
  end

  desc "Review Science Score inputs for current package candidates"
  task science_score_review: :environment do
    purls = ENV["PURLS"]&.split(",")
    report = PackageScienceScoreReviewReport.new(
      purls: purls,
      limit: ENV.fetch("LIMIT", PackageScienceScoreReviewReport::DEFAULT_LIMIT),
      max_score: ENV.fetch(
        "MAX_SCORE",
        PackageScienceScoreReviewReport::DEFAULT_MAX_SCORE
      )
    )
    puts JSON.pretty_generate(report.generate)
  end
end
