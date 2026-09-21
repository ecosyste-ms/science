class ProjectSearchContext
  PROJECT_COLUMNS = %i[
    id url description repository brief codemeta packages updated_at last_synced_at
    dependencies_indexed_at
  ].freeze

  attr_reader :project, :metadata

  def self.scope
    Project.visible.scientific.select(*PROJECT_COLUMNS)
      .preload(:direct_project_dependencies, published_package_records: :package_registry)
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
        source: metadata.text(record["source"]),
        occurrences: occurrences,
        updated_at: dependency.updated_at,
      }
    end
  end
end
