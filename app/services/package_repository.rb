class PackageRepository
  attr_reader :project

  def initialize(project)
    @project = project
  end

  def self.origin(package)
    parsed = Purl.parse(package.purl)
    unless parsed.type == "huggingface" && package.package_registry.name.casecmp?("huggingface.co") &&
        parsed.namespace.present? && parsed.version.nil? && parsed.qualifiers.blank? && parsed.subpath.blank? &&
        [parsed.namespace, parsed.name].all? { |part| part.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) }
      raise ArgumentError, "Expected a Hugging Face model package"
    end
    "https://huggingface.co/#{parsed.namespace}/#{parsed.name}"
  end

  def self.link!(package)
    url = origin(package)
    Package.transaction do
      package.lock!
      project = Project.where("lower(url) = ?", url.downcase).first || Project.new(url: url)
      if package.published_by_project_id && package.published_by_project_id != project.id
        raise ArgumentError, "Package already has a different publishing project"
      end
      new(project).refresh_metadata(package)
      package.update!(published_by_project: project)
      project
    end
  end

  def self.import!(record, registry:)
    Package.transaction do
      package = registry.packages.find_or_initialize_by(purl: record.fetch("purl"))
      package.name = record.fetch("name")
      existing = Project.exists?(url: origin(package))
      conflict = PackageMetadataSync.new.local_identity_conflict(package, record)
      raise ArgumentError, conflict if conflict

      package.record_ecosystems_match!(record)
      [link!(package), !existing]
    end
  end

  def package
    project.published_package_records.find_by!(purl: project.repository.dig("metadata", "model_package_purl"))
  end

  def refresh_metadata(package)
    url = self.class.origin(package)
    raise ArgumentError, "Model package does not match project URL" unless project.url.casecmp?(url)

    data = package.metadata
    parsed = Purl.parse(package.purl)
    metadata = RepositoryMetadata.new(readme: project.readme, brief: project.brief)
    hub = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
    card = (hub["card_data"].is_a?(Hash) ? hub["card_data"] : {}).merge(metadata.frontmatter)
    strings = metadata.method(:strings)
    names = Array.wrap(card["model-index"]).filter_map { |entry| entry["name"] if entry.is_a?(Hash) }
    display_name = strings.call(card["model_name"]).first || (strings.call(names).first if strings.call(names).one?)
    repository = (project.repository || {}).deep_dup
    repository.merge!("html_url" => url, "clone_url" => url, "full_name" => "#{parsed.namespace}/#{parsed.name}",
      "owner" => parsed.namespace, "default_branch" => "main",
      "host" => { "name" => "HuggingFace.co", "url" => "https://huggingface.co", "kind" => "git" })
    repository.merge!(metadata.attributes)
    repository.merge!(
      "name" => display_name || metadata.name,
      "description" => strings.call(data["description"]).first || strings.call(card["description"]).first || metadata.description,
      "topics" => strings.call(data["keywords_array"]) | strings.call(data["keywords"]) | strings.call(card["tags"]),
      "license" => strings.call(card["license"]).presence&.join(", ") ||
        strings.call(data["normalized_licenses"]).presence&.join(", ") ||
        strings.call(data["licenses"]).presence&.join(", ") || repository["license"],
      "homepage" => strings.call(data["homepage"]).first,
      "gated" => hub["gated"],
      "created_at" => hub["created_at"], "pushed_at" => hub["last_modified"])
    details = {
      "supported_languages" => strings.call(card["language"]),
      "tasks" => strings.call(card["pipeline_tag"].presence || hub["pipeline_tag"]),
      "libraries" => strings.call(card["library_name"].presence || hub["library_name"]),
      "base_models" => strings.call(card["base_model"]),
      "datasets" => strings.call(card["datasets"])
    }.reject { |_, value| value.empty? }
    repository["metadata"] = (repository["metadata"] || {}).merge("model_package_purl" => package.purl,
      "source" => "packages.ecosyste.ms", "revision" => data["latest_release_number"],
      "details" => details)
    displayed_package = data.merge("name" => package.name, "purl" => package.purl, "registry_url" => data["registry_url"].presence || url,
      "registry" => { "name" => package.package_registry.name, "url" => package.package_registry.url },
      "maintainers" => Array(data["maintainers"]), "advisories" => Array(data["advisories"]),
      "rankings" => data["rankings"] || {})
    project.update!(repository: repository, packages: [displayed_package])
    project.refresh_display_name
    project.find_or_create_host
    project.combine_keywords
    project.update_score
  end
end
