class PackageRankingMetadataNormalizer
  DEFAULT_LIMIT = 1_000
  MAX_LIMIT = 5_000

  attr_reader :limit

  def initialize(limit: DEFAULT_LIMIT)
    @limit = Integer(limit, exception: false)
    unless @limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end
  end

  def self.normalize_batch!(limit: DEFAULT_LIMIT)
    new(limit: limit).normalize_batch!
  end

  def normalize_batch!(now: Time.current)
    packages = candidates.to_a
    packages.each do |package|
      package.normalize_ranking_metadata(now: now)
      package.update_columns(
        general_dependent_repositories_count:
          package.general_dependent_repositories_count,
        dependent_repositories_top_percentage:
          package.dependent_repositories_top_percentage,
        average_top_percentage: package.average_top_percentage,
        ranking_metadata_normalized_at:
          package.ranking_metadata_normalized_at
      )
    end

    {
      selected: packages.length,
      normalized: packages.length,
    }
  end

  def candidates
    Package.where(ranking_metadata_normalized_at: nil)
      .order(:id)
      .limit(limit)
  end
end
