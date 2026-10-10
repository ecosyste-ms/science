namespace :wikidata do
  desc "Repeat an enabled Wikidata catalogue sweep, preserving unfinished progress"
  task resweep: :environment do
    record = ExternalSoftwareImport.resweep("wikidata")
    puts JSON.generate(queued: record.present?)
  end

  desc "Start or resume a background Wikidata sweep (optional: AFTER=QID LIMIT=100 RESTART=true)"
  task sweep: :environment do
    record = ExternalSoftwareImport.start_wikidata(after: ENV["AFTER"].presence,
      page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
    record.enqueue
    puts JSON.generate(record.progress)
  end

  desc "Resume an unfinished Wikidata sweep if its next page is due"
  task resume: :environment do
    record = ExternalSoftwareImport.resumable_wikidata
    record&.enqueue
    puts JSON.generate(queued: record.present?)
  end

  desc "Show saved Wikidata sweep progress"
  task status: :environment do
    record = ExternalSoftwareImport.find_by(source: "wikidata")
    puts JSON.generate(record ? record.progress : { status: "not_started" })
  end

  desc "Queue one page of repository-linked Wikidata items (LIMIT=100 AFTER=QID), or IDS=QID,QID"
  task import: :environment do
    if ENV["IDS"].present?
      ids = ENV.fetch("IDS").split(",").uniq
      WikidataClient.validate_ids!(ids)
      SyncWikidataWorker.perform_async(ids)
      puts JSON.generate(queued: ids.size)
    else
      puts JSON.generate(WikidataImporter.queue_page(after: ENV["AFTER"].presence, limit: Integer(ENV.fetch("LIMIT", "100"), 10)))
    end
  end

  desc "Queue due Wikidata records (LIMIT=100, maximum 1000)"
  task refresh: :environment do
    ids = ExternalSoftwareRecord.wikidata_refresh_ids(limit: Integer(ENV.fetch("LIMIT", "100"), 10))
    ids.each_slice(WikidataClient::BATCH_SIZE) { |batch| SyncWikidataWorker.perform_async(batch) }
    puts JSON.generate(queued: ids.size)
  end
end
