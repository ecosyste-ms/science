class ProjectDependencyResolver
  DEFAULT_LIMIT = 1_000
  MAX_LIMIT = 5_000

  class ResolutionError < StandardError; end

  attr_reader :limit, :retry_errors

  def initialize(limit: DEFAULT_LIMIT, retry_errors: false)
    @limit = Integer(limit, exception: false)
    unless @limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end

    @retry_errors = retry_errors
  end

  def self.resolve_batch!(limit: DEFAULT_LIMIT, retry_errors: false)
    new(limit: limit, retry_errors: retry_errors).resolve_batch!
  end

  def resolve_batch!
    if PackageRegistry.none?
      raise ResolutionError, "package registries must be synced before resolving dependencies"
    end

    selected_identities = identities
    result = {
      selected: selected_identities.length,
      resolved: 0,
      failed: 0,
      skipped: 0,
      dependency_rows: 0,
      packages_created: 0,
    }

    selected_identities.each do |identity|
      begin
        outcome = resolve_identity!(identity)
        unless outcome.fetch(:resolved)
          result[:skipped] += 1
          next
        end

        result[:resolved] += 1
        result[:dependency_rows] += outcome.fetch(:dependency_rows)
        result[:packages_created] += 1 if outcome.fetch(:package_created)
      rescue StandardError => error
        message = "#{error.class}: #{error.message}".truncate(2_000)
        record_error!(identity, message)
        Rails.logger.error("Package resolution failed for #{identity.inspect}: #{message}")
        result[:failed] += 1
      end
    end

    result
  end

  def identities
    scope = candidate_scope
    purls = scope
      .where.not(purl: nil)
      .distinct
      .order(:purl)
      .limit(limit)
      .pluck(:purl)
    selected = purls.map { |purl| { purl: purl } }
    remaining = limit - selected.length
    return selected if remaining.zero?

    coordinates = scope
      .where(purl: nil)
      .distinct
      .order(:ecosystem, :package_name)
      .limit(remaining)
      .pluck(:ecosystem, :package_name)
    selected + coordinates.map do |ecosystem, package_name|
      { ecosystem: ecosystem, package_name: package_name }
    end
  end

  def candidate_scope
    scope = ProjectDependency.unresolved
    scope = scope.where(package_resolution_attempted_at: nil) unless retry_errors
    scope
  end

  def resolve_identity!(identity)
    outcome = nil

    ProjectDependency.transaction do
      dependencies = identity_scope(identity).lock.order(:id).to_a
      if dependencies.empty?
        outcome = { resolved: false, dependency_rows: 0, package_created: false }
        next
      end

      attributes = package_attributes(dependencies.first)
      package, created = find_or_create_package!(attributes)
      dependencies.each { |dependency| link_dependency!(dependency, package) }
      outcome = {
        resolved: true,
        dependency_rows: dependencies.length,
        package_created: created,
      }
    end

    outcome
  end

  def identity_scope(identity)
    scope = ProjectDependency.unresolved
    if identity[:purl].present?
      scope.where(purl: identity.fetch(:purl))
    else
      scope.where(
        purl: nil,
        ecosystem: identity.fetch(:ecosystem),
        package_name: identity.fetch(:package_name)
      )
    end
  end

  def package_attributes(dependency)
    parsed = Purl.parse(dependency.purl) if dependency.purl.present?
    explicit_registry_url = parsed&.qualifiers&.fetch("repository_url", nil)
    package_name = dependency.package_name
    if parsed&.type == "docker" && explicit_registry_url.blank?
      coordinate = [parsed.namespace, parsed.name].compact.join("/")
      explicit_registry_url, package_name = docker_coordinate(coordinate)
      parsed = nil if explicit_registry_url.present? || package_name != coordinate
    elsif parsed.nil? && dependency.ecosystem.casecmp?("docker")
      explicit_registry_url, package_name = docker_coordinate(package_name)
    end
    registry = PackageRegistry.for_dependency(
      ecosystem: dependency.ecosystem,
      purl_type: parsed&.type,
      repository_url: explicit_registry_url
    )
    unless registry
      label = explicit_registry_url.presence || parsed&.type || dependency.ecosystem
      raise ResolutionError, "no package registry for #{label}"
    end

    parsed ||= purl_from_coordinate(
      registry,
      package_name,
      repository_url: explicit_registry_url
    )
    {
      package_registry: registry,
      name: parsed ? package_name_from_purl(parsed) : package_name,
      namespace: parsed&.namespace,
      purl: parsed&.to_s,
    }
  rescue Purl::Error => error
    raise ResolutionError, error.message
  end

  def purl_from_coordinate(registry, package_name, repository_url: nil)
    type = registry.purl_type
    return unless Purl.known_type?(type)

    namespace, name = coordinate_parts(type, package_name)
    qualifiers = if repository_url.present?
      { "repository_url" => repository_url }
    end
    Purl::PackageURL.new(
      type: type,
      namespace: namespace,
      name: name,
      qualifiers: qualifiers
    )
  end

  def coordinate_parts(type, package_name)
    if type == "maven"
      return package_name.split(":", 2)
    end

    config = Purl.type_config(type) || {}
    namespace_supported = config["namespace_requirement"] == "required" ||
      config.dig("registry_config", "components", "namespace") == true
    if (type == "docker" || namespace_supported) && package_name.include?("/")
      parts = package_name.rpartition("/")
      return [parts.first, parts.last]
    end

    [nil, package_name]
  end

  def docker_coordinate(package_name)
    parts = package_name.split("/")
    return [nil, package_name] if parts.length < 2

    hostname = parts.first.downcase
    if %w[docker.io index.docker.io registry-1.docker.io].include?(hostname)
      return [nil, parts.drop(1).join("/")]
    end
    return [nil, package_name] unless hostname == "localhost" || hostname.include?(".") || hostname.include?(":")

    ["https://#{parts.first}", parts.drop(1).join("/")]
  end

  def package_name_from_purl(purl)
    namespace = purl.namespace
    namespace = "library" if purl.type == "docker" && namespace.blank?
    return purl.name if namespace.blank?

    separator = purl.type == "maven" ? ":" : "/"
    [namespace, purl.name].join(separator)
  end

  def find_or_create_package!(attributes)
    package = if attributes[:purl].present?
      Package.find_by(purl: attributes.fetch(:purl))
    end
    package ||= Package.find_by(
      package_registry: attributes.fetch(:package_registry),
      name: attributes.fetch(:name)
    )

    if package
      if package.package_registry != attributes.fetch(:package_registry)
        raise ResolutionError, "package PURL belongs to a different registry"
      end
      if package.purl.present? && attributes[:purl].present? && package.purl != attributes[:purl]
        raise ResolutionError, "package registry and name already use a different PURL"
      end

      updates = {}
      updates[:purl] = attributes[:purl] if package.purl.nil? && attributes[:purl].present?
      updates[:namespace] = attributes[:namespace] if package.namespace.nil? && attributes[:namespace].present?
      package.update!(updates) if updates.any?
      return [package, false]
    end

    package = nil
    Package.transaction(requires_new: true) do
      package = Package.create!(attributes)
    end
    [package, true]
  rescue ActiveRecord::RecordNotUnique
    package = if attributes[:purl].present?
      Package.find_by(purl: attributes.fetch(:purl))
    end
    package ||= Package.find_by!(
      package_registry: attributes.fetch(:package_registry),
      name: attributes.fetch(:name)
    )
    [package, false]
  end

  def link_dependency!(dependency, package)
    existing = ProjectDependency.where(
      project_id: dependency.project_id,
      package_id: package.id
    ).where.not(id: dependency.id).first

    if existing
      existing.update!(
        purl: existing.purl.presence || dependency.purl,
        direct: existing.direct? || dependency.direct?,
        metadata: merged_metadata(existing.metadata, dependency.metadata),
        package_resolution_attempted_at: Time.current,
        package_resolution_error: nil
      )
      dependency.destroy!
      return
    end

    dependency.update!(
      package: package,
      package_resolution_attempted_at: Time.current,
      package_resolution_error: nil
    )
  end

  def merged_metadata(first, second)
    merged = first.deep_dup
    occurrences = Array(first["occurrences"]) + Array(second["occurrences"])
    merged["occurrences"] = occurrences.uniq if occurrences.any?
    merged["source"] ||= second["source"]
    merged
  end

  def record_error!(identity, message)
    identity_scope(identity).update_all(
      package_resolution_attempted_at: Time.current,
      package_resolution_error: message,
      updated_at: Time.current
    )
  end
end
