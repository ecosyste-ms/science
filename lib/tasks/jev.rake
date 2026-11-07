namespace :jev do
  desc "Start a bounded shadow discovery run (NAME required, TARGET=10000 BUDGET_USD=1)"
  task start: :environment do
    run = Jev::Run.start!(name: ENV.fetch("NAME"), target: Integer(ENV.fetch("TARGET", "10000")), budget: ENV.fetch("BUDGET_USD", "1"),
      population: ENV.fetch("POPULATION", "discovery"))
    puts JSON.pretty_generate(run.statistics)
  end

  desc "Resume sampling and queue due Jev screening and enrichment jobs"
  task tick: :environment do
    Jev::SchedulerWorker.perform_async if Jev::Settings.enabled?
  end

  desc "Inspect shadow discovery progress and spending (RUN_ID required)"
  task status: :environment do
    puts JSON.pretty_generate(Jev::Run.find(ENV.fetch("RUN_ID")).statistics)
  end

  desc "Retry failed shadow jobs (RUN_ID required)"
  task retry: :environment do
    run = Jev::Run.find(ENV.fetch("RUN_ID"))
    %w[screen enrich].each do |stage|
      run.discoveries.where(status: "failed_#{stage}").update_all(status: "pending_#{stage}", "#{stage}_attempts" => 0,
        next_attempt_at: Time.current, last_error: nil, updated_at: Time.current)
    end
    puts JSON.pretty_generate(run.statistics)
  end

  desc "Recollect missing source evidence (RUN_ID required, LIMIT=100)"
  task retry_evidence: :environment do
    run = Jev::Run.find(ENV.fetch("RUN_ID"))
    limit = Integer(ENV.fetch("LIMIT", "100"))
    raise ArgumentError, "LIMIT must be between 1 and 1000" unless (1..1000).cover?(limit)
    scope = run.discoveries.where(status: "complete").where.not(enrichment_error: nil).order(:id).limit(limit)
    retried = scope.map { |candidate| candidate.retry_evidence!; candidate.id }
    run.update!(status: "running") if run.status == "monitoring" && retried.any?
    puts JSON.pretty_generate(retried: retried, statistics: run.reload.statistics)
  end

  desc "Re-evaluate a run with current model and question content (RUN_ID required)"
  task reevaluate: :environment do
    run = Jev::Run.find(ENV.fetch("RUN_ID"))
    run.reevaluate!
    puts JSON.pretty_generate(run.statistics)
  end

  desc "Find existing repository identities without model calls (RUN_ID required, LIMIT=100, ALL=1 to refresh)"
  task resolve_repositories: :environment do
    run = Jev::Run.find(ENV.fetch("RUN_ID"))
    limit = Integer(ENV.fetch("LIMIT", "100"))
    raise ArgumentError, "LIMIT must be between 1 and 1000" unless (1..1000).cover?(limit)
    scope = run.discoveries.where(status: "complete").where.not(enriched_at: nil)
    scope = scope.where("evidence #> '{repository_identity}' IS NULL") unless ENV["ALL"] == "1"
    resolved = scope.order(:id).limit(limit).map { |candidate| candidate.resolve_repository!; candidate.id }
    puts JSON.pretty_generate(resolved: resolved)
  end

  %w[pause resume].each do |action|
    desc "#{action.capitalize} a discovery run (RUN_ID required)"
    task action => :environment do
      run = Jev::Run.find(ENV.fetch("RUN_ID"))
      run.update!(status: action == "pause" ? "paused" : "running", last_error: nil)
      puts JSON.pretty_generate(run.statistics)
    end
  end
end
