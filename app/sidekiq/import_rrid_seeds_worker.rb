class ImportRridSeedsWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3

  def perform(import_id)
    import = ExternalSoftwareImport.find_by(id: import_id, source: "rrid_seeds")
    return unless import
    token = import.claim
    return unless token
    unless import.page_retrieved_at
      records = RridSeeds.page(after: import.cursor, limit: import.page_size)
      next_cursor = records.last.fetch("biotoolsID") if records.size == import.page_size
      return unless import.save_catalogue_page(token, records, next_cursor, Time.current)
    end
    time = nil
    import.with_lock do
      return unless import.lease_token == token
      RridSeeds.persist(import.pending_records)
      time = import.advance_catalogue(token)
    end
    self.class.perform_at(time, import.id) if time
  rescue StandardError => error
    import.defer(token, 5.minutes.from_now, "#{error.class}: #{error.message}") if token
    raise
  end
end
