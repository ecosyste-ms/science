namespace :journals do
  desc "Queue due OpenAlex enrichment for journal papers (LIMIT=5, maximum 25)"
  task enrich: :environment do
    puts JSON.generate(JournalPaperEnrichment.enqueue(limit: ENV.fetch("LIMIT", JournalPaperEnrichment::DEFAULT_LIMIT)))
  end

  desc "Show journal paper OpenAlex enrichment status"
  task enrichment_status: :environment do
    puts JSON.generate(statuses: JournalPaperEnrichment.group(:status).count,
      due: JournalPaperEnrichment.due.count, cooldown_until: JournalPaperEnrichment.cooldown_until,
      untracked: PaperIdentifier.where(source: JournalPaperEnrichment::SOURCES)
        .where.not(paper_id: JournalPaperEnrichment.select(:paper_id)).distinct.count(:paper_id))
  end
end

%w[mloss jors jss].each do |source|
  namespace source do
    desc "Start or repeat the #{source.upcase} harvest, preserving unfinished progress"
    task harvest: :environment do
      record = ExternalSoftwareImport.harvest_journal(source)
      puts JSON.generate(record.progress)
    end
  end
end

%w[jors jss].each do |source|
  namespace source do
    desc "Start or resume a #{source.upcase} sweep (LIMIT=5, RESTART=true for completed sweeps)"
    task sweep: :environment do
      options = { page_size: ENV["LIMIT"].present? ? Integer(ENV["LIMIT"], 10) : nil, restart: ENV["RESTART"] == "true" }
      record = if source == "jss"
        ExternalSoftwareImport.start_jss(**options, from: ENV["FROM"].presence, until_time: ENV["UNTIL"].presence)
      else
        ExternalSoftwareImport.start_catalogue(source: source, **options)
      end
      record.enqueue
      puts JSON.generate(record.progress)
    end

    desc "Show #{source.upcase} sweep progress"
    task status: :environment do
      record = ExternalSoftwareImport.find_by(source: source)
      puts JSON.generate(record ? record.progress : { status: "not_started" })
    end

    desc "Resume a due unfinished #{source.upcase} sweep"
    task resume: :environment do
      record = ExternalSoftwareImport.where(source: source, completed_at: nil).where("next_run_at <= ?", Time.current)
        .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current).first
      record&.enqueue
      puts JSON.generate(queued: record.present?)
    end

    desc "Queue specified #{source.upcase} articles (IDS=comma-separated DOIs)"
    task import: :environment do
      ids = ImportJournalWorker::CLIENTS.fetch(source).validate_ids!(ENV.fetch("IDS", "").split(","))
      SyncJournalWorker.perform_async(source, ids)
      puts JSON.generate(queued: ids.size)
    end

    desc "Queue due #{source.upcase} articles (LIMIT=100, maximum 1000)"
    task refresh: :environment do
      limit = Integer(ENV.fetch("LIMIT", "100"), 10)
      raise ArgumentError, "limit must be between 1 and 1000" unless limit.between?(1, 1000)
      ids = ExternalSoftwareRecord.where(source: source).where("next_refresh_at <= ?", Time.current)
        .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
      ids.each_slice(ImportJournalWorker::CLIENTS.fetch(source)::PAGE_SIZE) { |batch| SyncJournalWorker.perform_async(source, batch) }
      puts JSON.generate(queued: ids.size)
    end
  end
end
