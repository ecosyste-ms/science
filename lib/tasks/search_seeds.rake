namespace :search_seeds do
  desc "Export software search seeds to SQLite (optional: OUTPUT=path LIMIT=n)"
  task export: :environment do
    export = SearchSeedExport.new(
      output: ENV["OUTPUT"],
      limit: ENV["LIMIT"],
      progress: ->(message) { warn message }
    )
    puts JSON.pretty_generate(export.export)
  end
end
