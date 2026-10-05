require "digest/sha2"
require "json"
require "open3"
require "tempfile"

class RorResearchOrganizationImporter
  BATCH_SIZE = 1_000
  MINIMUM_RECORDS = 10_000
  RELATIONSHIP_TYPES = %w[parent child related predecessor successor].freeze

  def self.sync!(minimum_records: MINIMUM_RECORDS, max_batches: nil, progress: nil)
    metadata = RorResearchOrganizationDomainImporter.fetch_metadata
    version = metadata.fetch("id").to_s
    previous = ResearchOrganizationImport.find_by(source_version: version)
    return previous.progress if previous&.completed_at

    file = metadata.fetch("files").find { |entry| entry.fetch("key").end_with?(".zip") }
    raise ArgumentError, "ROR release does not contain a ZIP file" unless file

    Tempfile.create(["ror-organizations", ".zip"]) do |archive|
      archive.binmode
      RorResearchOrganizationDomainImporter.download_archive(file.fetch("links").fetch("self"), archive)
      RorResearchOrganizationDomainImporter.verify_checksum!(archive.path, file.fetch("checksum"))
      listing, error, status = Open3.capture3("bsdtar", "-tf", archive.path)
      raise ArgumentError, "Could not inspect ROR archive: #{error.strip}" unless status.success?
      names = listing.lines.map(&:strip).select { |name| name.end_with?(".json") }
      name = names.find { |entry| entry.include?("schema_v2") } || names.first
      raise ArgumentError, "ROR archive does not contain JSON" unless name

      Tempfile.create(["ror-organizations", ".json"]) do |json|
        json.binmode
        Open3.popen3("bsdtar", "-xOf", archive.path, name) do |stdin, stdout, stderr, thread|
          stdin.close
          errors = Thread.new { stderr.read }
          IO.copy_stream(stdout, json)
          error = errors.value
          raise ArgumentError, "Could not extract ROR JSON: #{error.strip}" unless thread.value.success?
        end
        json.flush
        import_file!(json.path, source_version: version, minimum_records: minimum_records,
          max_batches: max_batches, progress: progress,
          source_metadata: { "record_id" => metadata.fetch("id"), "doi" => metadata.fetch("doi"),
            "published_at" => metadata.dig("metadata", "publication_date"),
            "filename" => file.fetch("key"), "checksum" => file.fetch("checksum"), "json_filename" => name })
      end
    end
  end

  def self.import_file!(path, source_version:, source_metadata: {}, minimum_records: MINIMUM_RECORDS,
    max_batches: nil, progress: nil)
    raise ArgumentError, "minimum_records must be positive" unless minimum_records.is_a?(Integer) && minimum_records.positive?
    raise ArgumentError, "max_batches must be positive" if max_batches && (!max_batches.is_a?(Integer) || !max_batches.positive?)
    checksum = Digest::SHA256.file(path).hexdigest
    import = ResearchOrganizationImport.create_or_find_by!(source_version: source_version.to_s) do |record|
      record.checksum = checksum
      record.source_metadata = source_metadata
      record.retrieved_at = Time.current
    end
    raise ArgumentError, "ROR file changed for the saved source version" unless import.checksum == checksum
    return import.progress if import.completed_at
    token = import.claim
    raise ArgumentError, "ROR import is already running" unless token

    batch = []
    batches = 0
    stopped = false
    last_offset = import.byte_offset
    File.open(path, "rb") do |io|
      RorJsonReader.each_record(io, offset: import.byte_offset) do |record, offset|
        validate_record!(record)
        last_offset = offset
        batch << record
        if batch.size == BATCH_SIZE
          save_batch!(import, token, batch, offset)
          batch.clear
          batches += 1
          progress&.call("ROR records staged: #{import.records_processed}")
          if max_batches && batches >= max_batches
            stopped = true
            break
          end
        end
      end
      save_batch!(import, token, batch, last_offset) unless batch.empty?
    end
    activate!(import, token, minimum_records) unless stopped
    import.progress
  rescue StandardError => error
    if import && token
      import.with_lock do
        import.update!(last_error: "#{error.class}: #{error.message}".truncate(1_000)) if import.lease_token == token
      end
    end
    raise
  ensure
    if import && token
      import.with_lock do
        import.update!(lease_token: nil, lease_expires_at: nil) if import.lease_token == token
      end
    end
  end

  def self.validate_record!(record)
    unless record.is_a?(Hash) && record["id"].is_a?(String) && record["id"].match?(ResearchOrganization::ROR_ID)
      raise ArgumentError, "Invalid ROR identifier"
    end
    raise ArgumentError, "Invalid ROR status" unless %w[active inactive withdrawn].include?(record["status"])
    %w[names types domains links locations relationships].each do |key|
      raise ArgumentError, "Invalid ROR #{key}" unless record[key].is_a?(Array)
    end
    unless record["names"].all? { |name| name.is_a?(Hash) && name["value"].is_a?(String) && name["types"].is_a?(Array) } &&
      record["names"].count { |name| name["types"].include?("ror_display") && name["value"].present? } == 1
      raise ArgumentError, "Invalid ROR names"
    end
    raise ArgumentError, "Invalid ROR domains" unless record["domains"].all? { |domain| domain.is_a?(String) }
    raise ArgumentError, "Invalid ROR types" unless record["types"].all? { |type| type.is_a?(String) }
    raise ArgumentError, "Invalid ROR locations" unless record["locations"].all? { |location| location.is_a?(Hash) }
    unless record["links"].all? { |link| link.is_a?(Hash) && link["value"].is_a?(String) }
      raise ArgumentError, "Invalid ROR links"
    end
    record["relationships"].each do |relationship|
      unless relationship.is_a?(Hash) && RELATIONSHIP_TYPES.include?(relationship["type"]) &&
        relationship["id"].is_a?(String) && relationship["id"].match?(ResearchOrganization::ROR_ID)
        raise ArgumentError, "Invalid ROR relationship"
      end
    end
  end

  def self.matching_domains(record)
    domains = record.fetch("domains")
    if domains.empty?
      websites = record.fetch("links").select { |link| link["type"] == "website" }.map { |link| link.fetch("value") }
      domains = RorResearchOrganizationDomainImporter.root_website_domains(websites.join(";"))
    end
    domains.filter_map do |domain|
      value = ResearchOrganizationDomainMatcher.normalize_domain(domain)
      value if value && PublicSuffix.valid?(value)
    end.uniq
  end

  def self.save_batch!(import, token, records, offset)
    now = Time.current
    rows = records.map do |record|
      { ror_id: record.fetch("id"), pending_import_id: import.id, pending_metadata: record,
        pending_domains: matching_domains(record), created_at: now, updated_at: now }
    end
    relationships = records.flat_map do |record|
      record.fetch("relationships").map do |relationship|
        from, to, kind = record.fetch("id"), relationship.fetch("id"), relationship.fetch("type")
        if %w[parent predecessor].include?(kind)
          from, to = to, from
          kind = kind == "parent" ? "child" : "successor"
        elsif kind == "related"
          from, to = [from, to].sort
        end
        { research_organization_import_id: import.id, ror_id: from, related_ror_id: to,
          kind: kind, created_at: now, updated_at: now }
      end
    end
    import.with_lock do
      raise ArgumentError, "ROR import lease changed" unless import.lease_token == token
      ResearchOrganization.upsert_all(rows, unique_by: :index_research_organizations_on_ror_id,
        update_only: %i[pending_import_id pending_metadata pending_domains updated_at], record_timestamps: false)
      ResearchOrganizationRelationship.insert_all(relationships,
        unique_by: :index_research_organization_relationships_on_identity) if relationships.any?
      import.update!(byte_offset: offset, records_processed: import.records_processed + records.size,
        lease_expires_at: ResearchOrganizationImport::LEASE_DURATION.from_now)
    end
  end

  def self.activate!(import, token, minimum_records)
    import.with_lock do
      raise ArgumentError, "ROR import lease changed" unless import.lease_token == token
      count = ResearchOrganization.where(pending_import_id: import.id).count
      raise ArgumentError, "ROR import contains duplicate identifiers" unless count == import.records_processed
      raise ArgumentError, "ROR import contained only #{count} records" if count < minimum_records
      ResearchOrganization.where(pending_import_id: import.id).update_all(
        "metadata = pending_metadata, matching_domains = pending_domains, current_import_id = pending_import_id, " \
        "pending_metadata = NULL, pending_domains = '{}', pending_import_id = NULL, updated_at = CURRENT_TIMESTAMP")
      ResearchOrganizationImport.where(current: true).update_all(current: false)
      import.update!(current: true, completed_at: Time.current, last_error: nil)
    end
  end
end
