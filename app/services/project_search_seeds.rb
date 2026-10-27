class ProjectSearchSeeds
  PROJECT_COLUMNS = %i[
    id name url repository packages citation_file codemeta zenodo joss_metadata
    science_score updated_at last_synced_at release_sync_state
  ].freeze

  attr_reader :project, :metadata

  def self.scope
    Project.visible.scientific.select(*PROJECT_COLUMNS).order(:id)
      .preload(:repository_aliases, published_package_records: :package_registry,
        project_external_software_records: :external_software_record)
  end

  def initialize(project, years: nil)
    @project = project
    @metadata = ProjectMetadata.new(project)
    @years = years
  end

  def years
    @years ||= SearchSeedYear.new([project])
  end

  def as_json(*)
    {
      project_id: project.id,
      repository_url: project.repository_url,
      science_score: project.science_score,
      updated_at: project.updated_at,
      last_synced_at: project.last_synced_at,
      search_year: years.for_project(project),
      seeds: project_seeds,
      packages: package_entries,
    }
  end

  def project_seeds
    repository = project.repository.is_a?(Hash) ? project.repository : {}
    seeds = [
      seed("name", project.name, "project.name"),
      seed("repository_url", project.repository_url, "project.url"),
      seed("name", project.repository_slug, "project.url"),
      seed("homepage_url", repository["homepage"], "repository.homepage"),
    ]
    seeds.concat(repository_alias_seeds(repository))
    seeds.concat(citation_seeds)
    seeds.concat(codemeta_seeds)
    seeds.concat(zenodo_seeds)
    seeds.concat(external_identifier_seeds)
    seeds.concat(wikidata_name_seeds)
    joss = project.joss_metadata.is_a?(Hash) ? project.joss_metadata : {}
    seeds.concat(doi_seeds(joss["doi"], "joss_metadata.doi", "publication"))
    seeds.compact.uniq
  end

  def external_identifier_seeds
    confirmed_software_links.filter_map do |link|
      record = link.external_software_record
      scheme = record.source.downcase

      {
        type: scheme, value: record.identifier,
        normalized_value: SoftwareIdentifier.normalize(record.identifier, scheme),
        source: "external_software_records.identifier", relation: "software",
        identifier_evidence: {
          scheme: scheme, external_software_record_id: record.id,
          project_external_software_record_id: link.id, record_url: record.record_url,
          relationship: link.relationship, evidence: link.evidence,
          retrieved_at: record.retrieved_at, source_status: record.status,
        },
      }
    rescue ArgumentError
      nil
    end
  end

  def confirmed_software_links
    project.project_external_software_records.select do |link|
      record = link.external_software_record
      link.match_status.casecmp?("matched") && SoftwareIdentifier::SCHEMES.include?(record.source.downcase) &&
        %w[ok error].include?(record.status.downcase) && record.retrieved_at &&
        %w[source_code_repository software software_version software_concept].include?(link.relationship.downcase)
    end
  end

  def wikidata_name_seeds
    confirmed_software_links.select { |link| link.external_software_record.source.casecmp?("wikidata") }.flat_map do |link|
      record = link.external_software_record
      next [] unless record.metadata.is_a?(Hash)

      %w[labels aliases].flat_map do |field|
        translations = record.metadata[field]
        next [] unless translations.is_a?(Hash)

        translations.flat_map do |language, items|
          (field == "labels" ? [items] : Array.wrap(items)).filter_map do |item|
            next unless item.is_a?(Hash)

            source = "external_software_records.metadata.#{field}.#{language}"
            entry = seed("name", item["value"], source)
            next unless entry

            entry.merge(name_evidence: {
              kind: field == "labels" ? "registry_label" : "registry_alias", source: source,
              value: entry[:value], language: language, scheme: "wikidata",
              external_software_record_id: record.id, project_external_software_record_id: link.id,
              record_url: record.record_url, relationship: link.relationship, evidence: link.evidence,
              retrieved_at: record.retrieved_at, source_status: record.status,
            })
          end
        end
      end
    end
  end

  def repository_alias_seeds(repository)
    host = URI.parse(project.repository_url).host
    previous_names = repository["previous_names"]
    urls = if previous_names.is_a?(Array)
      previous_names.filter_map do |name|
        next unless name.is_a?(String) && name.present?

        value = name.strip
        value = "https://#{host}/#{value}" unless value.include?("://") || value.start_with?("git@")
        uri = RepositoryUrlNormalizer.parse(value)
        uri if RepositoryUrlNormalizer.normalize(value)
      end
    else
      []
    end
    aliases = urls.map { |uri| [uri, "repository.previous_names"] }
    aliases += project.repository_aliases.filter_map do |record|
      uri = RepositoryUrlNormalizer.parse(record.url)
      [uri, "project_repository_aliases.url"] if uri
    end
    aliases.flat_map do |uri, source|
      url = "https://#{uri.host}#{uri.path}"
      [
        seed("repository_url", url, source),
        seed("name", uri.path.split("/").last&.delete_suffix(".git"), source),
      ]
    end
  rescue URI::InvalidURIError
    []
  end

  def citation_seeds
    document = metadata.cff_document
    seeds = [
      seed("name", document["title"], "citation_cff.title"),
      seed("homepage_url", document["url"], "citation_cff.url"),
      seed("repository_url", document["repository-code"], "citation_cff.repository-code"),
    ]
    relation = document["type"] == "dataset" ? "reference" : "software"
    seeds.concat(doi_seeds(document["doi"], "citation_cff.doi", relation))
    Array.wrap(document["identifiers"]).each do |identifier|
      next unless identifier.is_a?(Hash) && identifier["type"].to_s.casecmp?("doi")

      seeds.concat(doi_seeds(identifier["value"], "citation_cff.identifiers", relation))
    end
    seeds.concat(project.citation_cff_preferred_doi_candidates.flat_map do |candidate|
      doi_seeds(candidate[:value], candidate[:source], "preferred_citation")
    end)
    seeds.concat(project.citation_bib_doi_candidates.flat_map do |candidate|
      doi_seeds(candidate[:value], candidate[:source], "citation")
    end)
    seeds
  end

  def codemeta_seeds
    document = metadata.json_document(:codemeta)
    seeds = [
      seed("name", document["name"], "codemeta.name"),
      seed("homepage_url", document["url"], "codemeta.url"),
      seed("repository_url", document["codeRepository"], "codemeta.codeRepository"),
    ]
    Array.wrap(document["alternateName"]).each do |name|
      seeds << seed("name", name, "codemeta.alternateName")
    end
    %w[identifier referencePublication].each do |field|
      relation = field == "identifier" ? "software" : "publication"
      project.doi_candidates_from_metadata_value(document[field], "codemeta.#{field}").each do |candidate|
        seeds.concat(doi_seeds(candidate[:value], candidate[:source], relation))
      end
    end
    seeds
  end

  def zenodo_seeds
    document = metadata.json_document(:zenodo)
    seeds = doi_seeds(document["doi"], "zenodo.doi", "software")
    Array.wrap(document["related_identifiers"]).each do |identifier|
      next unless identifier.is_a?(Hash)
      next unless identifier["scheme"].to_s.casecmp?("doi")
      next unless identifier["relation"].to_s.casecmp?("isDocumentedBy")

      seeds.concat(doi_seeds(
        identifier["identifier"], "zenodo.related_identifiers.isDocumentedBy", "publication"
      ))
    end
    seeds
  end

  def package_entries
    ProjectPackageEntries.new(project).entries.filter_map do |entry|
      seeds = entry.fetch(:sources).flat_map do |item|
        record = item.fetch(:record)
        source = item.fetch(:source)
        [
          seed("name", record["name"], "#{source}.name"),
          seed("homepage_url", record["homepage"], "#{source}.homepage"),
        ].compact
      end
      entry.except(:sources).merge(seeds: seeds.uniq, search_year: years.for_package(entry, project)) if seeds.any?
    end
  end

  def doi_seeds(value, source, relation)
    return [] unless value.is_a?(String)

    Project.extract_dois(value).map do |doi|
      { type: "doi", value: doi, normalized_value: doi.downcase, source: source, relation: relation }
    end
  end

  def seed(type, value, source)
    value = metadata.text(value)
    return unless value

    normalized = if type == "name"
      value.unicode_normalize(:nfc).downcase
    else
      uri = URI.parse(value)
      return unless %w[http https].include?(uri.scheme&.downcase) && uri.host.present?
      return if uri.userinfo.present?

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      uri.to_s
    end
    result = { type: type, value: value, normalized_value: normalized, source: source, relation: "software" }
    result[:name_evidence] = name_evidence(source, value) if type == "name"
    result
  rescue URI::InvalidURIError
    nil
  end

  def name_evidence(source, value)
    if source == "project.name"
      stored = project.repository.is_a?(Hash) ? project.repository["metadata"] : nil
      if stored.is_a?(Hash) && stored["derived_name"] == value
        evidence = stored["derived_name_evidence"]
        if evidence.is_a?(Hash) && evidence["value"] == value && evidence["kind"].is_a?(String) && evidence["source"].is_a?(String)
          return evidence.symbolize_keys.slice(:kind, :source, :value)
        end
        return { kind: "derived_unknown", source: "repository.metadata.derived_name", value: value }
      end
      return { kind: "unknown", source: source, value: value }
    end

    kind = case source
    when "project.url", "repository.previous_names", "project_repository_aliases.url" then "repository_slug"
    when /\A(?:package\.name|project\.packages\[\d+\]\.name)\z/ then "package_name"
    else "declared_metadata"
    end
    { kind: kind, source: source, value: value }
  end
end
