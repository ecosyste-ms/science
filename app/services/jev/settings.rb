class Jev::Settings
  def self.enabled?
    ENV["JEV_ENABLED"] == "true"
  end

  def self.integer(name, default, range)
    value = Integer(ENV.fetch("JEV_#{name}", default.to_s))
    raise ArgumentError, "JEV_#{name} outside allowed range" unless range.cover?(value)
    value
  end

  def self.decimal(name, default)
    value = BigDecimal(ENV.fetch("JEV_#{name}", default.to_s))
    raise ArgumentError, "JEV_#{name} must be positive" unless value.finite? && value.positive?
    value
  end

  def self.snapshot
    model = ENV.fetch("JEV_MODEL", "jev-1.14.0")
    raise ArgumentError, "JEV_MODEL must pin a Jev release" unless model.match?(/\Ajev-\d+\.\d+\.\d+\z/)
    { "model" => model,
      "batch_size" => integer("BATCH_SIZE", 500, 1..1000),
      "enrich_batch_size" => integer("ENRICH_BATCH_SIZE", 20, 1..100),
      "max_enrichments" => integer("MAX_ENRICHMENTS", 1000, 0..100_000),
      "max_attempts" => integer("MAX_ATTEMPTS", 3, 1..8),
      "retry_seconds" => integer("RETRY_SECONDS", 60, 1..3600),
      "rescan_days" => integer("RESCAN_DAYS", 7, 1..365),
      "external_sampling" => "owner_time", "owner_windows" => integer("OWNER_WINDOWS", 5000, 1..50_000) }
  end
end
