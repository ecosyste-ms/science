class ImportSwmathWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3

  sidekiq_retry_in { 5.minutes.to_i + rand(1..30) }

  def perform(import_id)
    import = ExternalSoftwareImport.find_by(id: import_id, source: "swmath")
    return unless import
    token = import.claim
    return unless token
    unless import.page_retrieved_at
      retrieved_at = Time.current
      page = SwmathClient.new.page(after: import.cursor, limit: import.page_size)
      return unless import.save_catalogue_page(token, page[:records], page[:next_cursor], retrieved_at)
    end
    SwmathImporter.new.sync_page(import.pending_records, started_at: import.page_retrieved_at)
    schedule(import, import.advance_catalogue(token))
  rescue SwmathClient::RateLimited => error
    schedule(import, import.defer(token, error.retry_at, error.message))
  rescue SwmathClient::Error => error
    schedule(import, import.defer(token, 1.hour.from_now, error.message))
  rescue StandardError => error
    import.defer(token, 5.minutes.from_now, "#{error.class}: #{error.message}") if token
    raise
  end

  def schedule(import, time)
    self.class.perform_at(time, import.id) if time
  end
end
