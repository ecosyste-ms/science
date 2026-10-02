class WikidataImporter < ExternalSoftwareImporter
  SOURCE = "wikidata"

  def self.queue_page(after: nil, limit: 100)
    ids = WikidataClient.new.repository_ids(after: after, limit: limit)
    ids.each_slice(WikidataClient::BATCH_SIZE) { |batch| SyncWikidataWorker.perform_async(batch) }
    { queued: ids.size, after: ids.last || after, complete: ids.size < limit }
  end

  def sync(ids)
    WikidataClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: "wikidata", identifier: ids)
      .select(:identifier, :next_refresh_at).index_by(&:identifier)
    due_ids = ids.uniq.reject { |id| cached[id] && cached[id].next_refresh_at > started_at }
    return if due_ids.empty?

    entities = WikidataClient.new.entities(due_ids)
    matches = repository_matches(entities.values)
    due_ids.each { |id| persist(id, entities.fetch(id), matches, started_at) }
  rescue WikidataClient::Error => error
    retry_at = error.is_a?(WikidataClient::RateLimited) ? error.retry_at : 1.hour.from_now
    due_ids.each { |id| record_failure(id, error, started_at, retry_at) }
    raise
  end

  def repository_statements(entity)
    Array(entity.dig("claims", "P1324")).filter_map do |statement|
      next unless statement.is_a?(Hash) && %w[normal preferred].include?(statement["rank"])
      next unless statement.dig("mainsnak", "snaktype") == "value"
      url = statement.dig("mainsnak", "datavalue", "value")
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      next unless uri && uri.userinfo.nil? && RepositoryUrlNormalizer.normalize(url)
      { statement_id: statement["id"], repository_url: url, rank: statement["rank"] }
    end
  end

end
