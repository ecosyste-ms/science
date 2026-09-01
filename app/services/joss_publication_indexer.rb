require "digest"

class JossPublicationIndexer
  CURRENT_VERSION = 1
  DEFAULT_LIMIT = 250
  MAX_LIMIT = 1_000
  UPSERT_BATCH_SIZE = 1_000
  SOURCE = "joss"
  CANDIDATE_SQL = <<~SQL.squish.freeze
    joss_metadata IS NOT NULL
    OR joss_publication_source_digest IS NOT NULL
  SQL
  AUTHOR_UPDATE_COLUMNS = %i[
    display_name
    given_names
    family_names
    email
    orcid
    affiliation
    source_path
    source_digest
    raw_data
    author_id
    author_match_kind
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
      .where(CANDIDATE_SQL)
      .where(
        "joss_publication_indexed_at IS NULL " \
          "OR joss_publication_index_version IS DISTINCT FROM ?",
        CURRENT_VERSION
      )
    unless retry_errors
      scope = scope.where(
        "joss_publication_index_error IS NULL " \
          "OR joss_publication_index_version IS DISTINCT FROM ?",
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
      papers: 0,
      authors: 0,
      editors: 0,
    }
  end

  def self.merge_counts!(result, counts)
    empty_counts.except(:indexed, :failed, :skipped).each_key do |key|
      result[key] += counts.fetch(key)
    end
  end

  def sync!
    metadata = project.joss_metadata
    @attempted_source_digest = digest_for(metadata)
    publication = publication_for(metadata, attempted_source_digest)
    rows = publication&.fetch(:authors, []) || []
    counts = counts_for(publication, rows)

    project.with_lock do
      return counts.merge(indexed: false) unless current_source?
      return counts.merge(indexed: false) if already_indexed?
      if project.joss_publication_index_error.present? &&
          project.joss_publication_index_version == CURRENT_VERSION &&
          !retry_errors
        return counts.merge(indexed: false)
      end

      if publication
        paper = upsert_paper!(publication)
        mention = project.mentions.where(paper: paper).order(:id).first
        mention ||= project.mentions.create!(
          paper: paper,
          created_by_source: SOURCE
        )
        upsert_mention_source!(mention, publication)
        upsert_authors!(paper, rows)
        remove_stale_sources!(publication.fetch(:doi))
      else
        remove_stale_sources!
      end

      now = Time.current
      project.update_columns(
        joss_publication_indexed_at: now,
        joss_publication_index_error: nil,
        joss_publication_index_version: CURRENT_VERSION,
        joss_publication_source_digest: attempted_source_digest,
        author_identities_indexed_at: nil,
        author_identities_index_error: nil,
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
        joss_publication_indexed_at: nil,
        joss_publication_index_error: message,
        joss_publication_index_version: CURRENT_VERSION,
        joss_publication_source_digest: attempted_source_digest,
        updated_at: Time.current
      )
      recorded = true
    end

    Rails.logger.error(
      "JOSS publication indexing failed for project #{project.id}: #{message}"
    ) if recorded
    recorded
  end

  def publication_for(metadata, source_digest)
    return if metadata.blank?
    raise ArgumentError, "joss_metadata must be an object" unless metadata.is_a?(Hash)

    doi = Project.extract_dois(metadata["doi"]).first&.downcase
    raise ArgumentError, "JOSS publication DOI is missing or invalid" if doi.blank?

    authors = metadata["authors"] || []
    raise ArgumentError, "JOSS authors must be an array" unless authors.is_a?(Array)

    rows = authors.each_with_index.map do |actor, index|
      raise ArgumentError, "authors[#{index}] must be an object" unless actor.is_a?(Hash)

      author_row(
        actor,
        role: "author",
        position: index + 1,
        source_path: "authors[#{index}]",
        source_digest: source_digest
      )
    end
    if metadata["editor_name"].present?
      rows << author_row(
        {
          "name" => metadata["editor_name"],
          "orcid" => metadata["editor_orcid"],
        },
        role: "editor",
        position: 1,
        source_path: "editor",
        source_digest: source_digest
      )
    end

    {
      doi: doi,
      title: normalized_value(metadata["title"]),
      publication_date: publication_date(metadata),
      urls: publication_urls(metadata, doi),
      raw_data: json_safe(metadata),
      authors: rows,
      source_digest: source_digest,
    }
  end

  def author_row(actor, role:, position:, source_path:, source_digest:)
    given_names = normalized_value(actor["given_name"] || actor["given_names"])
    middle_names = normalized_value(actor["middle_name"] || actor["middle_names"])
    family_names = normalized_value(actor["last_name"] || actor["family_names"])
    display_name = normalized_value(actor["name"]) ||
      [given_names, middle_names, family_names].compact_blank.join(" ").presence

    {
      source: SOURCE,
      role: role,
      position: position,
      display_name: display_name,
      given_names: [given_names, middle_names].compact_blank.join(" ").presence,
      family_names: family_names,
      email: normalized_value(actor["email"])&.downcase,
      orcid: Project.extract_orcids(actor["orcid"]).first,
      affiliation: normalized_value(actor["affiliation"]),
      source_path: source_path,
      source_digest: source_digest,
      raw_data: json_safe(actor),
      author_id: nil,
      author_match_kind: nil,
    }
  end

  def upsert_paper!(publication)
    doi = publication.fetch(:doi)
    paper = Paper.find_by(doi: doi)
    paper ||= Paper.where("LOWER(doi) = ?", doi).order(:id).first
    paper ||= Paper.new(doi: doi)
    paper.title = publication.fetch(:title) if publication.fetch(:title).present?
    if publication.fetch(:publication_date).present?
      paper.publication_date = publication.fetch(:publication_date)
    end
    paper.urls = (Array(paper.urls) + publication.fetch(:urls)).uniq
    paper.last_synced_at = Time.current
    paper.save!
    paper
  end

  def upsert_mention_source!(mention, publication)
    MentionSource.upsert_all(
      [
        {
          mention_id: mention.id,
          source: SOURCE,
          source_identifier: publication.fetch(:doi),
          source_digest: publication.fetch(:source_digest),
          raw_data: publication.fetch(:raw_data),
        },
      ],
      unique_by: :index_mention_sources_on_mention_id_and_source,
      update_only: %i[source_identifier source_digest raw_data],
      record_timestamps: true
    )
  end

  def upsert_authors!(paper, rows)
    rows.each_slice(UPSERT_BATCH_SIZE) do |batch|
      PaperAuthor.upsert_all(
        batch.map { |row| row.merge(paper_id: paper.id) },
        unique_by: :index_paper_authors_on_snapshot_position,
        update_only: AUTHOR_UPDATE_COLUMNS,
        record_timestamps: true
      )
    end
    paper.paper_authors
      .where(source: SOURCE)
      .where.not(source_digest: attempted_source_digest)
      .delete_all
  end

  def remove_stale_sources!(current_identifier = nil)
    scope = project.mention_sources.where(source: SOURCE)
    scope = scope.where.not(source_identifier: current_identifier) if current_identifier
    mentions = Mention.where(id: scope.select(:mention_id)).to_a
    paper_ids = scope.joins(:mention).distinct.pluck("mentions.paper_id")
    scope.delete_all
    mentions.each do |mention|
      next unless mention.created_by_source == SOURCE
      mention.destroy! unless mention.sources.exists?
    end
    paper_ids.each do |paper_id|
      next if MentionSource.joins(:mention)
        .where(source: SOURCE, mentions: { paper_id: paper_id })
        .exists?

      PaperAuthor.where(paper_id: paper_id, source: SOURCE).delete_all
    end
  end

  def publication_date(metadata)
    value = metadata["published_at"]
    return Time.zone.parse(value.to_s) if value.present?

    year = Integer(metadata["year"], exception: false)
    Time.zone.local(year, 1, 1) if year&.positive?
  rescue ArgumentError
    nil
  end

  def publication_urls(metadata, doi)
    [
      "https://doi.org/#{doi}",
      metadata["pdf_url"],
      metadata["paper_review"],
    ].filter_map { |value| normalized_value(value) }.uniq
  end

  def normalized_value(value)
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

  def counts_for(publication, rows)
    {
      papers: publication ? 1 : 0,
      authors: rows.count { |row| row.fetch(:role) == "author" },
      editors: rows.count { |row| row.fetch(:role) == "editor" },
    }
  end

  def digest_for(metadata)
    Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(canonical_value(metadata)))
  end

  def canonical_value(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, result|
        result[key] = canonical_value(value[key])
      end
    when Array
      value.map { |item| canonical_value(item) }
    else
      value
    end
  end

  def current_source?
    digest_for(project.joss_metadata) == attempted_source_digest
  end

  def already_indexed?
    project.joss_publication_indexed_at.present? &&
      project.joss_publication_index_version == CURRENT_VERSION &&
      project.joss_publication_source_digest == attempted_source_digest
  end
end
