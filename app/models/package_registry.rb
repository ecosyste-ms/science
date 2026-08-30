class PackageRegistry < ApplicationRecord
  has_many :packages, dependent: :restrict_with_exception

  validates :name, :url, :ecosystem, :purl_type, presence: true
  validates :name, :url, uniqueness: { case_sensitive: false }

  before_validation :normalize_identifiers

  scope :defaults, -> { where(default: true) }

  def self.sync_from_ecosystems!(client: PackagesApiClient.new, limit: PackagesApiClient::MAX_REGISTRIES)
    records = client.registries(limit: limit)
    counts = { registries: records.length, created: 0, updated: 0 }

    transaction do
      records.each do |attributes|
        registry = where("lower(name) = ?", attributes.fetch("name").downcase).first_or_initialize
        created = registry.new_record?
        registry.assign_attributes(
          name: attributes.fetch("name"),
          url: normalized_url(attributes.fetch("url")),
          ecosystem: attributes.fetch("ecosystem"),
          purl_type: attributes.fetch("purl_type"),
          default: attributes.fetch("default", false),
          metadata: attributes["metadata"] || {},
          ecosystems_updated_at: attributes["updated_at"]
        )
        changed = registry.changed?
        registry.save! if changed
        counts[created ? :created : :updated] += 1 if created || changed
      end
    end

    counts
  end

  def self.for_dependency(ecosystem:, purl_type: nil, repository_url: nil)
    if repository_url.present?
      normalized = normalized_url(repository_url)
      return where("lower(url) = ?", normalized.downcase).first
    end

    if purl_type.present?
      default_url = Purl.default_registry(purl_type)
      if default_url.present?
        normalized = normalized_url(default_url)
        registry = where("lower(url) = ?", normalized.downcase).first
        return registry if registry
      end

      registry = defaults.where("lower(purl_type) = ?", purl_type.downcase).first
      return registry if registry
    end

    registry = defaults.where("lower(ecosystem) = ?", ecosystem.to_s.downcase).first
    return registry if registry

    default_url = Purl.default_registry(ecosystem)
    return if default_url.blank?

    normalized = normalized_url(default_url)
    where("lower(url) = ?", normalized.downcase).first
  end

  def self.normalized_url(value)
    value.to_s.strip.sub(%r{/+\z}, "")
  end

  def normalize_identifiers
    self.url = self.class.normalized_url(url) if url.present?
    self.ecosystem = ecosystem.to_s.strip.downcase if ecosystem.present?
    self.purl_type = purl_type.to_s.strip.downcase if purl_type.present?
  end
end
