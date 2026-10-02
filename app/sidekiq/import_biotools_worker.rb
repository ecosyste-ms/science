class ImportBiotoolsWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3

  sidekiq_retry_in { 5.minutes.to_i + rand(1..30) }

  def perform(import_id)
    import = ExternalSoftwareImport.find_by(id: import_id, source: "biotools")
    return unless import
    token = import.claim
    return unless token

    unless import.page_retrieved_at
      retrieved_at = Time.current
      page = BiotoolsClient.new.page(number: Integer(import.cursor, 10), limit: import.page_size)
      return unless import.save_biotools_page(token, page[:records], page[:next_page], retrieved_at)
    end
    BiotoolsImporter.new.sync_page(import.pending_records, started_at: import.page_retrieved_at)
    schedule(import, import.advance_biotools(token))
  rescue BiotoolsClient::RateLimited => error
    schedule(import, import.defer(token, error.retry_at, error.message))
  rescue BiotoolsClient::Error => error
    schedule(import, import.defer(token, 1.hour.from_now, error.message))
  rescue StandardError => error
    import.defer(token, 5.minutes.from_now, "#{error.class}: #{error.message}") if token
    raise
  end

  def schedule(import, time)
    self.class.perform_at(time, import.id) if time
  end
end
