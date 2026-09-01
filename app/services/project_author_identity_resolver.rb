require "set"

class ProjectAuthorIdentityResolver
  WRITE_BATCH_SIZE = 1_000
  KNOWN_BOT_NAMES = %w[
    dependabot
    dependabot[bot]
    github-actions[bot]
    renovate[bot]
  ].freeze

  attr_reader :project_authors

  def initialize(project_authors)
    @project_authors = project_authors
  end

  def resolve
    emails = project_authors.filter_map(&:email).uniq
    orcids_by_email = global_orcids_by_email(emails)
    desired = {}
    ambiguous = 0

    project_authors.each do |project_author|
      next if bot_author_observation?(project_author)

      if project_author.orcid.present?
        desired[project_author.id] = {
          canonical_key: "orcid:#{project_author.orcid}",
          match_kind: "orcid",
          project_author: project_author,
        }
        next
      end
      next if project_author.email.blank?

      orcids = orcids_by_email.fetch(project_author.email.downcase, [])
      if orcids.length > 1
        ambiguous += 1
        next
      end
      desired[project_author.id] = {
        canonical_key: orcids.one? ? "orcid:#{orcids.first}" : "email:#{project_author.email.downcase}",
        match_kind: orcids.one? ? "email_to_orcid" : "email",
        project_author: project_author,
      }
    end

    promote_email_authors!(desired.values)
    create_authors!(desired.values)
    authors_by_key = Author.where(
      canonical_key: desired.values.pluck(:canonical_key).uniq
    ).index_by { |author| author.canonical_key.downcase }
    create_author_identifiers!(desired.values, authors_by_key)

    identifiers = author_identifier_map(desired.values)
    assignments = {}
    desired.each do |project_author_id, resolution|
      author = authors_by_key[resolution.fetch(:canonical_key).downcase]
      next unless author

      project_author = resolution.fetch(:project_author)
      if resolution.fetch(:match_kind).start_with?("email")
        email_author_id = identifiers[["email", project_author.email.downcase]]
        unless email_author_id == author.id
          ambiguous += 1
          next
        end
      end
      assignments[project_author_id] = {
        author_id: author.id,
        match_kind: resolution.fetch(:match_kind),
      }
    end

    [assignments, ambiguous]
  end

  def bot_author_observation?(project_author)
    email = project_author.email&.downcase
    local_part = email&.split("@", 2)&.first
    return true if local_part&.match?(/\[bot\]\z/i)
    return true if ProjectContributorIndexer::KNOWN_BOT_EMAILS.include?(email)

    KNOWN_BOT_NAMES.include?(project_author.display_name.to_s.downcase)
  end

  def global_orcids_by_email(emails)
    return {} if emails.empty?

    ProjectAuthor.where(author_kind: "person", email: emails)
      .where.not(orcid: nil)
      .distinct
      .pluck(:email, :orcid)
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(email, orcid), result|
        result[email.downcase] << orcid unless result[email.downcase].include?(orcid)
      end
  end

  def promote_email_authors!(resolutions)
    resolutions.group_by { |resolution| resolution.fetch(:project_author).email&.downcase }
      .each_value do |email_resolutions|
        email = email_resolutions.first.fetch(:project_author).email&.downcase
        next if email.blank?

        canonical_keys = email_resolutions.pluck(:canonical_key).uniq
        next unless canonical_keys.one? && canonical_keys.first.start_with?("orcid:")
        next if Author.exists?(canonical_key: canonical_keys.first)

        identifier = AuthorIdentifier.find_by(scheme: "email", value: email)
        next unless identifier&.author&.canonical_key&.start_with?("email:")

        identifier.author.update!(canonical_key: canonical_keys.first)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        next
      end
  end

  def create_authors!(resolutions)
    rows = resolutions.group_by { |resolution| resolution.fetch(:canonical_key) }
      .map do |canonical_key, grouped|
        {
          canonical_key: canonical_key,
          display_name: grouped.filter_map do |resolution|
            resolution.fetch(:project_author).display_name
          end.first,
        }
      end
    rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      Author.insert_all(
        batch,
        unique_by: :index_authors_on_canonical_key,
        record_timestamps: true
      )
    end
  end

  def create_author_identifiers!(resolutions, authors_by_key)
    rows = resolutions.flat_map do |resolution|
      project_author = resolution.fetch(:project_author)
      author = authors_by_key.fetch(resolution.fetch(:canonical_key).downcase)
      identifiers = []
      if project_author.orcid.present?
        identifiers << {
          author_id: author.id,
          scheme: "orcid",
          value: project_author.orcid,
          publicly_visible: true,
        }
      end
      if project_author.email.present?
        identifiers << {
          author_id: author.id,
          scheme: "email",
          value: project_author.email.downcase,
          publicly_visible: false,
        }
      end
      identifiers
    end
    rows.uniq! { |row| [row.fetch(:scheme), row.fetch(:value)] }
    rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      AuthorIdentifier.insert_all(
        batch,
        unique_by: :index_author_identifiers_on_scheme_and_value,
        record_timestamps: true
      )
    end
  end

  def author_identifier_map(resolutions)
    pairs = resolutions.flat_map do |resolution|
      project_author = resolution.fetch(:project_author)
      [
        ["orcid", project_author.orcid],
        ["email", project_author.email&.downcase],
      ]
    end.reject { |_, value| value.blank? }.uniq
    return {} if pairs.empty?

    schemes = pairs.pluck(0).uniq
    values = pairs.pluck(1).uniq
    allowed = pairs.to_set
    AuthorIdentifier.where(scheme: schemes, value: values)
      .pluck(:scheme, :value, :author_id)
      .each_with_object({}) do |(scheme, value, author_id), result|
        key = [scheme, value.downcase]
        result[key] = author_id if allowed.include?(key)
      end
  end
end
