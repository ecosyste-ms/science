namespace :packages do
  desc "Extract paper candidates from collected package files (FILE=collection.json OUTPUT=candidates.json)"
  task extract_paper_candidates: :environment do
    input_path = ENV.fetch("FILE")
    output_path = ENV.fetch("OUTPUT")
    raise ArgumentError, "Input and output must be different files" if File.expand_path(input_path) == File.expand_path(output_path)
    input = File.read(input_path, 25.megabytes + 1)
    raise ArgumentError, "Collection report must be at most 25 MB" if input.bytesize > 25.megabytes

    report = PackageCitationCandidates.new.call(JSON.parse(input))
    File.write(output_path, JSON.pretty_generate(report) + "\n")
    puts "Package citation candidates: #{report.fetch('summary').inspect}"
  end

  desc "Scan model Projects from pinned Hugging Face PURLs (FILE=JSON array, optional OUTPUT=report.json; maximum 25)"
  task collect_huggingface: :environment do
    input_path = ENV.fetch("FILE")
    output_path = ENV["OUTPUT"].presence
    if output_path && File.expand_path(input_path) == File.expand_path(output_path)
      raise ArgumentError, "Input and output must be different files"
    end
    input = File.read(input_path, 1.megabyte + 1)
    raise ArgumentError, "Input file must be at most 1 MB" if input.bytesize > 1.megabyte

    report = HuggingFacePackageScanner.collect(JSON.parse(input))
    if output_path
      File.write(output_path, JSON.pretty_generate(report) + "\n")
      puts "Model project scans: #{report.fetch('counts').inspect}"
    else
      puts JSON.pretty_generate(report)
    end
  end

  desc "Import explicit Hugging Face PURLs (FILE=JSON array, DRY_RUN=true; maximum 500)"
  task import_huggingface: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true")
    raise ArgumentError, "DRY_RUN must be true or false" unless %w[true false].include?(dry_run)
    input = File.read(ENV.fetch("FILE"), 1.megabyte + 1)
    raise ArgumentError, "Input file must be at most 1 MB" if input.bytesize > 1.megabyte
    report = HuggingFacePackageImport.new(
      purls: JSON.parse(input), dry_run: dry_run == "true"
    ).call
    puts JSON.pretty_generate(report)
  end

  desc "Import reviewed package-project relationships from JSON (FILE=path; purl, repository_url, role, evidence)"
  task import_project_pairs: :environment do
    rows = JSON.parse(File.read(ENV.fetch("FILE")))
    puts "Package-project relationships: #{PackageProject.import_verified!(rows).inspect}"
  end

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
