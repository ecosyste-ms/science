class RridImporter < ExternalSoftwareImporter
  SOURCE = "rrid"

  def initialize(collection_url: nil)
    @collection_url = collection_url
  end

  def collection_url(entity)
    @collection_url || "#{RridClient::RESOLVER_URL}/#{RridClient.identifier(entity.dig('item', 'identifier'))}.json"
  end

  def sync(ids)
    ids = RridClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :next_refresh_at).to_h
    records = []
    aliases = {}
    failures = []
    ids.each do |id|
      next if cached[id] && cached[id] > started_at
      begin
        record = RridClient.new.record(id)
        records << record
        aliases[id] = record if RridClient.identifier(record.dig("item", "identifier")) != id
      rescue RridClient::Error => error
        retry_at = error.is_a?(RridClient::RateLimited) ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise if error.is_a?(RridClient::RateLimited)
        failures << error
      end
    end
    raise failures.first if failures.any?
  ensure
    if records&.any?
      ExternalSoftwareRecord.transaction do
        sync_page(records.uniq { |record| record.dig("item", "identifier") }, started_at: started_at)
        aliases.each { |id, record| persist_alias(id, record, started_at) }
      end
    end
  end

  def persist_alias(id, entity, started_at)
    record = record_for(id, started_at)
    record.with_lock do
      next if record.attempted_at && record.attempted_at > started_at
      record.update!(metadata: entity, status: "ok", retrieved_at: started_at, attempted_at: started_at,
        last_error: nil, next_refresh_at: 30.days.from_now, collection_url: collection_url(entity), next_discovery_at: nil)
      record.project_external_software_records.delete_all
    end
  end

  def sync_page(records, started_at: Time.current)
    return if records.empty?
    ids = RridClient.validate_ids!(records.map { |record| record.dig("item", "identifier") })
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids)
      .pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[RridClient.identifier(record.dig("item", "identifier"))]&.>= started_at }
    matches = repository_matches(records)
    records.each do |record|
      persist(RridClient.identifier(record.dig("item", "identifier")), record, matches, started_at, collection_url: collection_url(record))
    end
  end

  def repository_statements(entity)
    return [] unless entity["recordValid"] == true && [true, "true"].include?(entity.dig("rrid", "is_unique"))
    types = Array(entity.dig("item", "types")).map { |type| type["name"].to_s.downcase }
    return [] if (types & RridClient::SOFTWARE_TYPES).empty?
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
          collection_url: collection_url(entity) }
      end
    end.uniq
  end
end
