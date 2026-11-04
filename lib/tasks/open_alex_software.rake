namespace :open_alex do
  namespace :software do
    desc "Start software discovery or repeat a completed OpenAlex sweep"
    task harvest: :environment do
      record = ExternalSoftwareImport.harvest_open_alex
      puts JSON.generate(queued: record.present?)
    end

    desc "Start or resume software discovery (LIMIT=100 FROM=YYYY-MM-DD UNTIL=YYYY-MM-DD RESTART=true)"
    task sweep: :environment do
      record = ExternalSoftwareImport.start_open_alex(
        from: ENV["FROM"], until_time: ENV["UNTIL"],
        page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true")
      record.enqueue
      puts JSON.generate(record.progress)
    end

    desc "Recover an unfinished OpenAlex software sweep"
    task resume: :environment do
      record = ExternalSoftwareImport.resumable_open_alex
      record&.enqueue
      puts JSON.generate(queued: record.present?)
    end

    desc "Queue due OpenAlex source metadata hydration (LIMIT=100, maximum 1000)"
    task refresh: :environment do
      limit = Integer(ENV.fetch("LIMIT", "100"), 10)
      raise ArgumentError, "limit must be between 1 and 1000" unless limit.between?(1, 1000)
      ids = ExternalSoftwareRecord.where(source: "openalex").where("next_refresh_at <= ?", Time.current)
        .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
      ids.each_slice(OpenAlexSoftwareImporter::HYDRATION_BATCH_SIZE) { |batch| SyncOpenAlexSoftwareWorker.perform_async(batch) }
      puts JSON.generate(queued: ids.size)
    end

    desc "Show OpenAlex software sweep and hydration progress"
    task status: :environment do
      record = ExternalSoftwareImport.find_by(source: "openalex")
      puts JSON.generate(import: record ? record.progress : { status: "not_started" },
        records: ExternalSoftwareRecord.where(source: "openalex").group(:status).count)
    end
  end
end
