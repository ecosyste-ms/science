class WikidataImporter
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

  def repository_matches(entities)
    urls = entities.flat_map { |entity| repository_statements(entity).pluck(:repository_url) }.uniq
    urls.each_slice(100).flat_map { |batch| ProjectRepositoryLookup.call(batch) }.index_by { |entry| entry[:input_url] }
  end

  def links_for(entity, matches)
    links = Hash.new { |hash, key| hash[key] = [] }
    repository_statements(entity).each do |statement|
      lookup = matches.fetch(statement[:repository_url])
      ambiguous = lookup[:matches].map { |match| match[:project].fetch("id") }.uniq.size > 1
      lookup[:matches].each do |match|
        links[match[:project].fetch("id")] << statement.merge(
          normalized_url: lookup[:normalized_url], match_method: match[:source], ambiguous: ambiguous)
      end
    end
    links.transform_values(&:uniq)
  end

  def record_for(id, started_at)
    existing = ExternalSoftwareRecord.where(source: "wikidata", identifier: id).select(:id).first
    return existing if existing

    ExternalSoftwareRecord.create_or_find_by!(source: "wikidata", identifier: id) do |record|
      record.next_refresh_at = started_at
    end
  end

  def persist(id, entity, matches, started_at)
    record = record_for(id, started_at)
    record.with_lock do
      next if record.attempted_at && record.attempted_at > started_at
      if entity.key?("missing")
        record.update!(status: "missing", attempted_at: started_at, last_error: nil, next_refresh_at: 7.days.from_now)
        next
      end

      links = links_for(entity, matches)
      existing = record.project_external_software_records.index_by(&:project_id)
      rows = []
      links.each do |project_id, evidence|
        link = existing.delete(project_id) || ProjectExternalSoftwareRecord.new(project_id: project_id, external_software_record_id: record.id)
        link.assign_attributes(relationship: "source_code_repository",
          match_status: evidence.any? { |item| item[:ambiguous] } ? "ambiguous" : "matched", evidence: evidence)
        next unless link.changed?
        rows << link.attributes.slice("project_id", "external_software_record_id", "relationship", "match_status", "evidence")
          .merge("created_at" => link.created_at || Time.current, "updated_at" => Time.current)
      end
      QueryBatch.each(rows) do |batch|
        ProjectExternalSoftwareRecord.upsert_all(batch, unique_by: :index_project_external_records_on_record_and_project,
          update_only: %w[relationship match_status evidence updated_at], record_timestamps: false)
      end
      QueryBatch.each(existing.values.map(&:id), arguments_per_row: 1, fixed_arguments: 1) do |ids|
        record.project_external_software_records.where(id: ids).delete_all
      end
      record.update!(metadata: entity, status: "ok", retrieved_at: started_at, attempted_at: started_at,
        last_error: nil, next_refresh_at: 30.days.from_now)
    end
  end

  def record_failure(id, error, started_at, retry_at)
    record = record_for(id, started_at)
    record.with_lock do
      next if record.attempted_at && record.attempted_at > started_at
      record.update!(status: "error", attempted_at: started_at, last_error: error.message, next_refresh_at: retry_at)
    end
  end
end
