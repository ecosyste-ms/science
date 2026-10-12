class HuggingFacePackageImport
  MAX_PACKAGES = 500

  attr_reader :purls, :registry, :client, :dry_run, :input_count

  def initialize(purls:, dry_run: true, client: PackagesApiClient.new)
    unless purls.is_a?(Array) && purls.length.between?(1, MAX_PACKAGES)
      raise ArgumentError, "Expected 1 to #{MAX_PACKAGES} Hugging Face PURLs"
    end
    @input_count = purls.length
    @purls = purls.map { |value| normalize_purl(value) }.uniq
    @dry_run = dry_run
    @client = client
    registries = PackageRegistry.where("lower(name) = ?", "huggingface.co").limit(2).to_a
    unless registries.one? && registries.first.purl_type.casecmp?("huggingface")
      raise ArgumentError, "Sync the huggingface.co package registry before importing models"
    end
    @registry = registries.first
  end

  def call
    results = purls.map { |purl| import_package(purl) }
    { dry_run: dry_run, input_count: input_count, selected: purls.length,
      counts: results.group_by { |result| result.fetch(:status) }.transform_values(&:length),
      packages: results }
  end

  def normalize_purl(value)
    unless value.is_a?(String) && value.length.between?(1, 2_000)
      raise ArgumentError, "Expected a nonempty Hugging Face PURL"
    end
    parsed = Purl.parse(value.strip)
    unless parsed.type == "huggingface" && parsed.namespace.present? &&
        !parsed.namespace.include?("/") && !parsed.name.include?("/") && parsed.qualifiers.blank?
      raise ArgumentError, "Expected a Hugging Face model PURL without qualifiers: #{value}"
    end
    parsed.with(version: nil, subpath: nil).to_s
  rescue Purl::Error => error
    raise ArgumentError, error.message
  end

  def import_package(purl)
    existing = Package.find_by(purl: purl)
    return existing_result(existing, purl) if existing

    records = client.package_lookup(purl: purl)
    if records.empty?
      return { purl: purl, status: "missing", retryable: true,
        reason: "Not yet available in Packages; retry this PURL later" }
    end
    if records.many?
      return { purl: purl, status: "ambiguous", retryable: false,
        reason: "Packages returned #{records.length} records" }
    end
    record = records.sole
    validate_record!(record, purl)
    result = nil
    Package.transaction(requires_new: true) do
      existing = Package.find_by(purl: purl)
      if existing
        result = existing_result(existing, purl)
        next
      end
      package = registry.packages.new(name: record.fetch("name"), purl: purl)
      conflict = PackageMetadataSync.new(client: client).local_identity_conflict(package, record)
      raise ArgumentError, conflict if conflict
      unless package.valid?
        raise ArgumentError, package.errors.full_messages.join(", ")
      end
      if dry_run
        result = { purl: purl, status: "would_create", name: package.name }
      else
        package.record_ecosystems_match!(record)
        result = { purl: purl, status: "created", package_id: package.id, name: package.name }
      end
    end
    result
  rescue PackagesApiClient::RequestError => error
    { purl: purl, status: "error", retryable: true, reason: error.message }
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    { purl: purl, status: "conflict", retryable: false, reason: error.message }
  end

  def existing_result(package, purl)
    unless package.package_registry_id == registry.id
      raise ArgumentError, "PURL already belongs to a different registry"
    end
    { purl: purl, status: "existing", package_id: package.id, name: package.name }
  end

  def validate_record!(record, purl)
    unless record.is_a?(Hash) && record["registry"].is_a?(Hash) &&
        record.dig("registry", "name").to_s.casecmp?(registry.name) &&
        Integer(record["id"], exception: false)&.positive? && normalize_purl(record["purl"]) == purl
      raise ArgumentError, "Packages returned a different or invalid package identity"
    end
    parsed = Purl.parse(purl)
    unless record["name"] == "#{parsed.namespace}/#{parsed.name}"
      raise ArgumentError, "Packages returned a name that does not match the PURL"
    end
  end
end
