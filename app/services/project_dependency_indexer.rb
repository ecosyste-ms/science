class ProjectDependencyIndexer
  DEFAULT_LIMIT = 250
  MAX_LIMIT = 1_000
  REPOS_SOURCE = "repos_manifests"
  BRIEF_SOURCE = "brief"

  attr_reader :project, :retry_errors

  def initialize(project, retry_errors: false)
    @project = project
    @retry_errors = retry_errors
  end

  def self.sync_batch!(limit: DEFAULT_LIMIT, retry_errors: false)
    limit = Integer(limit, exception: false)
    unless limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end

    scope = Project
      .where("dependencies IS NOT NULL OR brief ? 'dependencies'")
      .where(dependencies_indexed_at: nil)
    scope = scope.where(dependencies_index_error: nil) unless retry_errors
    project_ids = scope.order(:id).limit(limit).pluck(:id)
    result = {
      selected: project_ids.length,
      indexed: 0,
      failed: 0,
      dependencies: 0,
      skipped: 0,
    }

    project_ids.each do |project_id|
      project = Project.find_by(id: project_id)
      next unless project

      begin
        counts = new(project, retry_errors: retry_errors).sync!
        next unless counts.fetch(:indexed)

        result[:indexed] += 1
        result[:dependencies] += counts.fetch(:dependencies)
        result[:skipped] += counts.fetch(:skipped)
      rescue StandardError => error
        message = "#{error.class}: #{error.message}".truncate(2_000)
        project.update_columns(
          dependencies_index_error: message,
          updated_at: Time.current
        )
        Rails.logger.error("Dependency indexing failed for project #{project.id}: #{message}")
        result[:failed] += 1
      end
    end

    result
  end

  def sync!
    result = nil

    project.with_lock do
      if project.dependencies_indexed_at.present? ||
          (project.dependencies_index_error.present? && !retry_errors)
        return { indexed: false, dependencies: 0, skipped: 0 }
      end

      grouped, skipped = grouped_dependencies
      existing = project.project_dependencies.to_a
      kept_ids = grouped.values.map do |attributes|
        dependency = matching_dependency(existing, attributes)
        existing.delete(dependency) if dependency
        dependency ||= project.project_dependencies.build
        dependency.assign_attributes(
          ecosystem: attributes.fetch(:ecosystem),
          package_name: attributes.fetch(:package_name),
          purl: attributes[:purl] || dependency.purl,
          direct: true,
          metadata: {
            "source" => attributes.fetch(:source),
            "occurrences" => attributes.fetch(:occurrences),
          }
        )
        dependency.save!
        dependency.id
      end

      project.project_dependencies.where.not(id: kept_ids).delete_all if kept_ids.any?
      project.project_dependencies.delete_all if kept_ids.empty?
      project.update_columns(
        dependencies_indexed_at: Time.current,
        dependencies_index_error: nil,
        updated_at: Time.current
      )
      result = { indexed: true, dependencies: kept_ids.length, skipped: skipped }
    end

    result
  end

  def grouped_dependencies
    grouped, skipped = grouped_repos_dependencies(project.dependencies)
    return [grouped, skipped] if grouped.any?

    brief_grouped, brief_skipped = grouped_brief_dependencies(project.brief)
    [brief_grouped, skipped + brief_skipped]
  end

  def grouped_repos_dependencies(manifests)
    return [{}, 0] if manifests.nil?

    unless manifests.is_a?(Array)
      raise ArgumentError, "dependencies must be an array"
    end

    skipped = 0
    grouped = {}
    manifests.each do |manifest|
      unless manifest.is_a?(Hash)
        raise ArgumentError, "each manifest must be an object"
      end

      dependencies = manifest["dependencies"] || []
      unless dependencies.is_a?(Array)
        raise ArgumentError, "manifest dependencies must be an array"
      end

      dependencies.each do |dependency|
        next unless dependency.is_a?(Hash) && dependency["direct"] == true

        ecosystem = (dependency["ecosystem"].presence || manifest["ecosystem"]).to_s.strip.downcase
        package_name = dependency["package_name"].to_s.strip
        if ecosystem.blank? || package_name.blank?
          skipped += 1
          next
        end

        purl = canonical_purl(dependency["purl"])
        key = purl.present? ? [purl] : [ecosystem, package_name]
        grouped[key] ||= {
          ecosystem: ecosystem,
          package_name: package_name,
          purl: purl,
          source: REPOS_SOURCE,
          occurrences: [],
        }
        grouped[key][:occurrences] << repos_occurrence(manifest, dependency)
      end
    end

    normalize_occurrences(grouped)
    [grouped, skipped]
  end

  def grouped_brief_dependencies(brief)
    return [{}, 0] unless brief.is_a?(Hash)

    dependencies = brief["dependencies"]
    return [{}, 0] if dependencies.nil?
    unless dependencies.is_a?(Array)
      raise ArgumentError, "Brief dependencies must be an array"
    end

    skipped = 0
    grouped = {}
    dependencies.each do |dependency|
      next unless dependency.is_a?(Hash) && dependency["direct"] == true

      package_name = dependency["name"].to_s.strip
      purl = canonical_purl(dependency["purl"])
      if package_name.blank? || purl.blank?
        skipped += 1
        next
      end

      ecosystem = Purl.parse(purl).type
      grouped[purl] ||= {
        ecosystem: ecosystem,
        package_name: package_name,
        purl: purl,
        source: BRIEF_SOURCE,
        occurrences: [],
      }
      grouped[purl][:occurrences] << brief_occurrence(dependency)
    end

    normalize_occurrences(grouped)
    [grouped, skipped]
  end

  def normalize_occurrences(grouped)
    grouped.each_value do |attributes|
      attributes[:occurrences] = attributes[:occurrences].uniq.sort_by do |item|
        item.values_at(
          "filepath", "manifest_kind", "requirements", "kind", "optional"
        ).map(&:to_s)
      end
    end
  end

  def canonical_purl(value)
    return if value.blank?

    Purl.parse(value).with(version: nil, subpath: nil).to_s
  rescue Purl::Error
    nil
  end

  def repos_occurrence(manifest, dependency)
    {
      "filepath" => manifest["filepath"],
      "manifest_kind" => manifest["kind"],
      "requirements" => dependency["requirements"],
      "kind" => dependency["kind"],
      "optional" => dependency["optional"] == true,
    }.compact
  end

  def brief_occurrence(dependency)
    {
      "requirements" => dependency["version"],
      "kind" => dependency["scope"],
      "optional" => dependency["optional"] == true,
    }.compact
  end

  def matching_dependency(existing, attributes)
    if attributes[:purl].present?
      existing.find { |dependency| dependency.purl == attributes[:purl] }
    else
      existing.find do |dependency|
        dependency.ecosystem == attributes[:ecosystem] &&
          dependency.package_name == attributes[:package_name]
      end
    end
  end
end
