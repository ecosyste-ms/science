class PackageVersion < ApplicationRecord
  SOURCE_ATTRIBUTES = %w[
    number published_at licenses integrity status immutable download_url
    registry_url documentation_url purl metadata related_tag
  ].freeze

  class IdentityConflict < StandardError; end

  belongs_to :package
  belongs_to :release, optional: true

  validates :number, :ecosystems_id, :fetched_at, presence: true

  scope :recent, -> { order(Arel.sql("published_at DESC NULLS LAST, id DESC")) }

  def self.import!(package, payload)
    raise ArgumentError, "version metadata must be an object" unless payload.is_a?(Hash)

    source_id = Integer(payload["id"].to_s, exception: false)
    number = payload["number"]
    raise ArgumentError, "version must include a positive ID" unless source_id&.positive?
    unless number.is_a?(String) && number.present?
      raise ArgumentError, "version must include a number"
    end

    by_id = package.package_versions.find_by(ecosystems_id: source_id)
    by_number = package.package_versions.where("lower(number) = lower(?)", number).first
    if (by_id && by_number && by_id.id != by_number.id) ||
        (by_number && by_number.ecosystems_id != source_id) ||
        (by_id && !by_id.number.casecmp?(number))
      raise IdentityConflict, "conflicting version ID #{source_id} for #{number}"
    end

    version = by_id || by_number || package.package_versions.new(ecosystems_id: source_id)
    attributes = payload.slice(*SOURCE_ATTRIBUTES)
    attributes["metadata"] ||= {} if attributes.key?("metadata")
    attributes["ecosystems_created_at"] = payload["created_at"] if payload.key?("created_at")
    attributes["ecosystems_updated_at"] = payload["updated_at"] if payload.key?("updated_at")
    version.assign_attributes(attributes)
    version.match_release
    if version.changed? || version.fetched_at.nil?
      version.fetched_at = Time.current
      version.save!
    end
    version
  end

  def match_release
    tag_name = related_tag.is_a?(Hash) && related_tag["name"]
    matches = if tag_name.is_a?(String) && tag_name.present? && package.published_by_project_id
      Release.where(project_id: package.published_by_project_id, tag_name: tag_name).limit(2).to_a
    else
      []
    end
    self.release = matches.one? ? matches.first : nil
    self.release_match_method = release ? "packages_related_tag" : nil
  end
end
