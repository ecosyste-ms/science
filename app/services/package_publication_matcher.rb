class PackagePublicationMatcher
  DEFAULT_LIMIT = 500
  MAX_LIMIT = 1_000
  RETRY_AFTER = 30.days

  attr_reader :limit

  def initialize(limit: DEFAULT_LIMIT)
    @limit = Integer(limit, exception: false)
    unless @limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end
  end

  def self.match_batch!(limit: DEFAULT_LIMIT)
    new(limit: limit).match_batch!
  end

  def match_batch!
    packages = candidates.to_a
    normalized = packages.to_h do |package|
      [package, RepositoryUrlNormalizer.normalize(package.repository_url)]
    end
    matches = project_matches(normalized.values.compact.uniq)
    result = {
      selected: packages.length,
      matched: 0,
      discovered: 0,
      ambiguous: 0,
      invalid: 0,
    }

    normalized.each do |package, repository_url|
      if repository_url.nil?
        record_match!(package, [], "invalid repository URL")
        result[:invalid] += 1
        next
      end

      project_ids = matches[repository_url].uniq
      if project_ids.one?
        record_match!(package, project_ids)
        result[:matched] += 1
      elsif project_ids.empty?
        project = Project.create_or_find_by!(url: repository_url)
        record_match!(package, [project.id])
        if project.previously_new_record?
          project.sync_async
          result[:discovered] += 1
        else
          result[:matched] += 1
        end
      else
        record_match!(package, [], "multiple projects match repository URL")
        result[:ambiguous] += 1
      end
    end

    result
  end

  def candidates(now: Time.current)
    Package.where.not(repository_url: nil)
      .where.not(repository_url: "")
      .where(published_by_project_id: nil)
      .where(
        "repository_checked_at IS NULL OR repository_checked_at < ?",
        now - RETRY_AFTER
      )
      .order(Arel.sql("repository_checked_at NULLS FIRST, id"))
      .limit(limit)
  end

  def project_matches(repository_urls)
    return {} if repository_urls.empty?

    matches = Hash.new { |hash, key| hash[key] = [] }
    variants = repository_urls.flat_map do |url|
      [url, "#{url}/", "#{url}.git", "#{url}.git/"]
    end
    Project.where(url: variants).pluck(:id, :url).each do |project_id, url|
      normalized = RepositoryUrlNormalizer.normalize(url)
      matches[normalized] << project_id if normalized
    end

    ProjectRepositoryAlias.where(url: repository_urls)
      .pluck(:project_id, :url).each do |project_id, url|
      normalized = RepositoryUrlNormalizer.normalize(url)
      matches[normalized] << project_id if normalized
    end
    matches
  end

  def record_match!(package, project_ids, error = nil)
    package.update!(
      published_by_project_id: project_ids.first,
      repository_checked_at: Time.current,
      repository_match_error: error
    )
  end
end
