class Package < ApplicationRecord
  GENERAL_DEPENDENT_REPOSITORIES_SQL =
    "packages.general_dependent_repositories_count".freeze
  DEPENDENT_REPOSITORIES_TOP_PERCENTAGE_SQL =
    "packages.dependent_repositories_top_percentage".freeze
  AVERAGE_TOP_PERCENTAGE_SQL = "packages.average_top_percentage".freeze
  SCIENCE_RELEVANCE_TOP_PERCENTAGE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN #{AVERAGE_TOP_PERCENTAGE_SQL} >= 100.0
        AND #{DEPENDENT_REPOSITORIES_TOP_PERCENTAGE_SQL} = 0.0
      THEN 0.0
      ELSE #{AVERAGE_TOP_PERCENTAGE_SQL}
    END
  SQL
  REPOSITORY_SCIENCE_SCORE_SQL = <<~SQL.squish.freeze
    package_projects.science_score
  SQL
  REPOSITORY_SCIENCE_BOOST_SQL = <<~SQL.squish.freeze
    (
      1.0 + COALESCE(
        LEAST(GREATEST(#{REPOSITORY_SCIENCE_SCORE_SQL}, 0.0), 100.0),
        0.0
      ) / 100.0
    )
  SQL
  SCIENCE_RELEVANCE_SCORE_SQL = <<~SQL.squish.freeze
    CASE WHEN #{SCIENCE_RELEVANCE_TOP_PERCENTAGE_SQL} IS NOT NULL THEN
      scientific_dependency_counts.scientific_dependents_count * (
        0.10 + 0.90 * LEAST(
          GREATEST(#{SCIENCE_RELEVANCE_TOP_PERCENTAGE_SQL}, 0.0),
          5.0
        ) / 5.0
      ) * #{REPOSITORY_SCIENCE_BOOST_SQL}
    END
  SQL
  ECOSYSTEMS_SYNC_STATUSES = %w[
    matched
    missing
    unavailable
    ambiguous
    transient_error
    failed
  ].freeze
  MISSING_RETRY_DELAYS = [1.day, 7.days].freeze
  ERROR_RETRY_DELAYS = [1.hour, 6.hours, 1.day].freeze

  belongs_to :package_registry
  belongs_to :published_by_project, class_name: "Project", optional: true

  has_many :project_dependencies, dependent: :nullify
  has_many :dependent_projects, through: :project_dependencies, source: :project

  validates :name, presence: true
  validates :name, uniqueness: { scope: :package_registry_id }
  validates :ecosystems_id, uniqueness: true, allow_nil: true
  validates :purl, uniqueness: true, allow_nil: true
  validates :ecosystems_sync_status,
    inclusion: { in: ECOSYSTEMS_SYNC_STATUSES },
    allow_nil: true

  before_validation :normalize_purl
  before_validation :normalize_ranking_metadata,
    if: :will_save_change_to_metadata?

  def self.ranked_by_scientific_dependents(
    field_ids: nil,
    sort: "scientific_projects"
  )
    counts = ProjectDependency.joins(:project)
      .merge(Project.visible)
      .merge(Project.scientific)
      .where(direct: true)
      .where.not(package_id: nil)
    unless field_ids.nil?
      project_ids = ProjectField.where(field_id: field_ids).select(:project_id)
      counts = counts.where(project_id: project_ids)
    end
    counts = counts.group(:package_id).select(
      "project_dependencies.package_id, " \
      "COUNT(DISTINCT project_dependencies.project_id) AS scientific_dependents_count"
    )

    joins(
      "INNER JOIN (#{counts.to_sql}) scientific_dependency_counts " \
      "ON scientific_dependency_counts.package_id = packages.id"
    )
      .joins(
        "LEFT JOIN projects package_projects " \
        "ON package_projects.id = packages.published_by_project_id"
      )
      .where(
        "package_projects.science_score IS NULL OR " \
        "package_projects.science_score > 0"
      )
      .select(
        "packages.*, " \
        "scientific_dependency_counts.scientific_dependents_count, " \
        "#{GENERAL_DEPENDENT_REPOSITORIES_SQL} " \
        "AS general_dependent_repositories_count, " \
        "#{DEPENDENT_REPOSITORIES_TOP_PERCENTAGE_SQL} " \
        "AS dependent_repositories_top_percentage, " \
        "#{AVERAGE_TOP_PERCENTAGE_SQL} AS average_top_percentage, " \
        "#{SCIENCE_RELEVANCE_TOP_PERCENTAGE_SQL} " \
        "AS science_relevance_top_percentage, " \
        "#{REPOSITORY_SCIENCE_SCORE_SQL} AS repository_science_score, " \
        "#{SCIENCE_RELEVANCE_SCORE_SQL} AS science_relevance_score, " \
        "CASE WHEN #{GENERAL_DEPENDENT_REPOSITORIES_SQL} > 0 " \
        "THEN scientific_dependency_counts.scientific_dependents_count * 100.0 " \
        "/ #{GENERAL_DEPENDENT_REPOSITORIES_SQL} END " \
        "AS science_usage_percentage"
      )
      .preload(:package_registry, :published_by_project)
      .order(*scientific_dependency_order(sort))
  end

  def self.scientific_dependency_order(sort)
    order = []
    if sort == "science_relevance"
      order << Arel.sql("#{SCIENCE_RELEVANCE_SCORE_SQL} DESC NULLS LAST")
    end
    order << Arel.sql(
      "scientific_dependency_counts.scientific_dependents_count DESC"
    )
    order << Arel.sql("lower(packages.name) ASC")
    order << :id
    order
  end

  def self.scientific_dependency_ecosystems
    ProjectDependency.joins(:project, package: :package_registry)
      .merge(Project.visible)
      .merge(Project.scientific)
      .where(direct: true)
      .distinct
      .order("package_registries.ecosystem")
      .pluck("package_registries.ecosystem")
  end

  def normalize_purl
    if purl.blank?
      self.purl = nil
      return
    end

    parsed = Purl.parse(purl)
    self.purl = parsed.with(version: nil, subpath: nil).to_s
    if package_registry && parsed.type != package_registry.purl_type
      errors.add(:purl, "type must match the package registry")
    end
  rescue Purl::Error => error
    errors.add(:purl, error.message)
  end

  def normalize_ranking_metadata(now: Time.current)
    rankings = metadata["rankings"]
    rankings = {} unless rankings.is_a?(Hash)
    self.general_dependent_repositories_count = Integer(
      metadata["dependent_repos_count"],
      exception: false
    )
    self.dependent_repositories_top_percentage = Float(
      rankings["dependent_repos_count"],
      exception: false
    )
    self.average_top_percentage = Float(
      rankings["average"],
      exception: false
    )
    self.ranking_metadata_normalized_at = now
  end

  def claim_ecosystems_sync!(now: Time.current)
    stale_before = now - 30.minutes
    claimed = self.class.where(id: id)
      .where(
        "ecosystems_sync_started_at IS NULL OR ecosystems_sync_started_at < ?",
        stale_before
      )
      .update_all(ecosystems_sync_started_at: now)
    claimed == 1
  end

  def release_ecosystems_sync!
    self.class.where(id: id).update_all(
      ecosystems_sync_started_at: nil
    )
  end

  def record_ecosystems_match!(record, now: Time.current)
    attributes = {
      ecosystems_id: record.fetch("id"),
      namespace: record["namespace"],
      metadata: record,
      ecosystems_updated_at: record["updated_at"],
      ecosystems_sync_status: "matched",
      ecosystems_checked_at: now,
      ecosystems_retry_at: nil,
      ecosystems_sync_started_at: nil,
      ecosystems_error: nil,
      ecosystems_error_count: 0,
    }
    attributes[:purl] = record["purl"] if record["purl"].present?

    remote_repository_url = record["repository_url"].presence
    if repository_url != remote_repository_url
      attributes.merge!(
        repository_url: remote_repository_url,
        published_by_project_id: nil,
        repository_checked_at: nil,
        repository_match_error: nil
      )
    end

    update!(attributes)
    :matched
  end

  def record_ecosystems_missing!(now: Time.current)
    count = ecosystems_miss_count + 1
    delay = MISSING_RETRY_DELAYS[count - 1]
    status = delay ? "missing" : "unavailable"
    update!(
      ecosystems_sync_status: status,
      ecosystems_checked_at: now,
      ecosystems_retry_at: delay ? now + delay : nil,
      ecosystems_sync_started_at: nil,
      ecosystems_miss_count: count,
      ecosystems_error_count: 0,
      ecosystems_error: nil
    )
    status.to_sym
  end

  def record_ecosystems_ambiguous!(count, now: Time.current)
    update!(
      ecosystems_sync_status: "ambiguous",
      ecosystems_checked_at: now,
      ecosystems_retry_at: nil,
      ecosystems_sync_started_at: nil,
      ecosystems_error: "lookup returned #{count} packages"
    )
    :ambiguous
  end

  def record_ecosystems_error!(error, now: Time.current)
    count = ecosystems_error_count + 1
    delay = ERROR_RETRY_DELAYS[count - 1]
    status = delay ? "transient_error" : "failed"
    update!(
      ecosystems_sync_status: status,
      ecosystems_checked_at: now,
      ecosystems_retry_at: delay ? now + delay : nil,
      ecosystems_sync_started_at: nil,
      ecosystems_error_count: count,
      ecosystems_error: "#{error.class}: #{error.message}".truncate(2_000)
    )
    status.to_sym
  end
end
