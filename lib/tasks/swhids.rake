namespace :swhids do
  desc "Move existing SWH API jobs to swh_api (DRY_RUN=true by default)"
  task move_api_jobs: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true")
    raise ArgumentError, "DRY_RUN must be true or false" unless %w[true false].include?(dry_run)

    puts JSON.pretty_generate(SwhidApiQueueMigration.new.move(dry_run: dry_run == "true"))
  end

  desc "Report repository coverage and classify archival requests"
  task coverage: :environment do
    puts JSON.pretty_generate(SwhidCoverageReport.counts)
  end

  desc "Queue repository archive checks (LIMIT=100 AFTER_ID=0 REQUESTS_ONLY=false)"
  task check_origins: :environment do
    limit = Integer(ENV.fetch("LIMIT", "100"), 10)
    after_id = Integer(ENV.fetch("AFTER_ID", "0"), 10)
    requests_only = ENV.fetch("REQUESTS_ONLY", "false")
    raise ArgumentError, "LIMIT must be 1..1000, AFTER_ID nonnegative, REQUESTS_ONLY true or false" unless
      limit.between?(1, 1_000) && after_id >= 0 && %w[true false].include?(requests_only)

    scope = Project.visible.scientific.with_repository.where("projects.id > ?", after_id)
    scope = scope.where("swhids->'archival'->>'id' IS NOT NULL") if requests_only == "true"
    ids = scope.order(:id).limit(limit).pluck(:id)
    queued = ids.count { |id| CheckSwhidOriginWorker.perform_async(id) }
    puts JSON.pretty_generate(selected: ids.size, queued: queued, last_project_id: ids.last || after_id)
  end

  desc "Count distinct SWHIDs archived after this app requested archival"
  task contributions: :environment do
    counts = SwhidArchiver.contribution_counts
    puts "SWHIDs archived after our request: #{counts.fetch('total')}"
    puts "Revisions: #{counts.fetch('revisions')}"
    puts "Directories: #{counts.fetch('directories')}"
  end
end
