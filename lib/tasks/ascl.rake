namespace :ascl do
  desc "Repeat an enabled ASCL catalogue sweep, preserving unfinished progress"
  task resweep: :environment do
    record = ExternalSoftwareImport.resweep("ascl")
    puts JSON.generate(queued: record.present?)
  end

  desc "Start or resume an ASCL sweep (LIMIT=50, RESTART=true for a completed sweep)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_ascl(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover a due unfinished ASCL sweep"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_ascl
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show ASCL sweep progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "ascl")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue specified ASCL records (IDS=1609.011,1010.083)"
  task import: :environment do
    ids = AsclClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncAsclWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due ASCL records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.ascl_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(AsclClient::PAGE_SIZE) { |batch| SyncAsclWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
