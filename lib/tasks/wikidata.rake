namespace :wikidata do
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
