class SwmathImporter < ExternalSoftwareImporter
  SOURCE = "swmath"

  def sync(ids)
    ids = SwmathClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :next_refresh_at).to_h
    records = []
    ids.each do |id|
      next if cached[id] && cached[id] > started_at
      begin
        records << SwmathClient.new.record(id)
      rescue SwmathClient::Error => error
        retry_at = error.is_a?(SwmathClient::RateLimited) ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise
      end
    end
  ensure
    sync_page(records, started_at: started_at) if records&.any?
  end

  def sync_page(records, started_at: Time.current)
    return if records.empty?
    ids = SwmathClient.validate_ids!(records.map { |record| record["id"].to_s })
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[SwmathClient.identifier(record["id"].to_s)]&.>= started_at }
    matches = repository_matches(records)
    records.each { |record| persist(SwmathClient.identifier(record["id"].to_s), record, matches, started_at) }
  end

  def repository_statements(entity)
    url = entity["source_code"]
    return [] unless url.is_a?(String) && url.length.between?(1, 2000)
    uri = RepositoryUrlNormalizer.parse(url)
    return [] unless uri && uri.userinfo.nil? && RepositoryUrlNormalizer.normalize(url)
    [{ repository_url: url, source_field: "source_code", collection_url: SwmathClient::API_URL,
      source_license: "CC-BY-SA-4.0" }]
  end
end
