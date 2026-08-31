class PackageProjectRefreshEnqueuer
  DEFAULT_LIMIT = 25
  MAXIMUM_LIMIT = 25
  REFRESH_AFTER = 7.days

  attr_reader :limit, :now

  def initialize(limit: DEFAULT_LIMIT, now: Time.current)
    @limit = integer(limit)
    @now = now

    validate
  end

  def enqueue
    selected_projects = projects.limit(limit).to_a
    selected_projects.each do |project|
      SyncProjectWorker.perform_async(project.id)
    end
    selected_projects.size
  end

  def projects
    usage = Package.scientific_publishing_project_counts

    Project.visible
      .joins(
        "INNER JOIN (#{usage.to_sql}) scientific_package_usage " \
        "ON scientific_package_usage.project_id = projects.id"
      )
      .where("projects.science_score <= 0")
      .where("projects.last_synced_at < ?", now - REFRESH_AFTER)
      .order(
        Arel.sql(
          "scientific_package_usage.scientific_dependents_count DESC, " \
          "projects.last_synced_at ASC, projects.id ASC"
        )
      )
  end

  def integer(value)
    return value if value.is_a?(Integer)

    Integer(value, 10)
  rescue ArgumentError, TypeError
    raise ArgumentError, "LIMIT must be an integer"
  end

  def validate
    unless limit.between?(1, MAXIMUM_LIMIT)
      raise ArgumentError, "LIMIT must be between 1 and #{MAXIMUM_LIMIT}"
    end
  end
end
