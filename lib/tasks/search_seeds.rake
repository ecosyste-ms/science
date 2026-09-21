namespace :search_seeds do
  desc "Index software names and identifiers for API lookup (optional: LIMIT=n AFTER_ID=n)"
  task index: :environment do
    after_id = Integer(ENV.fetch("AFTER_ID", "0"), 10)
    limit = Integer(ENV["LIMIT"], 10) if ENV["LIMIT"].present?
    raise ArgumentError, "AFTER_ID must be nonnegative and LIMIT positive" if after_id.negative? || (limit && limit < 1)

    scope = Project.visible.scientific.select(:id).where("id > ?", after_id)
    scope = scope.limit(limit) if limit
    count = 0
    scope.find_each(batch_size: 250) do |project|
      SoftwareSearchIndexer.index(project.id)
      count += 1
      after_id = project.id
      warn "Indexed #{count} projects; AFTER_ID=#{after_id}" if (count % 250).zero?
    end
    puts JSON.pretty_generate(indexed: count, last_project_id: after_id)
  end

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
