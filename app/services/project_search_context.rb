class ProjectSearchContext
  PROJECT_COLUMNS = %i[
    id url description repository brief codemeta packages updated_at last_synced_at
    dependencies_indexed_at
  ].freeze

  attr_reader :project, :metadata

  def self.scope
    Project.visible.scientific.select(*PROJECT_COLUMNS)
      .preload(direct_project_dependencies: { package: :package_registry }, published_package_records: :package_registry)
  end

  def initialize(project)
    @project = project
    @metadata = ProjectMetadata.new(project)
  end

  def as_json(*)
    repository = project.repository.is_a?(Hash) ? project.repository : {}
    brief = project.brief.is_a?(Hash) ? project.brief : {}
    codemeta = metadata.json_document(:codemeta)
    {
      project_id: project.id,
      repository_url: project.repository_url,
      updated_at: project.updated_at,
      last_synced_at: project.last_synced_at,
      repository_provenance: repository_provenance(repository),
      package_manifests: package_manifests(repository),
      descriptions: [
        evidence(project[:description], "project.description"),
        evidence(repository["description"], "repository.description"),
        evidence(codemeta["description"], "codemeta.description"),
      ].compact,
      languages: [
        evidence(repository["language"], "repository.language"),
        *language_evidence(brief["languages"], "brief.languages"),
        *language_evidence(codemeta["programmingLanguage"], "codemeta.programmingLanguage"),
      ].compact.uniq,
      packages: package_entries,
      dependencies_indexed_at: project.dependencies_indexed_at,
      direct_dependencies: direct_dependencies,
    }
  end

  def evidence(value, source)
    value = metadata.text(value)
    { value: value, source: source } if value
  end

  def repository_provenance(repository)
    %w[fork source_name mirror_url last_synced_at].each_with_object({ repository_url: project.repository_url }) do |key, result|
      next unless repository.key?(key)

      result[key] = { value: repository[key], source: "repository.#{key}" }
    end
  end

  def package_manifests(repository)
    stored = repository["metadata"].is_a?(Hash) ? repository["metadata"]["r_package_descriptions"] : nil
    Array.wrap(stored).grep(Hash).map do |item|
      fields = item["fields"].is_a?(Hash) ? item["fields"] : {}
      item.slice("path", "revision", "sha256", "retrieved_at", "url").merge(
        "names" => [evidence(fields["Package"], "DESCRIPTION.Package")].compact,
        "titles" => [evidence(fields["Title"], "DESCRIPTION.Title")].compact,
        "descriptions" => [evidence(fields["Description"], "DESCRIPTION.Description")].compact,
        "urls" => RPackageDescription.urls(metadata.text(fields["URL"])).map { |url| evidence(url, "DESCRIPTION.URL") },
        "bug_reports" => RPackageDescription.urls(metadata.text(fields["BugReports"])).map { |url| evidence(url, "DESCRIPTION.BugReports") }
      )
    end
  end

  def language_evidence(values, source)
    Array.wrap(values).filter_map do |value|
      if value.is_a?(Hash)
        evidence(value["name"], "#{source}.name")
      else
        evidence(value, source)
      end
    end
  end

  def package_entries
    ProjectPackageEntries.new(project).entries.filter_map do |entry|
      context = { names: [], descriptions: [], languages: [] }
      entry.fetch(:sources).each do |item|
        record = item.fetch(:record)
        source = item.fetch(:source)
        context[:names] << evidence(record["name"], "#{source}.name")
        context[:descriptions] << evidence(record["description"], "#{source}.description")
        context[:languages] << evidence(record["language"], "#{source}.language")
      end
      context.transform_values! { |values| values.compact.uniq }
      next if entry[:package_id].nil? && entry[:purl].nil? && context[:names].empty?

      entry.except(:sources).merge(context)
    end
  end

  def direct_dependencies
    project.direct_project_dependencies.sort_by(&:id).map do |dependency|
      record = dependency.metadata.is_a?(Hash) ? dependency.metadata : {}
      occurrences = Array.wrap(record["occurrences"]).grep(Hash).map do |occurrence|
        occurrence.slice("filepath", "manifest_kind", "requirements", "kind", "optional")
      end
      {
        dependency_id: dependency.id,
        package_id: dependency.package_id,
        name: dependency.package_name,
        ecosystem: dependency.ecosystem,
        purl: dependency.purl,
        resolved_package: resolved_package(dependency.package),
        source: metadata.text(record["source"]),
        occurrences: occurrences,
        updated_at: dependency.updated_at,
      }
    end
  end

  def resolved_package(package)
    return unless package

    {
      id: package.id,
      name: package.name,
      purl: package.purl,
      registry: { name: package.package_registry.name, ecosystem: package.package_registry.ecosystem },
      metadata_lookup: package.metadata_lookup,
    }
  end
end
