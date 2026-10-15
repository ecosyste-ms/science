class JorsImporter < JournalSoftwareImporter
  SOURCE = "jors"
  CLIENT = JorsClient

  def sync(ids)
    ids = JorsClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :next_refresh_at).to_h
    due = ids.reject { |id| cached[id] && cached[id] > started_at }
    return if due.empty?
    page = JorsClient.new.records(due)
    sync_page(page[:records], started_at: page[:retrieved_at])
  rescue JournalHttpClient::Error => error
    retry_at = error.is_a?(JournalHttpClient::RateLimited) ? error.retry_at : 1.hour.from_now
    due.each { |id| record_failure(id, error, started_at, retry_at) }
    raise
  end

  def sync_page(records, started_at:)
    matches = repository_matches(records)
    records.each do |record|
      id = JorsClient.identifier(record.fetch("id"))
      persist(id, record, matches, started_at, collection_url: JorsClient::CATALOGUE_URL)
    end
  end

  def repository_statements(entity)
    return [] unless entity["eligible"]
    super.map { |statement| statement.merge(source_field: "software_location", collection_url: JorsClient::CATALOGUE_URL,
      xml_url: entity.fetch("xml_url")) }
  end
end
