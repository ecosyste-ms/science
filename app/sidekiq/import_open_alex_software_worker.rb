class ImportOpenAlexSoftwareWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3

  def perform(import_id)
    import = ExternalSoftwareImport.find_by(id: import_id, source: "openalex")
    return unless import
    token = import.claim
    return unless token
    unless import.page_retrieved_at
      page = OpenAlexSoftwareClient.new.page(after: import.cursor, limit: import.page_size)
      return unless import.save_catalogue_page(token, page[:records], page[:next_cursor], page[:retrieved_at])
    end
    time = nil
    import.with_lock do
      return unless import.lease_token == token
      OpenAlexSoftwareImporter.new.sync_page(import.pending_records, started_at: import.page_retrieved_at)
      time = import.advance_catalogue(token)
    end
    self.class.perform_at(time, import.id) if time
  rescue OpenAlexApiClient::RequestError => error
    if token
      time = import.defer(token, error.retry_at || 1.hour.from_now, error.message)
      unless [400, 401, 403].include?(error.status) || error.message.include?("Plan upgrade required")
        self.class.perform_at(time, import.id) if time
      end
    end
  rescue StandardError => error
    import.defer(token, 5.minutes.from_now, "#{error.class}: #{error.message}") if token
    raise
  end
end
