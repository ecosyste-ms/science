require "digest"
require "set"

class AuthorIdentityIndexer
  CURRENT_VERSION = 2
  DEFAULT_LIMIT = 250
  MAX_LIMIT = 1_000
  WRITE_BATCH_SIZE = 1_000
  LINK_SOURCE = "same_project_email"
  CANDIDATE_SQL = <<~SQL.squish.freeze
    citation_authors_source_digest IS NOT NULL
    OR contributors_source_digest IS NOT NULL
    OR joss_publication_source_digest IS NOT NULL
    OR author_identities_source_digest IS NOT NULL
  SQL

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
        "author_identities_indexed_at IS NULL " \
          "OR author_identities_index_version IS DISTINCT FROM ?",
        CURRENT_VERSION
      )
    unless retry_errors
      scope = scope.where(
        "author_identities_index_error IS NULL " \
          "OR author_identities_index_version IS DISTINCT FROM ?",
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
      author_observations: 0,
      linked_author_observations: 0,
      paper_author_observations: 0,
      linked_paper_author_observations: 0,
      account_observations: 0,
      linked_account_observations: 0,
      linked_contributors: 0,
      account_author_links: 0,
      ambiguous: 0,
    }
  end

  def self.merge_counts!(result, counts)
    empty_counts.except(:indexed, :failed, :skipped).each_key do |key|
      result[key] += counts.fetch(key)
    end
  end

  def sync!
    counts = self.class.empty_counts.except(:indexed, :failed, :skipped)

    project.with_lock do
      @attempted_source_digest = source_digest
      return counts.merge(indexed: false) if already_indexed?
      if project.author_identities_index_error.present? &&
          project.author_identities_index_version == CURRENT_VERSION &&
          !retry_errors
        return counts.merge(indexed: false)
      end

      project_authors = project.project_authors
        .where(author_kind: "person")
        .order(:id)
        .to_a
      project_contributors = project.project_contributors.order(:id).to_a
      paper_authors = joss_paper_authors.to_a
      counts[:author_observations] = project_authors.length
      counts[:paper_author_observations] = paper_authors.length

      author_assignments, author_ambiguities =
        AuthorObservationIdentityResolver.new(project_authors).resolve
      counts[:linked_author_observations] = author_assignments.length
      counts[:ambiguous] += author_ambiguities

      paper_author_assignments, paper_author_ambiguities =
        AuthorObservationIdentityResolver.new(paper_authors).resolve
      counts[:linked_paper_author_observations] = paper_author_assignments.length
      counts[:ambiguous] += paper_author_ambiguities

      account_assignments, account_observations, account_ambiguities =
        ProjectDeveloperAccountResolver.new(
          project,
          project_contributors
        ).resolve
      counts[:account_observations] = account_observations
      counts[:linked_account_observations] = account_assignments.length
      counts[:ambiguous] += account_ambiguities

      contributor_author_assignments, links = resolve_contributor_authors(
        project_authors,
        project_contributors,
        author_assignments,
        account_assignments
      )
      counts[:linked_contributors] = contributor_author_assignments.length
      counts[:account_author_links] = links.length

      apply_project_author_assignments!(project_authors, author_assignments)
      apply_paper_author_assignments!(paper_authors, paper_author_assignments)
      apply_project_contributor_assignments!(
        project_contributors,
        account_assignments,
        contributor_author_assignments
      )
      replace_account_author_links!(links)

      now = Time.current
      project.update_columns(
        author_identities_indexed_at: now,
        author_identities_index_error: nil,
        author_identities_index_version: CURRENT_VERSION,
        author_identities_source_digest: attempted_source_digest,
        updated_at: now
      )
    end

    counts.merge(indexed: true)
  end

  def record_error!(error)
    message = "#{error.class}: #{error.message}".truncate(2_000)
    recorded = false

    project.with_lock do
      next if attempted_source_digest.blank?
      next unless source_digest == attempted_source_digest

      project.update_columns(
        author_identities_indexed_at: nil,
        author_identities_index_error: message,
        author_identities_index_version: CURRENT_VERSION,
        author_identities_source_digest: attempted_source_digest,
        updated_at: Time.current
      )
      recorded = true
    end

    Rails.logger.error(
      "Author identity indexing failed for project #{project.id}: #{message}"
    ) if recorded
    recorded
  end

  def resolve_contributor_authors(
    project_authors,
    project_contributors,
    author_assignments,
    account_assignments
  )
    authors_by_email = {}
    project_authors.group_by { |project_author| project_author.email&.downcase }
      .each do |email, grouped|
        next if email.blank?

        resolved = grouped.filter_map do |project_author|
          author_assignments.dig(project_author.id, :author_id)
        end.uniq
        authors_by_email[email] = {
          author_id: resolved.first,
          project_author_id: grouped.find do |project_author|
            author_assignments.dig(project_author.id, :author_id) == resolved.first
          end&.id,
        } if resolved.one?
      end

    assignments = {}
    links = []
    non_person_account_ids = DeveloperAccount
      .left_joins(:owner)
      .where(id: account_assignments.values.pluck(:developer_account_id))
      .where(
        "developer_accounts.account_kind = :bot " \
          "OR lower(owners.kind) = :organization",
        bot: "bot",
        organization: "organization"
      )
      .pluck(:id)
      .to_set
    project_contributors.each do |contributor|
      next if contributor.account_kind == "bot" || contributor.email.blank?
      account_id = account_assignments.dig(contributor.id, :developer_account_id)
      next if non_person_account_ids.include?(account_id)

      author_match = authors_by_email[contributor.email.downcase]
      next unless author_match

      assignments[contributor.id] = {
        author_id: author_match.fetch(:author_id),
        match_kind: "same_project_email",
      }
      next unless account_id

      links << {
        author_id: author_match.fetch(:author_id),
        developer_account_id: account_id,
        project_id: project.id,
        project_author_id: author_match.fetch(:project_author_id),
        project_contributor_id: contributor.id,
        source: LINK_SOURCE,
        source_key: "project:#{project.id}:contributor:#{contributor.id}",
        matching_method: "exact_email",
        deterministic: true,
        confidence: nil,
        source_digest: attempted_source_digest,
        evidence: {
          "email_sha256" => Digest::SHA256.hexdigest(contributor.email.downcase),
        },
      }
    end
    [assignments, links]
  end

  def apply_project_author_assignments!(project_authors, assignments)
    ids = project_authors.map(&:id)
    ProjectAuthor.where(id: ids).update_all(author_id: nil, author_match_kind: nil) if ids.any?
    rows = assignments.map do |project_author_id, assignment|
      [project_author_id, assignment.fetch(:author_id), assignment.fetch(:match_kind)]
    end
    update_assignment_rows!(
      "project_authors",
      %w[author_id author_match_kind],
      rows
    )
  end

  def apply_paper_author_assignments!(paper_authors, assignments)
    ids = paper_authors.map(&:id)
    PaperAuthor.where(id: ids).update_all(
      author_id: nil,
      author_match_kind: nil
    ) if ids.any?
    rows = assignments.map do |paper_author_id, assignment|
      [paper_author_id, assignment.fetch(:author_id), assignment.fetch(:match_kind)]
    end
    update_assignment_rows!(
      "paper_authors",
      %w[author_id author_match_kind],
      rows,
      project_scoped: false
    )
  end

  def apply_project_contributor_assignments!(
    project_contributors,
    account_assignments,
    author_assignments
  )
    ids = project_contributors.map(&:id)
    if ids.any?
      ProjectContributor.where(id: ids).update_all(
        author_id: nil,
        author_match_kind: nil,
        developer_account_id: nil,
        developer_account_match_kind: nil
      )
    end
    rows = ids.filter_map do |contributor_id|
      account = account_assignments[contributor_id]
      author = author_assignments[contributor_id]
      next unless account || author

      [
        contributor_id,
        author&.fetch(:author_id),
        author&.fetch(:match_kind),
        account&.fetch(:developer_account_id),
        account&.fetch(:match_kind),
      ]
    end
    update_assignment_rows!(
      "project_contributors",
      %w[author_id author_match_kind developer_account_id developer_account_match_kind],
      rows
    )
  end

  def update_assignment_rows!(table, columns, rows, project_scoped: true)
    connection = ActiveRecord::Base.connection
    rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      values = batch.map do |row|
        "(#{row.map { |value| connection.quote(value) }.join(", ")})"
      end.join(", ")
      aliases = ["id", *columns].join(", ")
      assignments = columns.map do |column|
        cast = column.end_with?("_id") ? "::bigint" : "::varchar"
        "#{column} = assignment.#{column}#{cast}"
      end.join(", ")
      project_condition = project_scoped ?
        "AND record.project_id = #{connection.quote(project.id)}" : ""
      connection.execute(<<~SQL.squish)
        UPDATE #{connection.quote_table_name(table)} AS record
        SET #{assignments}
        FROM (VALUES #{values}) AS assignment(#{aliases})
        WHERE record.id = assignment.id::bigint
          #{project_condition}
      SQL
    end
  end

  def replace_account_author_links!(links)
    links.each_slice(WRITE_BATCH_SIZE) do |batch|
      AuthorDeveloperAccountLink.upsert_all(
        batch,
        unique_by: :index_author_account_links_on_source_key,
        update_only: %i[
          author_id
          developer_account_id
          project_id
          project_author_id
          project_contributor_id
          matching_method
          deterministic
          confidence
          source_digest
          evidence
        ],
        record_timestamps: true
      )
    end
    project.author_developer_account_links
      .where(source: LINK_SOURCE)
      .where.not(source_digest: attempted_source_digest)
      .delete_all
  end

  def source_digest
    author_rows = project.project_authors.order(:id).pluck(
      :id,
      :author_kind,
      :display_name,
      :email,
      :orcid,
      :source_digest
    )
    contributor_rows = project.project_contributors.order(:id).pluck(
      :id,
      :owner_id,
      :name,
      :email,
      :login,
      :provider_uuid,
      :account_kind,
      :source_digest
    )
    paper_author_rows = joss_paper_authors.pluck(
      :id,
      :display_name,
      :email,
      :orcid,
      :role,
      :source_digest
    )
    Digest::SHA256.hexdigest(
      ActiveSupport::JSON.encode(
        [author_rows, contributor_rows, paper_author_rows]
      )
    )
  end

  def joss_paper_authors
    PaperAuthor
      .joins(paper: { mentions: :sources })
      .where(
        mentions: { project_id: project.id },
        mention_sources: { source: JossPublicationIndexer::SOURCE }
      )
      .distinct
      .order(:id)
  end

  def already_indexed?
    project.author_identities_indexed_at.present? &&
      project.author_identities_index_version == CURRENT_VERSION &&
      project.author_identities_source_digest == attempted_source_digest
  end
end
