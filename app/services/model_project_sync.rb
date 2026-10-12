class ModelProjectSync
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

  def package
    project.published_package_records.find_by!(purl: project.repository.dig("metadata", "model_package_purl"))
  end

  def refresh_metadata(package)
    url = self.class.origin(package)
    raise ArgumentError, "Model package does not match project URL" unless project.url.casecmp?(url)

    data = package.metadata
    parsed = Purl.parse(package.purl)
    repository = (project.repository || {}).deep_dup
    repository.merge!("html_url" => url, "clone_url" => url, "full_name" => "#{parsed.namespace}/#{parsed.name}",
      "owner" => parsed.namespace, "default_branch" => "main",
      "topics" => Array(data["keywords"]), "description" => data["description"],
      "host" => { "name" => "HuggingFace.co", "url" => "https://huggingface.co", "kind" => "git" })
    repository["metadata"] = (repository["metadata"] || {}).merge("model_package_purl" => package.purl,
      "source" => "packages.ecosyste.ms", "revision" => data["latest_release_number"])
    displayed_package = data.merge("name" => package.name, "purl" => package.purl, "registry_url" => data["registry_url"].presence || url,
      "registry" => { "name" => package.package_registry.name, "url" => package.package_registry.url },
      "maintainers" => Array(data["maintainers"]), "advisories" => Array(data["advisories"]),
      "rankings" => data["rankings"] || {})
    project.update!(repository: repository, packages: [displayed_package])
    project.find_or_create_host
    project.combine_keywords
  end

  def sync
    refresh_metadata(package)
    revision = project.repository.dig("metadata", "revision")
    changed = project.brief&.dig("revision") != revision
    ProjectRepositoryScanner.new(project, force_brief: changed).scan
    project.update!(last_synced_at: Time.current)
  end

  def store_files(files, revision)
    resources = project.brief.fetch("resources") || {}
    paths = resources.slice("readme", "citation", "codemeta", "zenodo")
    by_path = files.index_by { |file| file["path"] }
    attributes = {}
    { "readme" => :readme, "citation" => :citation_file, "codemeta" => :codemeta, "zenodo" => :zenodo }.each do |key, attribute|
      file = by_path[paths[key]]
      attributes[attribute] = file&.fetch("content", nil) if paths[key].nil? || file&.dig("status") == "ok"
    end
    repository = project.repository.deep_dup
    repository["metadata"]["files"] = paths
    if project.swhids && project.swhids["commit"] != revision
      attributes[:swhids] = project.swhids.slice("origin_archive")
    end
    project.update!(**attributes, repository: repository, last_synced_at: Time.current,
      brief: project.brief.merge("revision" => revision, "scanned_at" => Time.current.iso8601))
  end
end
