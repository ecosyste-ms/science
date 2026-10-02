class AsclImporter < ExternalSoftwareImporter
  SOURCE = "ascl"

  def sync(ids)
    ids = AsclClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :next_refresh_at).to_h
    due = ids.reject { |id| cached[id] && cached[id] > started_at }
    return if due.empty?
    page = AsclClient.new.records(due)
    sync_page(page[:records], started_at: page[:retrieved_at])
  rescue AsclClient::Error => error
    retry_at = error.is_a?(AsclClient::RateLimited) ? error.retry_at : 1.hour.from_now
    due.each { |id| record_failure(id, error, started_at, retry_at) }
    raise
  end

  def sync_page(records, started_at:)
    return if records.empty?
    ids = AsclClient.validate_ids!(records.pluck("ascl_id"))
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :retrieved_at).to_h
    records = records.reject { |record| cached[record["ascl_id"]]&.>= started_at }
    matches = repository_matches(records)
    records.each { |record| persist(record.fetch("ascl_id"), record, matches, started_at) }
  end

  def repository_statements(entity)
    return [] unless entity["site_list"].is_a?(Array)
    entity["site_list"].filter_map do |url|
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      next unless uri && uri.userinfo.nil? && %w[http https].include?(uri.scheme) && [80, 443].include?(uri.port)
      normalized = RepositoryUrlNormalizer.normalize(url)
      next unless normalized && repository_url?(normalized)
      { repository_url: url, source_field: "site_list", collection_url: AsclClient::CATALOGUE_URL }
    end.uniq
  end

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
end
