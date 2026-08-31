class PackageScienceScoreReviewReport
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100
  DEFAULT_MAX_SCORE = 40.0
  NON_JOSS_POSITIVE_SIGNALS = %i[
    has_citation_file
    has_codemeta
    has_zenodo
    has_doi_in_readme
    has_academic_links
    has_academic_committers
    has_institutional_owner
    has_scientific_registry
    has_scientific_dependencies
    has_research_tooling
    joss_vocabulary_similarity
  ].freeze
  JOSS_POSITIVE_SIGNALS = %i[
    has_citation_file
    has_codemeta
    has_zenodo
    has_doi_in_readme
    has_academic_committers
    has_institutional_owner
  ].freeze

  attr_reader :limit, :max_score, :now, :purls

  def initialize(
    purls: nil,
    limit: DEFAULT_LIMIT,
    max_score: DEFAULT_MAX_SCORE,
    now: Time.current
  )
    @purls = Array(purls).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    @limit = limit.to_i.clamp(1, MAX_LIMIT)
    @max_score = max_score.to_f
    @now = now
  end

  def generate
    selected_purls = purls.presence || candidate_purls
    packages = Package.where(purl: selected_purls)
      .includes(:package_registry, :published_by_project)
      .index_by(&:purl)
    counts = scientific_dependent_counts(packages.values)

    {
      generated_at: now.iso8601,
      selection: selection_report,
      packages: selected_purls.map do |purl|
        package = packages[purl]
        package ? package_report(package, counts) : missing_package_report(purl)
      end,
    }
  end

  def candidate_purls
    Package.ranked_by_scientific_dependents(sort: "science_relevance")
      .where("package_projects.science_score > 0")
      .where("package_projects.science_score <= ?", max_score)
      .where.not(purl: nil)
      .limit(limit)
      .map(&:purl)
  end

  def selection_report
    return { mode: "purls", count: purls.size } if purls.present?

    {
      mode: "current_candidates",
      limit: limit,
      minimum_science_score: 0.0,
      maximum_science_score: max_score,
      order: "science_relevance",
    }
  end

  def scientific_dependencies
    ProjectDependency.joins(:project)
      .merge(Project.visible)
      .merge(Project.scientific)
      .where(direct: true)
      .where.not(package_id: nil)
  end

  def scientific_dependent_counts(packages)
    package_ids = packages.map(&:id)
    return {} if package_ids.empty?

    scientific_dependencies
      .where(package_id: package_ids)
      .distinct
      .group(:package_id)
      .count(:project_id)
  end

  def missing_package_report(purl)
    {
      purl: purl,
      status: "package_not_found",
    }
  end

  def package_report(package, counts)
    report = {
      purl: package.purl,
      name: package.name,
      registry: {
        name: package.package_registry.name,
        ecosystem: package.package_registry.ecosystem,
      },
      scientific_projects_count: counts.fetch(package.id, 0),
      metadata: {
        status: package.ecosystems_sync_status,
        checked_at: package.ecosystems_checked_at&.iso8601,
        error: package.ecosystems_error,
      },
      repository_match: {
        url: package.repository_url,
        checked_at: package.repository_checked_at&.iso8601,
        error: package.repository_match_error,
      },
    }
    project = package.published_by_project
    return report.merge(
      status: "publishing_project_not_linked",
      project: nil
    ) unless project

    score = project.calculate_science_score_breakdown
    report.merge(
      status: "reviewed",
      project: project_report(project, score)
    )
  rescue StandardError => error
    report.merge(
      status: "score_calculation_error",
      project: basic_project_report(package.published_by_project),
      error: "#{error.class}: #{error.message}"
    )
  end

  def project_report(project, score)
    breakdown = score.fetch(:breakdown)
    {
      id: project.id,
      url: project.url,
      name: project.name,
      last_synced_at: project.last_synced_at&.iso8601,
      sync_age_days: sync_age_days(project),
      stored_science_score: project.science_score,
      calculated_science_score: score.fetch(:score),
      score_difference: score_difference(project, score),
      repository_metadata_files: repository_metadata_files(project),
      fetched_metadata: {
        citation: project.citation_file.present?,
        codemeta: project.codemeta.present?,
        zenodo: project.zenodo.present?,
      },
      brief: brief_report(project.brief),
      missing_positive_signals: missing_positive_signals(project, breakdown),
      science_score_breakdown: breakdown,
    }
  end

  def basic_project_report(project)
    return unless project

    {
      id: project.id,
      url: project.url,
      name: project.name,
      last_synced_at: project.last_synced_at&.iso8601,
      stored_science_score: project.science_score,
    }
  end

  def sync_age_days(project)
    return unless project.last_synced_at

    ((now - project.last_synced_at) / 1.day).round(2)
  end

  def score_difference(project, score)
    return unless project.science_score

    (score.fetch(:score) - project.science_score).round(2)
  end

  def repository_metadata_files(project)
    files = project.repository&.dig("metadata", "files")
    return {} unless files.is_a?(Hash)

    files.select { |_, value| value.present? }
  end

  def brief_report(brief)
    return { status: "not_collected" } unless brief.is_a?(Hash)
    if brief["error"].present?
      return {
        status: "error",
        attempted_at: brief["attempted_at"],
        error: brief["error"],
      }
    end

    {
      status: "collected",
      version: brief["version"],
      languages: brief_names(brief["languages"]),
      package_managers: brief_names(brief["package_managers"]),
      tools: brief_tools(brief["tools"]),
      manifests_count: collection_size(brief["manifests"]),
      dependencies_count: collection_size(brief["dependencies"]),
    }
  end

  def brief_names(items)
    Array(items).filter_map do |item|
      name = item.is_a?(Hash) ? item["name"] : item
      name if name.present?
    end
  end

  def brief_tools(tools)
    return {} unless tools.is_a?(Hash)

    tools.transform_values { |items| brief_names(items) }
      .reject { |_, names| names.empty? }
  end

  def collection_size(collection)
    collection.respond_to?(:size) ? collection.size : 0
  end

  def missing_positive_signals(project, breakdown)
    keys = project.joss_metadata.present? ?
      JOSS_POSITIVE_SIGNALS : NON_JOSS_POSITIVE_SIGNALS
    keys.filter_map do |key|
      signal = breakdown.fetch(key)
      next if signal.fetch(:present)

      {
        key: key,
        description: signal.fetch(:description),
        details: signal[:details],
      }.compact
    end
  end
end
