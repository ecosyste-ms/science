class BriefScanEnqueuer
  COHORTS = %w[all joss non_joss].freeze

  attr_reader :limit, :cohort, :shard_count, :shard

  def initialize(limit: 100, cohort: "all", shard_count: 1, shard: 0)
    @limit = integer(limit, "LIMIT")
    @cohort = cohort
    @shard_count = integer(shard_count, "SHARD_COUNT")
    @shard = integer(shard, "SHARD")

    validate
  end

  def enqueue
    enqueued = 0

    projects.limit(limit).find_each(batch_size: 500) do |project|
      FetchBriefWorker.perform_async(project.id)
      enqueued += 1
    end

    enqueued
  end

  def projects
    base = Project.visible.with_repository.needing_brief_dependencies
    scope = base.where("projects.science_score > 0")
      .or(base.where(id: Package.scientific_publishing_project_ids))
    scope = scope.with_joss if cohort == "joss"
    scope = scope.where(joss_metadata: nil) if cohort == "non_joss"
    scope.where("projects.id % ? = ?", shard_count, shard)
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
