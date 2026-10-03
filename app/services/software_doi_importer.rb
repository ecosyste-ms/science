class SoftwareDoiImporter < ExternalSoftwareImporter
  SOURCE = "doi"
  REPOSITORY_RELATIONS = %w[issupplementto isidenticalto isversionof].freeze

  def sync(ids)
    ids = SoftwareDoiClient.validate_ids!(ids)
    started_at = Time.current
    cached = ExternalSoftwareRecord.where(source: SOURCE, identifier: ids).pluck(:identifier, :next_refresh_at).to_h
    ids.each do |id|
      next if cached[id] && cached[id] > started_at
      begin
        entity = SoftwareDoiClient.new.record(id)
        persist(id, entity, repository_matches([entity]), started_at,
          collection_url: SoftwareDoiClient.collection_url(id), concept_identifier: concept_identifier(entity))
      rescue SoftwareDoiClient::Error => error
        retry_at = error.is_a?(SoftwareDoiClient::RateLimited) ? error.retry_at : 1.hour.from_now
        record_failure(id, error, started_at, retry_at)
        raise
      end
    end
  end

  def software?(entity)
    entity.dig("datacite", "attributes", "types", "resourceTypeGeneral").to_s.casecmp?("software")
  end

  def concept_identifier(entity)
    return unless software?(entity)
    zenodo = entity["zenodo"]
    if zenodo
      return if zenodo["conceptdoi"].blank?
      return SoftwareDoiClient.identifier(zenodo["conceptdoi"])
    end
    relations = entity.dig("datacite", "attributes", "relatedIdentifiers")
    parents = Array(relations).filter_map do |item|
      next unless item["relationType"].casecmp?("IsVersionOf") && item["relatedIdentifierType"].casecmp?("DOI")
      SoftwareDoiClient.identifier(item["relatedIdentifier"])
    rescue ArgumentError
      nil
    end.uniq
    parents.sole if parents.one?
  end

  def relationship_for(entity)
    parent = concept_identifier(entity)
    return "software_version" if parent && parent != entity["doi"]
    return "software_concept" if parent == entity["doi"] || Array(entity.dig("datacite", "attributes", "relatedIdentifiers"))
      .any? { |item| item["relationType"].casecmp?("HasVersion") }
    "software"
  end

  def repository_statements(entity)
    return [] unless software?(entity)
    attributes = entity.dig("datacite", "attributes")
    entries = [{ repository_url: attributes["url"], source_field: "datacite.url" }]
    attributes["relatedIdentifiers"].each do |item|
      next unless item["relatedIdentifierType"].casecmp?("URL") && REPOSITORY_RELATIONS.include?(item["relationType"].downcase)
      entries << { repository_url: item["relatedIdentifier"], source_field: "datacite.relatedIdentifiers", source_relation: item["relationType"] }
    end
    entries.each { |entry| entry[:collection_url] = SoftwareDoiClient.collection_url(entity["doi"]) }
    if (zenodo = entity["zenodo"])
      url = "#{SoftwareDoiClient::ZENODO_URL}/#{zenodo['id']}"
      entries << { repository_url: zenodo.dig("metadata", "custom", "code:codeRepository"),
        source_field: "zenodo.metadata.custom.code:codeRepository", collection_url: url }
      Array(zenodo.dig("metadata", "related_identifiers")).each do |item|
        next unless item["scheme"].casecmp?("url") && REPOSITORY_RELATIONS.include?(item["relation"].downcase)
        entries << { repository_url: item["identifier"], source_field: "zenodo.metadata.related_identifiers",
          source_relation: item["relation"], collection_url: url }
      end
    end
    entries.filter_map do |entry|
      url = entry[:repository_url]
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      next unless uri && uri.userinfo.nil? && %w[http https].include?(uri.scheme) && [80, 443].include?(uri.port)
      normalized = RepositoryUrlNormalizer.normalize(url)
      next unless normalized && repository_url?(normalized)
      entry.merge(source_record_url: SoftwareDoiClient.record_url(entity["doi"]))
    end.uniq
  end

  def links_for(entity, matches)
    links = super
    return links unless software?(entity)
    id = entity.fetch("doi")
    candidates = SoftwareDoiSeeds.scope.where("search_identifiers @> ?::jsonb", { doi: [id] }.to_json).limit(101).to_a
    raise SoftwareDoiClient::Error, "DOI has more than 100 candidate projects" if candidates.size > 100
    evidence = candidates.filter_map do |project|
      seeds = SoftwareDoiSeeds.evidence(project).select { |seed| seed[:normalized_value] == id }
      [project.id, seeds] if seeds.any?
    end
    evidence.each do |project_id, seeds|
      links[project_id] ||= []
      seeds.each do |seed|
        links[project_id] << { normalized_doi: id, source_field: seed[:source], match_method: "software_doi",
          collection_url: SoftwareDoiClient.collection_url(id), source_record_url: SoftwareDoiClient.record_url(id),
          ambiguous: evidence.size > 1 }
      end
    end
    links
  end
end
