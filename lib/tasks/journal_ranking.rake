namespace :journals do
  desc "Review cached journal associations without requests or writes (OUTPUT=path, SOURCE=optional, LIMIT=50, AFTER=record ID)"
  task audit: :environment do
    report = JournalAssociationReview.new.call(source: ENV["SOURCE"].presence,
      after: ENV["AFTER"].present? ? Integer(ENV["AFTER"], 10) : nil, limit: Integer(ENV.fetch("LIMIT", "50"), 10))
    File.write(ENV.fetch("OUTPUT"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report.fetch("summary"))
  end

  desc "Rank primary publication sources from normalized paper associations (OUTPUT=path, LIMIT=100)"
  task rank: :environment do
    report = JournalRankingReport.new.call(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    File.write(ENV.fetch("OUTPUT"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report.fetch("summary"))
  end
end
