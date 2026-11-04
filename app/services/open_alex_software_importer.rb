class OpenAlexSoftwareImporter < ExternalSoftwareImporter
  SOURCE = "openalex"
  HYDRATION_BATCH_SIZE = 25

  def sync_page(works, started_at:)
    works.each do |work|
      id = OpenAlexSoftwareClient.identifier(work.fetch("id"))
      record = record_for(id, started_at)
      record.with_lock do
        next if record.attempted_at && record.attempted_at >= started_at
        next if record.metadata["openalex"] == work && record.retrieved_at
        record.update!(metadata: record.metadata.merge("openalex" => work), status: "pending",
          attempted_at: started_at, next_refresh_at: Time.current, next_discovery_at: nil, last_error: nil,
          collection_url: "#{OpenAlexApiClient::BASE_URL}/works/#{id}")
      end
    end
  end

  def sync(ids)
    ids = OpenAlexSoftwareClient.validate_ids!(ids)
    raise ArgumentError, "hydrate at most 25 works" if ids.size > HYDRATION_BATCH_SIZE
    failures = []
    ids.each do |id|
      record = ExternalSoftwareRecord.find_by(source: SOURCE, identifier: id)
      next unless record && record.next_refresh_at <= Time.current
      started_at = Time.current
      begin
        work = record.status == "pending" ? record.metadata.fetch("openalex") : OpenAlexSoftwareClient.new.record(id)
        entity = { "openalex" => work }
        if work["type"] == "software" && work["doi"].present?
          entity["software_doi"] = SoftwareDoiClient.new.record(SoftwareDoiClient.identifier(work["doi"]))
        end
        persist(id, entity, repository_matches([entity]), started_at,
          collection_url: "#{OpenAlexApiClient::BASE_URL}/works/#{id}")
      rescue SoftwareDoiClient::Error, OpenAlexApiClient::RequestError, ArgumentError => error
        if error.is_a?(OpenAlexApiClient::RequestError) && error.status == 404
          persist(id, { "missing" => true }, {}, started_at)
          next
        end
        retry_at = error.respond_to?(:retry_at) && error.retry_at ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise if error.is_a?(SoftwareDoiClient::RateLimited) || (error.respond_to?(:status) && error.status == 429)
        failures << error
      end
    end
    raise failures.first if failures.any?
  end

  def repository_statements(entity)
    work = entity["openalex"]
    return [] unless work.is_a?(Hash) && work["type"] == "software"
    doi = entity["software_doi"]
    return [] if doi && doi["missing"] && doi["doi"].to_s.start_with?("10.5281/zenodo.")
    available_doi = doi && !doi["missing"]
    return [] if available_doi && !SoftwareDoiImporter.new.software?(doi)
    entries = available_doi ? SoftwareDoiImporter.new.repository_statements(doi) : []
    locations = Array(work["locations"]).each_with_index.map { |location, index| [location, "openalex.locations[#{index}]"] }
    locations << [work["primary_location"], "openalex.primary_location"] if work["primary_location"]
    locations.uniq(&:first).each do |location, path|
      next unless location.is_a?(Hash)
      url = location["landing_page_url"]
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      normalized = RepositoryUrlNormalizer.normalize(url)
      next unless uri && uri.userinfo.nil? && %w[http https].include?(uri.scheme) && [80, 443].include?(uri.port)
      next unless normalized && repository_url?(normalized)
      entries << { repository_url: url, source_field: "#{path}.landing_page_url" }
    end
    entries.map { |entry| entry.merge(openalex_work_id: work.fetch("id"),
      source_record_url: work.fetch("id"), collection_url: entry[:collection_url] || "#{OpenAlexApiClient::BASE_URL}/works") }.uniq
  end

  def relationship_for(entity)
    "repository_candidate"
  end
end
