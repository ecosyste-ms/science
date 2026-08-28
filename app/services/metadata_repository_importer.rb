require "set"
require "uri"

class MetadataRepositoryImporter
  BATCH_SIZE = 100
  GITHUB_HOST = "github.com"
  REPOSITORY_ALIAS_SQL = <<~SQL.squish
    SELECT DISTINCT
      'https://' || lower(split_part(projects.url::text, '/', 3)) || '/' ||
        lower(previous_names.name) AS repository_url
    FROM projects
    CROSS JOIN LATERAL json_array_elements_text(
      CASE
        WHEN json_typeof(projects.repository -> 'previous_names') = 'array'
          THEN projects.repository -> 'previous_names'
        ELSE '[]'::json
      END
    ) AS previous_names(name)
    WHERE NULLIF(previous_names.name, '') IS NOT NULL
  SQL
  BITBUCKET_HOSTS = %w[bitbucket.org www.bitbucket.org].freeze
  GITHUB_RESERVED_OWNERS = %w[
    about
    account
    apps
    codespaces
    collections
    copilot
    customer-stories
    enterprise
    events
    explore
    features
    github-copilot
    issues
    join
    login
    marketplace
    new
    notifications
    orgs
    organizations
    pricing
    pulls
    readme
    search
    security
    settings
    site
    sponsors
    topics
    trending
    users
  ].freeze
  PLACEHOLDER_OWNERS = %w[
    account
    example
    my-org
    my-organization
    my-user
    my-username
    org
    organization
    owner
    test
    user
    username
    your-github-username
    your-lab
    your-org
    your-organization
    your-user
    your-username
    yourlab
    yourorg
    youruser
    yourusername
  ].freeze
  PLACEHOLDER_REPOSITORIES = %w[
    example
    repo
    repo-name
    reponame
    repository
    repository-name
    test
    your-project
    your-repo
    your-repo-name
    your-repository
    your-repository-name
  ].freeze
  GITLAB_PATH_MARKERS = %w[
    -
    activity
    blob
    commits
    issues
    merge_requests
    raw
    releases
    tree
    wikis
  ].freeze
  GITLAB_RESERVED_ROOTS = %w[
    -
    admin
    dashboard
    explore
    help
    profile
    projects
    search
    users
  ].freeze
  PLACEHOLDER_PATHS = %w[
    org/repo
    organization/repository
    owner/repo
    username/repo
    username/repository
    your-org/your-repo
    your-organization/your-repository
    your-username/your-repository-name
  ].freeze

  class << self
    def sync!(
      scope: default_scope,
      gitlab_hosts: configured_gitlab_hosts,
      batch_size: BATCH_SIZE,
      dry_run: false,
      progress: nil
    )
      counts = {
        projects: scope.count,
        processed: 0,
        links: 0,
        repositories: 0,
        github: 0,
        gitlab: 0,
        existing: 0,
        aliases: 0,
        new: 0,
        created: 0,
        self: 0,
        bitbucket: 0,
        skipped: 0,
        failed: 0,
      }
      seen = Set.new
      alias_urls = nil
      allowed_gitlab_hosts = gitlab_hosts.map { |host| normalized_host(host) }.compact.to_set

      scope.in_batches(of: batch_size) do |batch|
        projects = batch.select(*project_columns).to_a
        candidates = repository_candidates(
          projects,
          allowed_gitlab_hosts,
          seen,
          counts
        )
        if candidates.any?
          alias_urls ||= repository_alias_urls
          import_candidates(
            candidates,
            counts,
            alias_urls: alias_urls,
            gitlab_hosts: allowed_gitlab_hosts,
            dry_run: dry_run
          )
        end
        counts[:processed] += projects.length
        progress&.call(
          "Metadata repository projects processed: #{counts[:processed]}"
        )
      end

      counts
    end

    def default_scope
      Project.visible.scientific.where(
        "NULLIF(citation_file, '') IS NOT NULL OR " \
        "NULLIF(codemeta, '') IS NOT NULL OR " \
        "NULLIF(zenodo, '') IS NOT NULL"
      )
    end

    def configured_gitlab_hosts(client: ReposApiClient.new)
      values = Host.where("lower(kind) = ?", "gitlab").pluck(:url, :name).flatten
      local_hosts = (["gitlab.com"] + values)
        .filter_map { |value| normalized_host(value) }
      remote_hosts = client.gitlab_hosts.filter_map do |value|
        normalized_host(value)
      end
      (local_hosts + remote_hosts).uniq
    rescue ReposApiClient::RequestError => error
      warn "Unable to load the repos.ecosyste.ms GitLab hosts: #{error.message}"
      local_hosts.uniq
    end

    def repository_candidates(projects, gitlab_hosts, seen, counts)
      projects.each_with_object([]) do |project, candidates|
        source_url = normalize_repository_url(project.url, gitlab_hosts: gitlab_hosts)
        project.metadata_repository_url_candidates.each do |candidate|
          counts[:links] += 1
          value = candidate[:value]
          if bitbucket_url?(value)
            counts[:bitbucket] += 1
            next
          end

          repository_url = normalize_repository_url(
            value,
            gitlab_hosts: gitlab_hosts
          )
          unless repository_url
            counts[:skipped] += 1
            next
          end
          next unless seen.add?(repository_url)

          counts[:repositories] += 1
          kind = repository_url.start_with?("https://github.com/") ? :github : :gitlab
          counts[kind] += 1
          if repository_url == source_url
            counts[:self] += 1
            next
          end

          candidates << repository_url
        end
      end
    end

    def import_candidates(candidates, counts, alias_urls:, gitlab_hosts:, dry_run:)
      return if candidates.empty?

      existing_urls = existing_repository_urls(candidates, gitlab_hosts: gitlab_hosts)
      candidates.each do |repository_url|
        if existing_urls.include?(repository_url)
          counts[:existing] += 1
          next
        end
        if alias_urls.include?(repository_url)
          counts[:existing] += 1
          counts[:aliases] += 1
          next
        end

        counts[:new] += 1
        next if dry_run

        project = Project.create(url: repository_url)
        if project.persisted?
          project.sync_async
          counts[:created] += 1
        else
          counts[:failed] += 1
          warn "Failed to create #{repository_url}: #{project.errors.full_messages.join(', ')}"
        end
      rescue ActiveRecord::RecordNotUnique
        counts[:existing] += 1
        counts[:new] -= 1
      end
    end

    def existing_repository_urls(candidates, gitlab_hosts:)
      lookup_urls = candidates.flat_map { |url| [url, "#{url}/"] }
      Project.where(url: lookup_urls).pluck(:url).filter_map do |url|
        normalize_repository_url(url, gitlab_hosts: gitlab_hosts)
      end.to_set
    end

    def repository_alias_urls
      connection = ActiveRecord::Base.connection
      Project.transaction do
        connection.execute("SET LOCAL max_parallel_workers_per_gather = 0")
        connection.select_values(REPOSITORY_ALIAS_SQL).to_set
      end
    end

    def normalize_repository_url(value, gitlab_hosts: configured_gitlab_hosts)
      uri = repository_uri(value)
      return unless uri

      host = normalized_host(uri.host)
      if host == GITHUB_HOST
        normalize_github_url(uri)
      elsif gitlab_hosts.include?(host)
        normalize_gitlab_url(uri)
      end
    end

    def normalize_github_url(uri)
      segments = path_segments(uri)
      return unless segments.length >= 2

      owner, repository = segments.first(2)
      repository = repository.delete_suffix(".git")
      return unless valid_github_owner?(owner) && valid_path_segment?(repository)
      return if GITHUB_RESERVED_OWNERS.include?(owner.downcase)
      return if placeholder_path?([owner, repository])

      "https://github.com/#{owner}/#{repository}".downcase
    end

    def normalize_gitlab_url(uri)
      segments = path_segments(uri)
      return if GITLAB_RESERVED_ROOTS.include?(segments.first&.downcase)

      marker = segments.each_index.find do |index|
        index >= 2 && GITLAB_PATH_MARKERS.include?(segments[index].downcase)
      end
      segments = segments.first(marker) if marker
      return unless segments.length >= 2

      segments[-1] = segments[-1].delete_suffix(".git")
      return unless segments.all? { |segment| valid_path_segment?(segment) }
      return if placeholder_path?(segments)

      "https://#{normalized_host(uri.host)}/#{segments.join('/')}".downcase
    end

    def repository_uri(value)
      cleaned = value.to_s.strip
        .sub(/\A[<({\[]+/, "")
        .sub(/[>)}\],.;:]+\z/, "")
      uri = URI.parse(cleaned)
      return unless %w[http https].include?(uri.scheme&.downcase)
      return unless uri.host.present?
      return if uri.userinfo.present?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def bitbucket_url?(value)
      uri = repository_uri(value)
      uri && BITBUCKET_HOSTS.include?(uri.host.downcase)
    end

    def normalized_host(value)
      string = value.to_s.strip.downcase
      return if string.blank?

      uri = URI.parse(string.include?("://") ? string : "https://#{string}")
      uri.host&.downcase&.delete_prefix("www.")
    rescue URI::InvalidURIError
      nil
    end

    def path_segments(uri)
      uri.path.split("/").reject(&:blank?)
    end

    def valid_path_segment?(segment)
      segment.present? && segment.match?(/\A[a-z0-9_.-]+\z/i)
    end

    def valid_github_owner?(owner)
      owner.present? &&
        owner.length <= 39 &&
        owner.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i)
    end

    def placeholder_path?(segments)
      normalized = segments.map { |segment| segment.downcase.tr("_", "-") }
      owner = normalized.first
      repository = normalized.last

      PLACEHOLDER_PATHS.include?(normalized.join("/")) ||
        PLACEHOLDER_OWNERS.include?(owner) ||
        PLACEHOLDER_REPOSITORIES.include?(repository) ||
        repository.match?(/\Ayour-(?:project|repo|repository)(?:-|\z)/)
    end

    def project_columns
      %i[id url citation_file codemeta zenodo]
    end
  end
end
