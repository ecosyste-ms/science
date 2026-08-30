class PackageMetadataSync
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 100
  REFRESH_AFTER = 30.days
  STOPPED_STATUSES = %w[unavailable ambiguous failed].freeze

  attr_reader :client, :limit, :retry_stopped

  def initialize(
    client: PackagesApiClient.new,
    limit: DEFAULT_LIMIT,
    retry_stopped: false
  )
    @client = client
    @limit = Integer(limit, exception: false)
    unless @limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end
    @retry_stopped = retry_stopped
  end

  def self.sync_batch!(
    client: PackagesApiClient.new,
    limit: DEFAULT_LIMIT,
    retry_stopped: false
  )
    new(
      client: client,
      limit: limit,
      retry_stopped: retry_stopped
    ).sync_batch!
  end

  def sync_batch!
    packages = candidates.to_a
    result = {
      selected: packages.length,
      matched: 0,
      missing: 0,
      unavailable: 0,
      ambiguous: 0,
      transient_error: 0,
      failed: 0,
      skipped: 0,
    }

    packages.each do |package|
      claimed = false
      unless package.claim_ecosystems_sync!
        result[:skipped] += 1
        next
      end
      claimed = true

      outcome = sync_package!(package)
      result[outcome] += 1
    rescue StandardError => error
      outcome = package.record_ecosystems_error!(error)
      result[outcome] += 1
      Rails.logger.error(
        "Package metadata sync failed for package #{package.id}: " \
        "#{error.class}: #{error.message}"
      )
    ensure
      package&.release_ecosystems_sync! if claimed
    end

    result
  end

  def candidates(now: Time.current)
    due = Package.where(ecosystems_checked_at: nil)
      .or(Package.where("ecosystems_retry_at <= ?", now))
      .or(Package.where(
        "ecosystems_sync_status = ? AND ecosystems_checked_at < ?",
        "matched",
        now - REFRESH_AFTER
      ))
    if retry_stopped
      due = due.or(Package.where(ecosystems_sync_status: STOPPED_STATUSES))
    end

    due.includes(:package_registry)
      .where(
        "ecosystems_sync_started_at IS NULL OR ecosystems_sync_started_at < ?",
        now - 30.minutes
      )
      .order(Arel.sql("COALESCE(ecosystems_retry_at, created_at), id"))
      .limit(limit)
  end

  def sync_package!(package)
    records = if package.purl.present?
      client.package_lookup(purl: package.purl)
    else
      client.package_lookup(
        registry_name: package.package_registry.name,
        ecosystem: package.package_registry.ecosystem,
        name: package.name
      )
    end
    matches = records.select do |record|
      record.dig("registry", "name").to_s.casecmp?(package.package_registry.name)
    end

    return package.record_ecosystems_missing! if matches.empty?
    return package.record_ecosystems_ambiguous!(matches.length) if matches.many?

    package.record_ecosystems_match!(matches.sole)
  end
end
