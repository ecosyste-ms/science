require "digest"
require "uri"

class ProjectContributorIndexer
  CURRENT_VERSION = 1
  DEFAULT_LIMIT = 250
  MAX_LIMIT = 1_000
  UPSERT_BATCH_SIZE = 1_000
  SOURCE = "commits_ecosyste_ms"
  CANDIDATE_SQL = <<~SQL.squish.freeze
    (
      commits IS NOT NULL
      AND json_typeof(commits -> 'committers') = 'array'
    )
    OR contributors_source_digest IS NOT NULL
  SQL
  UPSERT_COLUMNS = %i[
    owner_id
    name
    email
    login
    provider_uuid
    account_kind
    classification_reason
    contributions_count
    source_digest
    raw_data
    author_id
    author_match_kind
    developer_account_id
    developer_account_match_kind
  ].freeze
  MERGED_COLUMNS = %i[
    owner_id
    name
    email
    login
    provider_uuid
  ].freeze
  PROVIDER_ID_KEYS = %w[uuid provider_uuid user_id provider_id id].freeze
  KNOWN_BOT_EMAILS = %w[
    action@github.com
    actions@github.com
    bot@deepsource.io
    github-actions@github.com
    github-bot@pyup.io
    snyk-bot@snyk.io
    support@dependabot.com
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
        "contributors_indexed_at IS NULL " \
          "OR contributors_index_version IS DISTINCT FROM ?",
        CURRENT_VERSION
      )
    unless retry_errors
      scope = scope.where(
        "contributors_index_error IS NULL " \
          "OR contributors_index_version IS DISTINCT FROM ?",
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
      source_rows: 0,
      contributors: 0,
      duplicates: 0,
      bots: 0,
      owner_links: 0,
    }
  end

  def self.merge_counts!(result, counts)
    empty_counts.except(:indexed, :failed, :skipped).each_key do |key|
      result[key] += counts.fetch(key)
    end
  end

  def sync!
    content = project.commits
    @attempted_source_digest = digest_for(content)
    source_rows = rows_for(content, attempted_source_digest)
    rows = collapse_rows(source_rows)
    resolve_owners!(rows)
    counts = counts_for(source_rows, rows)

    project.with_lock do
      return counts.merge(indexed: false) unless current_source?
      return counts.merge(indexed: false) if already_indexed?
      if project.contributors_index_error.present? &&
          project.contributors_index_version == CURRENT_VERSION &&
          !retry_errors
        return counts.merge(indexed: false)
      end

      now = Time.current
      rows.each_slice(UPSERT_BATCH_SIZE) do |batch|
        ProjectContributor.upsert_all(
          batch.map do |row|
            row.merge(
              project_id: project.id,
              author_id: nil,
              author_match_kind: nil,
              developer_account_id: nil,
              developer_account_match_kind: nil
            )
          end,
          unique_by: :index_project_contributors_on_source_key,
          update_only: UPSERT_COLUMNS,
          record_timestamps: true
        )
      end
      project.project_contributors
        .where(source: SOURCE)
        .where.not(source_digest: attempted_source_digest)
        .delete_all
      project.update_columns(
        contributors_indexed_at: now,
        contributors_index_error: nil,
        contributors_index_version: CURRENT_VERSION,
        contributors_source_digest: attempted_source_digest,
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
        contributors_indexed_at: nil,
        contributors_index_error: message,
        contributors_index_version: CURRENT_VERSION,
        contributors_source_digest: attempted_source_digest,
        updated_at: Time.current
      )
      recorded = true
    end

    Rails.logger.error(
      "Contributor indexing failed for project #{project.id}: #{message}"
    ) if recorded
    recorded
  end

  def rows_for(content, source_digest)
    committers = committers_from(content)
    committers.map.with_index do |committer, index|
      unless committer.is_a?(Hash)
        raise ArgumentError, "committers[#{index}] must be an object"
      end

      row_for(committer, source_digest)
    end
  end

  def committers_from(content)
    return [] if content.nil?
    unless content.is_a?(Hash)
      raise ArgumentError, "commits must be an object"
    end

    return [] unless content.key?("committers") || content.key?(:committers)

    committers = content["committers"] || content[:committers]
    return [] if committers.nil?
    unless committers.is_a?(Array)
      raise ArgumentError, "committers must be an array"
    end

    committers
  end

  def row_for(committer, source_digest)
    email = normalized_email(committer)
    github_identity = github_noreply_identity(email)
    login = normalized_login(committer) || github_identity&.fetch(:login)
    provider_uuid = provider_identifier(committer) ||
      github_identity&.fetch(:provider_uuid)
    account_kind, classification_reason = account_classification(
      committer,
      login,
      email
    )

    {
      source: SOURCE,
      source_key: source_key_for(committer, provider_uuid, login, email),
      owner_id: nil,
      name: normalized_scalar(committer["name"] || committer[:name]),
      email: email,
      login: login,
      provider_uuid: provider_uuid,
      account_kind: account_kind,
      classification_reason: classification_reason,
      contributions_count: contribution_count(committer),
      source_digest: source_digest,
      raw_data: json_safe(committer),
    }
  end

  def collapse_rows(rows)
    rows.each_with_object({}) do |row, collapsed|
      current = collapsed[row.fetch(:source_key)]
      unless current
        collapsed[row.fetch(:source_key)] = row.dup
        next
      end

      current[:contributions_count] += row.fetch(:contributions_count)
      MERGED_COLUMNS.each do |column|
        current[column] ||= row[column]
      end
      if current[:account_kind] == "unknown" && row[:account_kind] == "bot"
        current[:account_kind] = "bot"
        current[:classification_reason] = row[:classification_reason]
      end
    end.values
  end

  def resolve_owners!(rows)
    return rows if project.host_id.blank?

    provider_uuids = rows.filter_map { |row| row[:provider_uuid] }.uniq
    logins = rows.filter_map { |row| row[:login]&.downcase }.uniq
    owners = Owner.visible.where(host_id: project.host_id)
    owners_by_uuid = if provider_uuids.any?
      owners.where(uuid: provider_uuids).index_by { |owner| owner.uuid.to_s.downcase }
    else
      {}
    end
    owners_by_login = if logins.any?
      owners.where("lower(login) IN (?)", logins)
        .index_by { |owner| owner.login.downcase }
    else
      {}
    end

    rows.each do |row|
      owner = owners_by_uuid[row[:provider_uuid].to_s.downcase]
      owner ||= owners_by_login[row[:login].to_s.downcase]
      row[:owner_id] = owner&.id
    end
    rows
  end

  def source_key_for(committer, provider_uuid, login, email)
    return "provider:#{host_scope}:#{provider_uuid.downcase}" if provider_uuid
    return "login:#{host_scope}:#{login.downcase}" if login
    return "email:#{email}" if email

    identity_fields = committer.except("count", :count)
    "raw:#{digest_for(identity_fields)}"
  end

  def host_scope
    return "host-#{project.host_id}" if project.host_id

    URI.parse(project.url).host.to_s.downcase.presence || "unknown"
  rescue URI::InvalidURIError
    "unknown"
  end

  def provider_identifier(committer)
    PROVIDER_ID_KEYS.each do |key|
      value = normalized_scalar(committer[key] || committer[key.to_sym])
      return value if value
    end
    nil
  end

  def normalized_email(committer)
    value = normalized_scalar(committer["email"] || committer[:email])&.downcase
    return unless value&.match?(/\A[^@\s]+@[^@\s]+\z/)

    value
  end

  def normalized_login(committer)
    normalized_scalar(committer["login"] || committer[:login])&.downcase
  end

  def github_noreply_identity(email)
    return unless email

    match = email.match(
      /\A(?:(?<provider_uuid>\d+)\+)?(?<login>[^@]+)@users\.noreply\.github\.com\z/i
    )
    return unless match

    {
      provider_uuid: match[:provider_uuid],
      login: match[:login].downcase,
    }
  end

  def account_classification(committer, login, email)
    source_kind = normalized_scalar(
      committer["type"] || committer[:type] ||
        committer["kind"] || committer[:kind] ||
        committer["account_kind"] || committer[:account_kind]
    )
    return ["bot", "source_account_kind"] if source_kind&.casecmp?("bot")

    local_part = email&.split("@", 2)&.first
    return ["bot", "noreply_bot_email"] if local_part&.match?(/\[bot\]\z/i)
    return ["bot", "login_bot_suffix"] if login&.match?(/\[bot\]\z/i)
    return ["bot", "known_bot_email"] if KNOWN_BOT_EMAILS.include?(email)

    ["unknown", nil]
  end

  def contribution_count(committer)
    value = committer["count"] || committer[:count]
    count = Integer(value, exception: false) || 0
    [count, 0].max
  end

  def normalized_scalar(value)
    return if value.is_a?(Array) || value.is_a?(Hash)

    value.to_s.strip.presence
  end

  def counts_for(source_rows, rows)
    {
      source_rows: source_rows.length,
      contributors: rows.length,
      duplicates: source_rows.length - rows.length,
      bots: rows.count { |row| row.fetch(:account_kind) == "bot" },
      owner_links: rows.count { |row| row[:owner_id].present? },
    }
  end

  def digest_for(value)
    Digest::SHA256.hexdigest(
      ActiveSupport::JSON.encode(canonical_value(value))
    )
  end

  def canonical_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key.to_s] = canonical_value(item)
      end.sort.to_h
    when Array
      value.map { |item| canonical_value(item) }
    else
      value
    end
  end

  def json_safe(value)
    JSON.parse(ActiveSupport::JSON.encode(value))
  end

  def current_source?
    digest_for(project.commits) == attempted_source_digest
  end

  def already_indexed?
    project.contributors_indexed_at.present? &&
      project.contributors_index_version == CURRENT_VERSION &&
      project.contributors_source_digest == attempted_source_digest
  end
end
