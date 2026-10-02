class RridImporter < ExternalSoftwareImporter
  SOURCE = "rrid"

  def sync(ids)
    ids = RridClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :next_refresh_at).to_h
    records = []
    ids.each do |id|
      next if cached[id] && cached[id] > started_at
      begin
        records << RridClient.new.record(id)
      rescue RridClient::Error => error
        retry_at = error.is_a?(RridClient::RateLimited) ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise
      end
    end
  ensure
    sync_page(records, started_at: started_at) if records&.any?
  end

  def sync_page(records, started_at: Time.current)
    return if records.empty?
    ids = RridClient.validate_ids!(records.map { |record| record.dig("item", "identifier") })
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[RridClient.identifier(record.dig("item", "identifier"))]&.>= started_at }
    matches = repository_matches(records)
    records.each { |record| persist(RridClient.identifier(record.dig("item", "identifier")), record, matches, started_at) }
  end

  def repository_statements(entity)
    return [] unless entity["recordValid"] == true && [true, "true"].include?(entity.dig("rrid", "is_unique"))
    types = Array(entity.dig("item", "types")).map { |type| type["name"].to_s.downcase }
    return [] if (types & ["software resource", "software application", "software toolkit", "software tool", "source code"]).empty?
    %w[current alternate].flat_map do |kind|
      Array(entity.dig("distributions", kind)).filter_map do |entry|
        url = entry["uri"]
        next unless url.is_a?(String) && url.length.between?(1, 2000)
        uri = RepositoryUrlNormalizer.parse(url)
        next unless uri && uri.userinfo.nil? && %w[http https].include?(uri.scheme) && [80, 443].include?(uri.port)
        normalized = RepositoryUrlNormalizer.normalize(url)
        next unless normalized && repository_url?(normalized)
        { repository_url: url, source_field: "distributions.#{kind}",
          source_record_url: "#{RridClient::RESOLVER_URL}/#{RridClient.identifier(entity.dig('item', 'identifier'))}",
          collection_url: "#{RridClient::RESOLVER_URL}/#{RridClient.identifier(entity.dig('item', 'identifier'))}.json" }
      end
    end.uniq
  end
end
