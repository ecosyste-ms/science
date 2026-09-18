class PackageMetadataSync
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 100
  REFRESH_AFTER = 30.days
  STOPPED_STATUSES = %w[missing unavailable ambiguous failed].freeze
  SKIPPED_METADATA_IDENTITIES = {
    "github actions" => %w[
      google/clusterfuzzlite/actions/build_fuzzers
      google/clusterfuzzlite/actions/run_fuzzers
    ],
  }.freeze

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
      record_sync_error!(package, error, result)
    ensure
      package&.release_ecosystems_sync! if claimed
    end

    result
  end

  def candidates(now: Time.current)
    dependency_counts = ProjectDependency.where(direct: true)
      .where.not(package_id: nil)
      .group(:package_id)
      .select(
        :package_id,
        "COUNT(*) AS project_dependents_count"
      )
    transient_retries = Package.where(ecosystems_sync_status: "transient_error")
      .where("ecosystems_retry_at <= ?", now)
    due = Package.where(ecosystems_checked_at: nil)
      .or(transient_retries)
      .or(Package.where(
        "ecosystems_sync_status = ? AND ecosystems_checked_at < ?",
        "matched",
        now - REFRESH_AFTER
      ))
    if retry_stopped
      due = due.or(Package.where(ecosystems_sync_status: STOPPED_STATUSES))
    end
    due = exclude_skipped_metadata_identities(due)

    due.joins(
      "LEFT JOIN (#{dependency_counts.to_sql}) package_usage_counts " \
      "ON package_usage_counts.package_id = packages.id"
    )
      .includes(:package_registry)
      .where(
        "ecosystems_sync_started_at IS NULL OR ecosystems_sync_started_at < ?",
        now - 30.minutes
      )
      .order(
        Arel.sql(
          "COALESCE(package_usage_counts.project_dependents_count, 0) DESC"
        ),
        Arel.sql("COALESCE(packages.ecosystems_retry_at, packages.created_at)"),
        :id
      )
      .limit(limit)
  end

  def exclude_skipped_metadata_identities(scope)
    SKIPPED_METADATA_IDENTITIES.reduce(scope) do |remaining, (registry_name, names)|
      registry_ids = PackageRegistry
        .where("LOWER(name) = ?", registry_name.downcase)
        .select(:id)
      skipped_ids = Package
        .where(package_registry_id: registry_ids)
        .where("LOWER(name) IN (?)", names.map(&:downcase))
        .select(:id)
      remaining.where.not(id: skipped_ids)
    end
  end

  def sync_package!(package)
    records = if package.purl.present?
      client.package_lookup(purl: metadata_lookup_purl(package))
    else
      client.package_lookup(
        registry_name: package.package_registry.name,
        ecosystem: package.package_registry.ecosystem,
        name: metadata_lookup_name(package)
      )
    end
    matches = records.select do |record|
      record.dig("registry", "name").to_s.casecmp?(package.package_registry.name)
    end

    return package.record_ecosystems_missing! if matches.empty?
    return package.record_ecosystems_ambiguous!(matches.length) if matches.many?

    record = matches.sole
    conflict = local_identity_conflict(package, record)
    return package.record_ecosystems_conflict!(conflict) if conflict

    package.record_ecosystems_match!(record)
  end

  def metadata_lookup_purl(package)
    return package.purl unless nuget_package?(package)

    parsed = Purl.parse(package.purl)
    parsed.with(name: parsed.name.downcase).to_s
  end

  def metadata_lookup_name(package)
    return package.name unless nuget_package?(package)

    package.name.downcase
  end

  def nuget_package?(package)
    package.package_registry.purl_type.to_s.casecmp?("nuget")
  end

  def local_identity_conflict(package, record)
    ecosystems_id = Integer(record["id"], exception: false)
    if ecosystems_id
      package_id = Package.where(ecosystems_id: ecosystems_id)
        .where.not(id: package.id)
        .pick(:id)
      if package_id
        return "ecosystems package #{ecosystems_id} already belongs to package #{package_id}"
      end
    end

    purl = record["purl"].presence
    return unless purl

    normalized_purl = Purl.parse(purl).with(version: nil, subpath: nil).to_s
    package_id = Package.where(purl: normalized_purl)
      .where.not(id: package.id)
      .pick(:id)
    if package_id
      "PURL #{normalized_purl} already belongs to package #{package_id}"
    end
  rescue Purl::Error => error
    "invalid upstream PURL #{purl.inspect}: #{error.message}"
  end

  def record_sync_error!(package, error, result)
    package.reload
    outcome = package.record_ecosystems_error!(error)
    result[outcome] += 1
    Rails.logger.error(
      "Package metadata sync failed for package #{package.id}: " \
      "#{error.class}: #{error.message}"
    )
  rescue StandardError => recording_error
    result[:failed] += 1
    Rails.logger.error(
      "Package metadata sync error could not be recorded for package " \
      "#{package&.id}: #{recording_error.class}: #{recording_error.message}; " \
      "original error: #{error.class}: #{error.message}"
    )
  end
end
