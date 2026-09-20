class Release < ApplicationRecord
  FORGE_ATTRIBUTES = %w[
    uuid tag_name target_commitish name body draft prerelease immutable
    published_at author assets last_synced_at html_url tag_url release_url
  ].freeze
  TAG_ATTRIBUTES = {
    "name" => "tag_name", "sha" => "tag_sha", "kind" => "tag_kind",
    "published_at" => "tag_published_at", "html_url" => "tag_html_url",
    "download_url" => "download_url", "purl" => "purl",
    "tag_url" => "tag_url", "manifests_url" => "manifests_url"
  }.freeze

  class IdentityConflict < StandardError; end

  belongs_to :project

  scope :recent, -> {
    order(Arel.sql("COALESCE(releases.published_at, releases.tag_published_at) DESC NULLS LAST, releases.id DESC"))
  }

  def self.sync_attributes(attributes)
    attributes = attributes.stringify_keys
    result = attributes.slice(*FORGE_ATTRIBUTES)
    result["uuid"] = result["uuid"].to_s.presence if result.key?("uuid")
    result["forge_created_at"] = attributes["created_at"] if attributes.key?("created_at")
    result
  end

  def self.import!(project, source, payload)
    raise ArgumentError, "release metadata must be an object" unless payload.is_a?(Hash)

    attributes = case source
    when "tags"
      payload.slice(*TAG_ATTRIBUTES.keys).transform_keys { |key| TAG_ATTRIBUTES.fetch(key) }
    when "releases"
      sync_attributes(payload)
    else
      raise ArgumentError, "unknown release source"
    end
    tag_name = attributes["tag_name"]
    raise ArgumentError, "release metadata must include a tag name" unless tag_name.is_a?(String) && tag_name.present?
    if source == "releases" && attributes["uuid"].blank?
      raise ArgumentError, "forge release must include a UUID"
    end

    matches = project.releases.where(tag_name: tag_name).limit(2).to_a
    raise IdentityConflict, "duplicate tag #{tag_name}" if matches.length > 1

    release = matches.first || project.releases.new(tag_name: tag_name)
    if source == "releases"
      by_uuid = project.releases.where(uuid: attributes.fetch("uuid")).limit(2).to_a
      if by_uuid.any? { |record| record.id != release.id } ||
          (release.uuid.present? && release.uuid != attributes["uuid"])
        raise IdentityConflict, "conflicting release UUID for tag #{tag_name}"
      end
    end
    release.assign_attributes(attributes)
    fetched_at = source == "tags" ? :tag_fetched_at : :release_fetched_at
    if release.changes.except("last_synced_at").any? || release.public_send(fetched_at).nil?
      release.public_send("#{fetched_at}=", Time.current)
      release.save!
    end
    release
  end

  def title
    name.presence || tag_name
  end

  def forge_release?
    uuid.present?
  end

  def source_url
    html_url.presence || tag_html_url.presence
  end
end
