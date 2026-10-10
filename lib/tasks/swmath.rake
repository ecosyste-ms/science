namespace :swmath do
  desc "Repeat an enabled swMATH catalogue sweep, preserving unfinished progress"
  task resweep: :environment do
    record = ExternalSoftwareImport.resweep("swmath")
    puts JSON.generate(queued: record.present?)
  end

  desc "Start or resume an swMATH sweep (LIMIT=50, RESTART=true for a completed sweep)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_swmath(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover a due unfinished swMATH sweep"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_swmath
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show swMATH sweep progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "swmath")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue specified swMATH records (IDS=6294,825)"
  task import: :environment do
    ids = SwmathClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncSwmathWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due swMATH records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.swmath_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(SwmathClient::PAGE_SIZE) { |batch| SyncSwmathWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
