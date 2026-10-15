namespace :journals do
  desc "Rank primary publication sources from normalized paper associations (OUTPUT=path, LIMIT=100)"
  task rank: :environment do
    report = JournalRankingReport.new.call(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    File.write(ENV.fetch("OUTPUT"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report.fetch("summary"))
  end
end
