class ProjectSearchSeeds
  PROJECT_COLUMNS = %i[
    id name url repository packages citation_file codemeta zenodo joss_metadata
    science_score updated_at last_synced_at
  ].freeze

  attr_reader :project, :metadata

  def self.scope
    Project.visible.scientific.select(*PROJECT_COLUMNS).order(:id)
      .preload(:repository_aliases, published_package_records: :package_registry)
  end

  def initialize(project)
    @project = project
    @metadata = ProjectMetadata.new(project)
  end

  def as_json(*)
    {
      project_id: project.id,
      repository_url: project.repository_url,
      science_score: project.science_score,
      updated_at: project.updated_at,
      last_synced_at: project.last_synced_at,
      seeds: project_seeds,
      packages: package_entries,
    }
  end

  def project_seeds
    repository = project.repository.is_a?(Hash) ? project.repository : {}
    seeds = [
      seed("name", project.name, "project.name"),
      seed("repository_url", project.repository_url, "project.url"),
      seed("homepage_url", repository["homepage"], "repository.homepage"),
    ]
    seeds.concat(repository_alias_seeds(repository))
    seeds.concat(citation_seeds)
    seeds.concat(codemeta_seeds)
    seeds.concat(zenodo_seeds)
    joss = project.joss_metadata.is_a?(Hash) ? project.joss_metadata : {}
    seeds.concat(doi_seeds(joss["doi"], "joss_metadata.doi", "publication"))
    seeds.compact.uniq
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
      project.repository_aliases.filter_map { |record| RepositoryUrlNormalizer.parse(record.url) }
    end
    urls.flat_map do |uri|
      url = "https://#{uri.host}#{uri.path}"
      [
        seed("repository_url", url, "repository.previous_names"),
        seed("name", uri.path.split("/").last&.delete_suffix(".git"), "repository.previous_names"),
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
      entry.except(:sources).merge(seeds: seeds.uniq) if seeds.any?
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
    { type: type, value: value, normalized_value: normalized, source: source, relation: "software" }
  rescue URI::InvalidURIError
    nil
  end
end
