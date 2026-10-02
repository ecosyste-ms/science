class ExternalSoftwareImporter
  def repository_url?(url)
    uri = URI.parse(url)
    segments = uri.path.split("/").reject(&:blank?)
    return false if segments.any? { |segment| !segment.match?(/\A[a-z0-9_.-]+\z/i) || %w[. ..].include?(segment) }
    case uri.host
    when "github.com"
      segments.size == 2 && MetadataRepositoryImporter.valid_github_owner?(segments.first) &&
        !MetadataRepositoryImporter::GITHUB_RESERVED_OWNERS.include?(segments.first)
    when "bitbucket.org"
      segments.size == 2 && !%w[account product support].include?(segments.first)
    else
      gitlab_hosts.include?(uri.host) && segments.size >= 2 && !MetadataRepositoryImporter::GITLAB_RESERVED_ROOTS.include?(segments.first)
    end
  end

  def gitlab_hosts
    @gitlab_hosts ||= ExternalRepositoryDiscovery.new.gitlab_hosts
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
        evidence = statement.merge(
          normalized_url: lookup[:normalized_url], match_method: match[:source], ambiguous: ambiguous)
        if RepositoryUrlNormalizer.github_pages_repository(statement[:repository_url])
          evidence.merge!(source_url: statement[:repository_url], url_transformation: "github_pages")
        end
        links[match[:project].fetch("id")] << evidence
      end
    end
    links.transform_values(&:uniq)
  end

  def record_for(id, started_at)
    existing = ExternalSoftwareRecord.where(source: self.class::SOURCE, identifier: id).select(:id).first
    return existing if existing

    ExternalSoftwareRecord.create_or_find_by!(source: self.class::SOURCE, identifier: id) do |record|
      record.next_refresh_at = started_at
    end
  end

  def persist(id, entity, matches, started_at, collection_url: nil, concept_identifier: nil)
    record = record_for(id, started_at)
    record.with_lock do
      next if record.attempted_at && record.attempted_at > started_at
      if entity.key?("missing")
        record.update!(status: "missing", attempted_at: started_at, last_error: nil, next_refresh_at: 7.days.from_now)
        next
      end

      record.next_discovery_at = Time.current if record.metadata != entity || record.status != "ok"
      persist_links(record, entity, matches)
      record.update!(metadata: entity, status: "ok", retrieved_at: started_at, attempted_at: started_at,
        last_error: nil, next_refresh_at: 30.days.from_now, collection_url: collection_url, concept_identifier: concept_identifier)
    end
  end

  def persist_links(record, entity, matches)
    links = links_for(entity, matches)
    existing = record.project_external_software_records.index_by(&:project_id)
    rows = []
    links.each do |project_id, evidence|
      link = existing.delete(project_id) || ProjectExternalSoftwareRecord.new(project_id: project_id, external_software_record_id: record.id)
      link.assign_attributes(relationship: relationship_for(entity),
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
  end

  def record_failure(id, error, started_at, retry_at)
    record = record_for(id, started_at)
    record.with_lock do
      next if record.attempted_at && record.attempted_at > started_at
      record.update!(status: "error", attempted_at: started_at, last_error: error.message, next_refresh_at: retry_at)
    end
  end

  def relationship_for(entity)
    "source_code_repository"
  end
end
