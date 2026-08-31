require "digest"

class ProjectCitationAuthorIndexer
  CURRENT_VERSION = 1
  DEFAULT_LIMIT = 250
  MAX_LIMIT = 1_000
  UPSERT_BATCH_SIZE = 1_000
  SOURCE = "citation_cff"
  CFF_PATTERN = /\A\s*cff-version:/
  CANDIDATE_SQL = <<~SQL.squish.freeze
    citation_file ~ '^[[:space:]]*cff-version:'
    OR citation_authors_source_digest IS NOT NULL
  SQL
  UPSERT_COLUMNS = %i[
    author_kind
    display_name
    given_names
    family_names
    email
    orcid
    affiliation
    source_path
    source_digest
    raw_data
  ].freeze

  attr_reader :project, :retry_errors, :attempted_source_digest

  def initialize(project, retry_errors: false)
    @project = project
    @retry_errors = retry_errors
  end

  def self.sync_batch!(limit: DEFAULT_LIMIT, retry_errors: false)
    limit = Integer(limit, exception: false)
    unless limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end

    scope = Project.visible
      .scientific
      .where(CANDIDATE_SQL)
      .where(
        "citation_authors_indexed_at IS NULL " \
          "OR citation_authors_index_version IS DISTINCT FROM ?",
        CURRENT_VERSION
      )
    unless retry_errors
      scope = scope.where(
        "citation_authors_index_error IS NULL " \
          "OR citation_authors_index_version IS DISTINCT FROM ?",
        CURRENT_VERSION
      )
    end
    project_ids = scope.order(:id).limit(limit).pluck(:id)
    result = empty_counts.merge(selected: project_ids.length)

    project_ids.each do |project_id|
      project = Project.find_by(id: project_id)
      next unless project

      indexer = new(project, retry_errors: retry_errors)
      begin
        counts = indexer.sync!
        result[:skipped] += 1 unless counts.fetch(:indexed)
        next unless counts.fetch(:indexed)

        result[:indexed] += 1
        merge_counts!(result, counts)
      rescue StandardError => error
        indexer.record_error!(error)
        result[:failed] += 1
      end
    end

    result
  end

  def self.empty_counts
    {
      indexed: 0,
      failed: 0,
      skipped: 0,
      authors: 0,
      software_people: 0,
      software_organizations: 0,
      publication_people: 0,
      publication_organizations: 0,
    }
  end

  def self.merge_counts!(result, counts)
    empty_counts.except(:indexed, :failed, :skipped).each_key do |key|
      result[key] += counts.fetch(key)
    end
  end

  def sync!
    content = project.citation_file
    @attempted_source_digest = digest_for(content)
    rows = rows_for(content, attempted_source_digest)
    counts = counts_for(rows)

    project.with_lock do
      return counts.merge(indexed: false) unless current_source?
      return counts.merge(indexed: false) if already_indexed?
      if project.citation_authors_index_error.present? &&
          project.citation_authors_index_version == CURRENT_VERSION &&
          !retry_errors
        return counts.merge(indexed: false)
      end

      now = Time.current
      rows.each_slice(UPSERT_BATCH_SIZE) do |batch|
        ProjectAuthor.upsert_all(
          batch.map { |row| row.merge(project_id: project.id) },
          unique_by: :index_project_authors_on_snapshot_position,
          update_only: UPSERT_COLUMNS,
          record_timestamps: true
        )
      end
      project.project_authors
        .where(source: SOURCE)
        .where.not(source_digest: attempted_source_digest)
        .delete_all
      project.update_columns(
        citation_authors_indexed_at: now,
        citation_authors_index_error: nil,
        citation_authors_index_version: CURRENT_VERSION,
        citation_authors_source_digest: attempted_source_digest,
        updated_at: now
      )
    end

    counts.merge(indexed: true)
  end

  def record_error!(error)
    message = "#{error.class}: #{error.message}".truncate(2_000)
    recorded = false

    project.with_lock do
      next unless current_source?

      project.update_columns(
        citation_authors_indexed_at: nil,
        citation_authors_index_error: message,
        citation_authors_index_version: CURRENT_VERSION,
        citation_authors_source_digest: attempted_source_digest,
        updated_at: Time.current
      )
      recorded = true
    end

    Rails.logger.error(
      "Citation author indexing failed for project #{project.id}: #{message}"
    ) if recorded
    recorded
  end

  def rows_for(content, source_digest)
    return [] unless content.to_s.match?(CFF_PATTERN)

    cff = CFF::Index.read(content)
    rows = actor_rows(
      cff.authors,
      authorship_kind: "software",
      source_path: "authors",
      source_digest: source_digest
    )
    preferred_citation = cff.preferred_citation
    if preferred_citation.respond_to?(:authors)
      rows.concat(
        actor_rows(
          preferred_citation.authors,
          authorship_kind: "preferred_citation",
          source_path: "preferred-citation.authors",
          source_digest: source_digest
        )
      )
    end
    rows
  end

  def actor_rows(actors, authorship_kind:, source_path:, source_digest:)
    unless actors.is_a?(Array)
      raise ArgumentError, "#{source_path} must be an array"
    end

    actors.each_with_index.map do |actor, index|
      unless actor.is_a?(CFF::Person) || actor.is_a?(CFF::Entity)
        raise ArgumentError, "#{source_path}[#{index}] must be a person or organization"
      end

      row_for(
        actor,
        authorship_kind: authorship_kind,
        position: index + 1,
        source_path: "#{source_path}[#{index}]",
        source_digest: source_digest
      )
    end
  end

  def row_for(actor, authorship_kind:, position:, source_path:, source_digest:)
    organization = actor.is_a?(CFF::Entity)
    given_names = organization ? nil : normalized_field(actor, :given_names)
    family_names = organization ? nil : normalized_field(actor, :family_names)
    {
      source: SOURCE,
      authorship_kind: authorship_kind,
      author_kind: organization ? "organization" : "person",
      position: position,
      display_name: display_name(actor, given_names, family_names),
      given_names: given_names,
      family_names: family_names,
      email: normalized_email(actor),
      orcid: organization ? nil : normalized_orcid(actor),
      affiliation: organization ? nil : normalized_field(actor, :affiliation),
      source_path: source_path,
      source_digest: source_digest,
      raw_data: json_safe(actor.fields),
    }
  end

  def display_name(actor, given_names, family_names)
    return normalized_field(actor, :name) if actor.is_a?(CFF::Entity)

    [
      given_names,
      normalized_field(actor, :name_particle),
      family_names,
      normalized_field(actor, :name_suffix),
    ].compact_blank.join(" ").presence || normalized_field(actor, :alias)
  end

  def normalized_email(actor)
    normalized_field(actor, :email)&.downcase
  end

  def normalized_orcid(actor)
    Project.extract_orcids(normalized_field(actor, :orcid)).first
  end

  def normalized_field(actor, field)
    value = actor.public_send(field)
    case value
    when Array
      value.filter_map { |item| item.to_s.strip.presence }.join("; ").presence
    when Hash
      nil
    else
      value.to_s.strip.presence
    end
  end

  def json_safe(value)
    JSON.parse(ActiveSupport::JSON.encode(value))
  end

  def counts_for(rows)
    counts = self.class.empty_counts.except(:indexed, :failed, :skipped)
    rows.each do |row|
      counts[:authors] += 1
      prefix = row.fetch(:authorship_kind) == "software" ? "software" : "publication"
      suffix = row.fetch(:author_kind) == "person" ? "people" : "organizations"
      counts["#{prefix}_#{suffix}".to_sym] += 1
    end
    counts
  end

  def digest_for(content)
    Digest::SHA256.hexdigest(content.to_s)
  end

  def current_source?
    digest_for(project.citation_file) == attempted_source_digest
  end

  def already_indexed?
    project.citation_authors_indexed_at.present? &&
      project.citation_authors_index_version == CURRENT_VERSION &&
      project.citation_authors_source_digest == attempted_source_digest
  end
end
