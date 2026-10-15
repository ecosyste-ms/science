namespace :rjournal do
  desc "Review subject packages from a checkout's origin/published ref (REPOSITORY=path, OUTPUT=path, LIMIT=20, SLUGS=optional list, AFTER=slug)"
  task review: :environment do
    report = RJournalPackageReview.new.call(repository: ENV.fetch("REPOSITORY"),
      slugs: ENV["SLUGS"].presence&.split(","), limit: Integer(ENV.fetch("LIMIT", "20"), 10), after: ENV["AFTER"].presence)
    File.write(ENV.fetch("OUTPUT"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report.fetch("summary"))
  end
end
