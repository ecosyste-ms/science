namespace :mloss do
  desc "Repeat an enabled MLOSS catalogue sweep, preserving unfinished progress"
  task resweep: :environment do
    record = ExternalSoftwareImport.resweep("mloss")
    puts JSON.generate(queued: record.present?)
  end

  desc "Start or resume an MLOSS sweep (LIMIT=50, RESTART=true for a completed sweep)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_mloss(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover a due unfinished MLOSS sweep"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_mloss
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show MLOSS sweep progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "mloss")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Inspect unresolved cached MLOSS code links (LIMIT=50, AFTER=article identifier)"
  task unresolved: :environment do
    limit = Integer(ENV.fetch("LIMIT", "50"), 10)
    raise ArgumentError, "limit must be between 1 and 50" unless limit.between?(1, 50)
    after = MlossClient.identifier(ENV["AFTER"]) if ENV["AFTER"].present?
    scope = ExternalSoftwareRecord.where(source: "mloss").order(:identifier)
    scope = scope.where("identifier > ?", after) if after
    records = scope.select(:source, :identifier, :metadata).limit(limit + 1).to_a
    importer = MlossImporter.new
    unresolved = records.first(limit).filter_map do |record|
      urls = Array(record.metadata["code_urls"]) - importer.repository_statements(record.metadata).pluck(:repository_url)
      { identifier: record.identifier, article_url: record.record_url, code_urls: urls } if urls.any?
    end
    puts JSON.generate(records: unresolved, next_after: records.size > limit ? records[limit - 1].identifier : nil)
  end

  desc "Queue specified MLOSS records (IDS=v27/26-0434,v9/fan08a)"
  task import: :environment do
    ids = MlossClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncMlossWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due MLOSS records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.mloss_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(MlossClient::PAGE_SIZE) { |batch| SyncMlossWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
