class RridSeeds
  def self.page(after: nil, limit: 50)
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, 50)
    records = ExternalSoftwareRecord.where(source: "biotools", status: %w[ok error]).where.not(retrieved_at: nil)
    records = records.where("identifier > ?", after) if after
    records.order(:identifier).limit(limit).pluck(:identifier, Arel.sql("metadata -> 'otherID'")).map do |identifier, other_ids|
      { "biotoolsID" => identifier, "otherID" => other_ids }
    end
  end

  def self.persist(records)
    ids = records.flat_map do |record|
      Array(record["otherID"]).filter_map do |entry|
        next unless entry.is_a?(Hash) && entry["type"].to_s.casecmp?("rrid")
        RridClient.identifier(entry["value"])
      rescue ArgumentError
        nil
      end
    end.uniq
    rows = ids.map { |id| { source: "rrid", identifier: id, status: "pending", next_refresh_at: Time.current } }
    QueryBatch.each(rows) do |batch|
      ExternalSoftwareRecord.insert_all(batch, unique_by: :index_external_software_records_on_source_and_identifier)
    end
  end
end
