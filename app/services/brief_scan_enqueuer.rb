class BriefScanEnqueuer
  COHORTS = %w[all joss non_joss].freeze

  attr_reader :limit, :cohort, :shard_count, :shard, :rescan

  def initialize(limit: 100, cohort: "all", shard_count: 1, shard: 0, rescan: false)
    @limit = integer(limit, "LIMIT")
    @cohort = cohort
    @shard_count = integer(shard_count, "SHARD_COUNT")
    @shard = integer(shard, "SHARD")
    @rescan = rescan

    validate
  end

  def enqueue
    enqueued = 0

    projects.select(:id).limit(limit).find_each(batch_size: 500) do |project|
      args = rescan ? [project.id, true] : [project.id]
      enqueued += 1 if RepositoryScanWorker.perform_async(*args)
    end

    enqueued
  end

  def projects
    scope = Project.visible.with_repository
    scope = if rescan
      scope.with_external_identifier.where("science_score < ?", Project::SCIENCE_SCORE_THRESHOLD)
    else
      scope.needing_brief_dependencies.eligible_for_brief
    end
    scope = scope.with_joss if cohort == "joss"
    scope = scope.where(joss_metadata: nil) if cohort == "non_joss"
    shard_count == 1 ? scope : scope.where("projects.id % ? = ?", shard_count, shard)
  end

  def integer(value, name)
    return value if value.is_a?(Integer)

    Integer(value, 10)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be an integer"
  end

  def validate
    raise ArgumentError, "LIMIT must be greater than zero" unless limit.positive?
    raise ArgumentError, "COHORT must be all, joss, or non_joss" unless COHORTS.include?(cohort)
    raise ArgumentError, "SHARD_COUNT must be greater than zero" unless shard_count.positive?
    return if shard.between?(0, shard_count - 1)

    raise ArgumentError, "SHARD must be between zero and SHARD_COUNT - 1"
  end
end
