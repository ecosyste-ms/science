namespace :jev do
  desc "Start a bounded shadow discovery run (NAME required, TARGET=10000 BUDGET_USD=1)"
  task start: :environment do
    run = JevRun.start!(name: ENV.fetch("NAME"), target: Integer(ENV.fetch("TARGET", "10000")), budget: ENV.fetch("BUDGET_USD", "1"))
    puts JSON.pretty_generate(run.statistics)
  end

  desc "Resume sampling and queue due Jev screening and enrichment jobs"
  task tick: :environment do
    JevSchedulerWorker.perform_async if JevSettings.enabled?
  end

  desc "Inspect shadow discovery progress and spending (RUN_ID required)"
  task status: :environment do
    puts JSON.pretty_generate(JevRun.find(ENV.fetch("RUN_ID")).statistics)
  end

  desc "Retry failed shadow jobs (RUN_ID required)"
  task retry: :environment do
    run = JevRun.find(ENV.fetch("RUN_ID"))
    %w[screen enrich].each do |stage|
      run.jev_discoveries.where(status: "failed_#{stage}").update_all(status: "pending_#{stage}", "#{stage}_attempts" => 0,
        next_attempt_at: Time.current, last_error: nil, updated_at: Time.current)
    end
    puts JSON.pretty_generate(run.statistics)
  end

  desc "Re-evaluate a run with current model and question content (RUN_ID required)"
  task reevaluate: :environment do
    run = JevRun.find(ENV.fetch("RUN_ID"))
    run.reevaluate!
    puts JSON.pretty_generate(run.statistics)
  end

  %w[pause resume].each do |action|
    desc "#{action.capitalize} a discovery run (RUN_ID required)"
    task action => :environment do
      run = JevRun.find(ENV.fetch("RUN_ID"))
      run.update!(status: action == "pause" ? "paused" : "running", last_error: nil)
      puts JSON.pretty_generate(run.statistics)
    end
  end
end
