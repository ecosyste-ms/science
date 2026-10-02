class BiotoolsImporter < ExternalSoftwareImporter
  SOURCE = "biotools"

  def sync(ids)
    ids = BiotoolsClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :next_refresh_at).to_h
    records = []
    ids.each do |id|
      next if cached[id] && cached[id] > started_at
      begin
        records << BiotoolsClient.new.record(id)
      rescue BiotoolsClient::Error => error
        retry_at = error.is_a?(BiotoolsClient::RateLimited) ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise
      end
    end
  ensure
    sync_page(records, started_at: started_at) if records&.any?
  end

  def sync_page(records, started_at: Time.current)
    return if records.empty?
    ids = BiotoolsClient.validate_ids!(records.map { |record| record["biotoolsID"] })
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[BiotoolsClient.identifier(record["biotoolsID"])]&.>= started_at }
    matches = repository_matches(records)
    records.each { |record| persist(BiotoolsClient.identifier(record["biotoolsID"]), record, matches, started_at) }
  end

  def repository_statements(entity)
    Array(entity["link"]).filter_map do |link|
      next unless link.is_a?(Hash) && Array(link["type"]).include?("Repository")
      url = link["url"]
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      next unless uri && uri.userinfo.nil? && RepositoryUrlNormalizer.normalize(url)
      { repository_url: url, source_field: "link", source_type: "Repository" }
    end.uniq
  end
end
