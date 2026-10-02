namespace :biotools do
  desc "Start or resume a bio.tools sweep (optional: LIMIT=50 RESTART=true)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_biotools(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover a due unfinished bio.tools sweep"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_biotools
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show saved bio.tools sweep progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "biotools")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue specific bio.tools records (IDS=scanpy,multiqc)"
  task import: :environment do
    ids = BiotoolsClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncBiotoolsWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due bio.tools records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.biotools_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(BiotoolsClient::PAGE_SIZE) { |batch| SyncBiotoolsWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
