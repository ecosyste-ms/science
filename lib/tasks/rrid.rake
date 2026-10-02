namespace :rrid do
  desc "Start or resume the SciCrunch software catalogue (LIMIT=50, RESTART=true)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_rrid(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Show SciCrunch catalogue progress"
  task sweep_status: :environment do
    record = ExternalSoftwareImport.find_by(source: "rrid")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Start or resume seeding RRIDs from cached bio.tools records (LIMIT=50, RESTART=true)"
  task seed: :environment do
    record = ExternalSoftwareImport.start_rrid_seeds(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover due unfinished RRID seed and catalogue imports"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_rrid_seeds
    record&.enqueue
    catalogue = ExternalSoftwareImport.resumable_rrid
    catalogue&.enqueue
    puts JSON.generate(queued: record.present? || catalogue.present?)
  end

  desc "Repeat a previously enabled RRID seed pass"
  task rescan: :environment do
    record = ExternalSoftwareImport.find_by(source: "rrid_seeds")
    record = ExternalSoftwareImport.start_rrid_seeds(restart: true) if record&.completed_at
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show RRID seed progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "rrid_seeds")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue known software RRIDs (IDS=SCR_015687,SCR_026162)"
  task import: :environment do
    ids = RridClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncRridWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due RRID records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.rrid_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(RridClient::PAGE_SIZE) { |batch| SyncRridWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
