namespace :science_cohort do
  desc "Export project and dependency cohorts from one read-only snapshot (OUTPUT=path)"
  task export: :environment do
    result = ScienceCohortExport.new(
      output: ENV["OUTPUT"], batch_size: ENV.fetch("BATCH_SIZE", "250"),
      progress: ->(counts) { warn "Exported #{counts[:projects]} projects and #{counts[:packages]} packages" }
    ).export
    puts JSON.pretty_generate(result)
  end
end
