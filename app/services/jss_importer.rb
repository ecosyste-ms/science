class JssImporter < JournalSoftwareImporter
  SOURCE = "jss"
  CLIENT = JssClient

  def sync(ids)
    ids = CLIENT.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :next_refresh_at).to_h
    due = ids.reject { |id| cached[id] && cached[id] > started_at }
    return if due.empty?
    page = CLIENT.new.records(due)
    sync_page(page[:records], started_at: page[:retrieved_at])
  rescue JournalHttpClient::Error => error
    retry_at = error.is_a?(JournalHttpClient::RateLimited) ? error.retry_at : 1.hour.from_now
    due.each { |id| record_failure(id, error, started_at, retry_at) }
    raise
  end

  def sync_page(records, started_at:)
    matches = repository_matches(records)
    records.each do |entity|
      id = CLIENT.identifier(entity.fetch("id"))
      if entity["deleted"]
        remove_publication(id, entity, started_at)
      else
        persist(id, entity, matches, started_at, collection_url: CLIENT::CATALOGUE_URL)
      end
    end
  end

  def remove_publication(id, entity, started_at)
    record = record_for(id, started_at)
    record.with_lock do
      return if record.attempted_at && record.attempted_at > started_at
      metadata = record.metadata.merge(entity).merge("eligible" => false, "code_urls" => [])
      record.project_external_software_records.delete_all
      JournalPublicationIndexer.new.sync!(record, metadata) if metadata["article_url"]
      record.update!(metadata: metadata, status: "missing", retrieved_at: started_at, attempted_at: started_at,
        last_error: nil, next_refresh_at: 30.days.from_now, next_discovery_at: nil, collection_url: CLIENT::CATALOGUE_URL)
    end
  end

  def repository_statements(entity)
    return [] unless entity["eligible"] && !entity["deleted"]
    super.map do |statement|
      packages = entity.fetch("subject_packages", []).select { |package| Array(package["urls"]).include?(statement[:repository_url]) }
      statement.merge(source_field: "package_metadata", subject_packages: packages)
    end
  end
end
