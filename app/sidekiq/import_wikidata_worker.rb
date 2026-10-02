class ImportWikidataWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3

  sidekiq_retry_in { 5.minutes.to_i + rand(1..30) }

  def perform(import_id)
    import = ExternalSoftwareImport.find_by(id: import_id, source: "wikidata")
    return unless import
    token = import.claim
    return unless token

    if import.pending_ids.empty?
      ids = WikidataClient.new.repository_ids(after: import.cursor, limit: import.page_size)
      return unless import.save_page(token, ids)
    end
    import.pending_ids.each_slice(WikidataClient::BATCH_SIZE) { |ids| WikidataImporter.new.sync(ids) }
    records = ExternalSoftwareRecord.where(source: "wikidata", identifier: import.pending_ids)
      .pluck(:identifier, :status, :next_refresh_at)
    if records.size != import.pending_ids.size || records.any? { |_, status, _| !%w[ok missing].include?(status) }
      retry_at = records.filter_map { |_, status, date| date unless %w[ok missing].include?(status) }.max || 1.hour.from_now
      schedule(import, import.defer(token, retry_at, "Source records awaiting retry"))
    else
      schedule(import, import.advance(token))
    end
  rescue WikidataClient::RateLimited => error
    schedule(import, import.defer(token, error.retry_at, error.message))
  rescue WikidataClient::Error => error
    schedule(import, import.defer(token, 1.hour.from_now, error.message))
  rescue StandardError => error
    import.defer(token, 5.minutes.from_now, "#{error.class}: #{error.message}") if token
    raise
  end

  def schedule(import, time)
    self.class.perform_at(time, import.id) if time
  end
end
