class MlossImporter < JournalSoftwareImporter
  SOURCE = "mloss"
  CLIENT = MlossClient

  def sync(ids)
    ids = MlossClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :next_refresh_at).to_h
    due = ids.reject { |id| cached[id] && cached[id] > started_at }
    return if due.empty?
    page = MlossClient.new.records(due)
    sync_page(page[:records], started_at: page[:retrieved_at])
  rescue MlossClient::Error => error
    retry_at = error.is_a?(MlossClient::RateLimited) ? error.retry_at : 1.hour.from_now
    due.each { |id| record_failure(id, error, started_at, retry_at) }
    raise
  end

  def sync_page(records, started_at:)
    return if records.empty?
    ids = MlossClient.validate_ids!(records.pluck("id"))
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[record["id"]]&.>= started_at }
    matches = repository_matches(records)
    records.each { |record| persist(record.fetch("id"), record, matches, started_at, collection_url: MlossClient::CATALOGUE_URL) }
  end

end
