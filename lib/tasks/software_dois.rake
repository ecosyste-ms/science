namespace :software_dois do
  desc "Start or resume seeding known software DOIs (LIMIT=25, RESTART=true)"
  task seed: :environment do
    record = ExternalSoftwareImport.start_software_doi_seeds(
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Recover a due unfinished software DOI seed pass"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_software_doi_seeds
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Repeat a previously enabled software DOI seed pass"
  task rescan: :environment do
    record = ExternalSoftwareImport.find_by(source: "doi_seeds")
    record = ExternalSoftwareImport.start_software_doi_seeds(restart: true) if record&.completed_at
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show software DOI seed progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "doi_seeds")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue known software DOIs (IDS=10.5281/zenodo.596036)"
  task import: :environment do
    ids = SoftwareDoiClient.validate_ids!(ENV.fetch("IDS", "").split(","))
    SyncSoftwareDoiWorker.perform_async(ids)
    puts JSON.generate(queued: ids.size)
  end

  desc "Queue due software DOI records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.software_doi_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(SoftwareDoiClient::PAGE_SIZE) { |batch| SyncSoftwareDoiWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
