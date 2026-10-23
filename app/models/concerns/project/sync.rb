require 'open3'

module Project::Sync
  extend ActiveSupport::Concern

  SLOW_STAGE_SECONDS = 5.0
  SLOW_SYNC_SECONDS = 30.0

  class_methods do
    def sync_least_recently_synced
      Project.visible.should_sync.where("last_synced_at IS NULL OR last_synced_at < ?", 1.day.ago)
        .order(Arel.sql('last_synced_at asc nulls first, id asc')).limit(50).pluck(:id).each do |id|
        SyncProjectWorker.perform_async(id)
      end
    end

    def sync_all
      Project.all.each do |project|
        project.sync_async
      end
    end

    def sync_dependencies(limit: ProjectDependencyIndexer::DEFAULT_LIMIT, retry_errors: false)
      ProjectDependencyIndexer.sync_batch!(limit: limit, retry_errors: retry_errors)
    end

    def sync_citation_authors(
      limit: ProjectCitationAuthorIndexer::DEFAULT_LIMIT,
      retry_errors: false
    )
      ProjectCitationAuthorIndexer.sync_batch!(
        limit: limit,
        retry_errors: retry_errors
      )
    end

    def sync_joss_publications(
      limit: JossPublicationIndexer::DEFAULT_LIMIT,
      retry_errors: false
    )
      JossPublicationIndexer.sync_batch!(
        limit: limit,
        retry_errors: retry_errors
      )
    end

    def sync_contributors(
      limit: ProjectContributorIndexer::DEFAULT_LIMIT,
      retry_errors: false
    )
      ProjectContributorIndexer.sync_batch!(
        limit: limit,
        retry_errors: retry_errors
      )
    end

    def sync_author_identities(
      limit: AuthorIdentityIndexer::DEFAULT_LIMIT,
      retry_errors: false
    )
      AuthorIdentityIndexer.sync_batch!(
        limit: limit,
        retry_errors: retry_errors
      )
    end
  end

  def sync
    sync_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stage_durations = {}

    return if hidden_owner?
    if repository_from_package?
      run_sync_stage(stage_durations, :fetch_repository) do
        source = PackageRepository.new(self)
        source.refresh_metadata(source.package)
      end
      run_sync_stage(stage_durations, :scan_repository) do
        revision = repository.dig("metadata", "revision")
        ProjectRepositoryScanner.new(self, force_brief: brief&.dig("revision") != revision).scan
      end
    else
      run_sync_stage(stage_durations, :check_url) { check_url }
      return unless self.persisted?
      run_sync_stage(stage_durations, :fetch_repository) { fetch_repository }
      run_sync_stage(stage_durations, :find_or_create_host) { find_or_create_host }
      run_sync_stage(stage_durations, :fetch_owner) { fetch_owner }
      run_sync_stage(stage_durations, :find_or_create_owner) { find_or_create_owner }
      return if hidden_owner?

      run_sync_stage(stage_durations, :fetch_dependencies) { fetch_dependencies }
      run_sync_stage(stage_durations, :fetch_packages) { fetch_packages }
      run_sync_stage(stage_durations, :fetch_readme) { fetch_readme }
      run_sync_stage(stage_durations, :fetch_commits) { fetch_commits }
      run_sync_stage(stage_durations, :fetch_events) { fetch_events }
      run_sync_stage(stage_durations, :fetch_issue_stats) { fetch_issue_stats }
      run_sync_stage(stage_durations, :sync_issues) { sync_issues }
      run_sync_stage(stage_durations, :fetch_citation_file) { fetch_citation_file }
      run_sync_stage(stage_durations, :fetch_codemeta) { fetch_codemeta }
      run_sync_stage(stage_durations, :fetch_zenodo_file) { fetch_zenodo_file }
      run_sync_stage(stage_durations, :sync_releases) { sync_releases }
      run_sync_stage(stage_durations, :update_committers) { update_committers }
      run_sync_stage(stage_durations, :update_keywords_from_contributors) do
        update_keywords_from_contributors
      end
    end
    run_sync_stage(stage_durations, :combine_keywords) { combine_keywords }
    run_sync_stage(stage_durations, :refresh_display_name) { refresh_display_name }
    run_sync_stage(stage_durations, :finalize) do
      update(last_synced_at: Time.now, matching_criteria: matching_criteria?)
    end
    run_sync_stage(stage_durations, :update_score) { update_score }
    run_sync_stage(stage_durations, :update_science_score) { update_science_score }
    run_sync_stage(stage_durations, :fetch_swhids_async) { fetch_swhids_async }
  ensure
    if sync_started_at
      total_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - sync_started_at
      log_sync_timings(stage_durations, total_duration)
    end
  end

  def run_sync_stage(durations, stage)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    durations[stage] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  end

  def log_sync_timings(durations, total_duration)
    rounded_stages = durations.transform_values { |duration| duration.round(3) }
    slow_stages = durations
      .select { |_, duration| duration >= SLOW_STAGE_SECONDS }
      .transform_values { |duration| duration.round(3) }
    return if total_duration < SLOW_SYNC_SECONDS && slow_stages.empty?

    payload = {
      event: "project_sync_timing",
      project_id: id,
      url: url,
      total_seconds: total_duration.round(3),
      slow_stages: slow_stages
    }
    payload[:stages] = rounded_stages if total_duration >= SLOW_SYNC_SECONDS
    Rails.logger.info(payload.to_json)
  end

  def sync_async
    return if hidden_owner?
    return unless persisted?

    SyncProjectWorker.perform_async(id)
  end

  def check_url
    conn = http_client(url)

    response = conn.get
    return unless response.success?
    self.class.transaction(requires_new: true) do
      update!(url: response.env.url.to_s)
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    puts "Duplicate url #{url}"
    puts e.class
    destroy
  rescue
    puts "Error checking url for #{url}"
  end

  def combine_keywords
    all_keywords = []
    all_keywords += repository["topics"] if repository.present?
    all_keywords += packages.flat_map { |p| Array(p["keywords_array"]) + Array(p["keywords"]) } if packages.present?
    self.keywords = all_keywords.reject(&:blank?).uniq { |keyword| keyword.downcase }.dup
    self.save
  rescue FrozenError
    puts "Error combining keywords for #{repository_url}"
  end

  def refresh_display_name
    return unless repository.present?

    metadata = repository["metadata"] || {}
    return if name.present? && name != metadata["derived_name"]

    value = if model_project?
      repository["name"].presence || readme_name || repository["full_name"].presence || repository_slug
    else
      declared_name || repository["full_name"].presence || repository_slug
    end
    return if value.blank?

    update!(name: value, repository: repository.merge("metadata" => metadata.merge("derived_name" => value)))
  end

  def declared_name
    metadata = ProjectMetadata.new(self)
    cff_title = begin
      metadata.text(metadata.cff_document["title"])
    rescue Psych::Exception
      nil
    end
    cff_title || metadata.text(metadata.json_document(:codemeta)["name"])
  end

  def repos_api_url
    "https://repos.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def repos_url
    return unless repository.present?
    return repository["html_url"] if model_project?
    "https://repos.ecosyste.ms/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}"
  end

  def fetch_repository
    conn = ecosystem_http_client(repos_api_url)

    response = conn.get
    return unless response.success?
    data = JSON.parse(response.body)
    # The marker separates derived names from curated ones, so it has to survive a refresh.
    derived_name = repository.dig("metadata", "derived_name") if repository.is_a?(Hash) && repository["metadata"].is_a?(Hash)
    if derived_name && data.is_a?(Hash)
      data["metadata"] = (data["metadata"].is_a?(Hash) ? data["metadata"] : {}).merge("derived_name" => derived_name)
    end
    self.repository = data
    self.save
  rescue => e
    puts "Error fetching repository for #{repository_url}"
    puts e.message
    puts e.backtrace
  end

  def owner_api_url
    return unless repository.present?
    return unless repository["owner"].present?
    return unless repository["host"].present?
    return unless repository["host"]["name"].present?
    "https://repos.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/owners/#{repository['owner']}"
  end

  def owner_url
    return unless repository.present?
    return unless repository["owner"].present?
    return unless repository["host"].present?
    return unless repository["host"]["name"].present?
    "https://repos.ecosyste.ms/hosts/#{repository['host']['name']}/owners/#{repository['owner']}"
  end

  def fetch_owner
    return unless owner_api_url.present?
    conn = ecosystem_http_client(owner_api_url)

    response = conn.get
    return unless response.success?
    self.owner = JSON.parse(response.body)
    self.save
  rescue
    puts "Error fetching owner for #{repository_url}"
  end

  def find_or_create_host
    return unless repository.present?
    return unless repository['host'].present?

    host_data = repository['host']
    return unless host_data['name'].present?

    host = Host.find_or_initialize_by(name: host_data['name'])
    host.assign_attributes(
      url: host_data['url'],
      kind: host_data['kind']
    )
    host.save

    self.update(host: host)
  rescue => e
    puts "Error finding or creating host for #{repository_url}: #{e.message}"
  end

  def find_or_create_owner
    owner_data = read_attribute(:owner)
    return unless owner_data.present?
    return unless host.present?
    return unless owner_data['login'].present?

    owner_record = host.owners.find_by('lower(login) = ?', owner_data['login'].downcase)
    if owner_record&.hidden? || owner_data['hidden'] == true
      owner_record ||= host.owners.build(login: owner_data['login'].downcase)
      owner_record.hide!
      update_attribute(:owner_id, owner_record.id)
      return owner_record
    end

    owner_record ||= host.owners.build(login: owner_data['login'].downcase)

    owner_record.assign_attributes(
      name: owner_data['name'],
      uuid: owner_data['uuid'],
      kind: owner_data['kind'],
      description: owner_data['description'],
      email: owner_data['email'],
      website: owner_data['website'],
      location: owner_data['location'],
      twitter: owner_data['twitter'],
      company: owner_data['company'],
      icon_url: owner_data['icon_url'],
      repositories_count: owner_data['repositories_count'] || 0,
      last_synced_at: Time.now,
      metadata: owner_data['metadata'] || {},
      total_stars: owner_data['total_stars'],
      followers: owner_data['followers'],
      following: owner_data['following'],
      hidden: owner_record.hidden? ? true : owner_data['hidden']
    )
    owner_record.save

    update_attribute(:owner_id, owner_record.id)
  rescue => e
    puts "Error finding or creating owner for #{repository_url}: #{e.message}"
  end

  def timeline_url
    return unless repository.present?
    return unless repository["host"]["name"] == "GitHub"

    "https://timeline.ecosyste.ms/api/v1/events/#{repository['full_name']}/summary"
  end

  def fetch_events
    return unless timeline_url.present?
    conn = ecosystem_http_client(timeline_url)

    response = conn.get
    return unless response.success?
    summary = JSON.parse(response.body)

    conn = ecosystem_http_client(timeline_url+'?after='+1.year.ago.to_fs(:iso8601))

    response = conn.get
    return unless response.success?
    last_year = JSON.parse(response.body)

    self.events = {
      "total" => summary,
      "last_year" => last_year
    }
    self.save
  rescue
    puts "Error fetching events for #{repository_url}"
  end

  def packages_url
    "https://packages.ecosyste.ms/api/v1/packages/lookup?repository_url=#{repository_url}"
  end

  def fetch_packages
    conn = ecosystem_http_client(packages_url)

    response = conn.get
    return unless response.success?
    package_records = JSON.parse(response.body)
    package_records, duplicates = without_case_duplicate_go_modules(package_records)
    self.packages = package_records
    self.save
    link_published_packages(package_records)
    unlink_published_packages(duplicates)
  rescue
    puts "Error fetching packages for #{repository_url}"
  end

  # proxy.golang.org lists each capitalisation of a GitHub path anyone requested as its own module.
  def without_case_duplicate_go_modules(records)
    full_name = repository["full_name"].presence if repository.is_a?(Hash)
    go = records.select { |record| record.is_a?(Hash) && record["ecosystem"] == "go" && record["name"].is_a?(String) }
    kept = go.group_by { |record| record["name"].downcase }.values.map do |group|
      group.find { |record| full_name && record["name"].end_with?("/#{full_name}") } || group.first
    end
    duplicates = go - kept
    [records - duplicates, duplicates]
  end

  def unlink_published_packages(records)
    purls = records.filter_map do |record|
      Purl.parse(record["purl"]).with(version: nil, subpath: nil).to_s if record["purl"].present?
    rescue Purl::Error
      nil
    end
    return if purls.empty?

    Package.where(purl: purls, published_by_project_id: id).update_all(published_by_project_id: nil, updated_at: Time.current)
  end

  def link_published_packages(records)
    purls = records.filter_map do |record|
      purl = record["purl"]
      next if purl.blank?

      Purl.parse(purl).with(version: nil, subpath: nil).to_s
    rescue Purl::Error
      nil
    end.uniq
    return if purls.empty?

    now = Time.current
    Package.where(purl: purls, published_by_project_id: nil).update_all(
      published_by_project_id: id,
      repository_checked_at: now,
      repository_match_error: nil,
      updated_at: now
    )
  end

  def commits_api_url
    "https://commits.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def commits_url
    "https://commits.ecosyste.ms/repositories/lookup?url=#{repository_url}"
  end

  def fetch_commits
    return unless repository.present?
    
    conn = ecosystem_http_client(commits_api_url)
    response = conn.get
    return unless response.success?
    self.commits = JSON.parse(response.body)
    self.save
  rescue
    puts "Error fetching commits for #{repository_url}"
  end

  def reset_contributor_index
    self.contributors_indexed_at = nil
    self.contributors_index_error = nil
  end

  def fetch_dependencies
    return unless repository.present?
    conn = ecosystem_http_client(repository['manifests_url'])
    response = conn.get
    return unless response.success?
    self.dependencies = JSON.parse(response.body)
    if will_save_change_to_dependencies?
      self.dependencies_indexed_at = nil
      self.dependencies_index_error = nil
    end
    self.save
  rescue
    puts "Error fetching dependencies for #{repository_url}"
  end

  def fetch_dependent_repos
    return unless packages.present?
    dependent_repos = []
    packages.each do |package|
      # TODO paginate
      # TODO group dependencies by repo
      dependent_repos_url = "https://repos.ecosyste.ms/api/v1/usage/#{package["ecosystem"]}/#{package["name"]}/dependencies"
      conn = ecosystem_http_client(dependent_repos_url)
      response = conn.get
      return unless response.success?
      dependent_repos += JSON.parse(response.body)
    end
    self.dependent_repos = dependent_repos.uniq
    self.save
  end

  def issues_api_url
    "https://issues.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def issue_stats_url
    "https://issues.ecosyste.ms/repositories/lookup?url=#{repository_url}"
  end

  def fetch_issue_stats
    conn = ecosystem_http_client(issues_api_url)
    response = conn.get
    return unless response.success?
    self.issues_stats = JSON.parse(response.body)
    self.save
  rescue
    puts "Error fetching issues for #{repository_url}"
  end

  def load_readme
    return unless download_url.present?
    conn = ecosystem_http_client(archive_url(readme_file_name))
    response = conn.get
    return unless response.success?
    json = JSON.parse(response.body)
    json['contents'].gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def load_codemeta
    return unless download_url.present?
    return unless codemeta_file_name.present?
    conn = ecosystem_http_client(archive_url(codemeta_file_name))
    response = conn.get
    return unless response.success?
    json = JSON.parse(response.body)
    json['contents'].gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def fetch_readme
    return unless repository.present?
    
    if readme_file_name.blank? || download_url.blank?
      fetch_readme_fallback
    else  
      readme_content = load_readme
      if readme_content.present?
        self.readme = readme_content
        self.save if changed?
      else
        fetch_readme_fallback
      end
    end
  rescue => e
    puts "Error fetching readme for #{repository_url}"
    puts e.message
    puts e.backtrace
    fetch_readme_fallback
  end

  def load_readme_fallback
    return unless repository.present?

    file_name = readme_file_name.presence || 'README.md'
    url = raw_url(file_name)

    return unless url.present?

    conn = http_client(url, retry_requests: true)

    response = conn.get
    return unless response.success?
    response.body.gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def load_codemeta_fallback
    return unless repository.present?

    file_name = codemeta_file_name.presence || 'codemeta.json'
    url = raw_url(file_name)

    return unless url.present?

    conn = http_client(url, retry_requests: true)

    response = conn.get
    return unless response.success?
    response.body.gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def fetch_readme_fallback
    return unless repository.present?

    readme_content = load_readme_fallback
    return unless readme_content.present?
    self.readme = readme_content
    self.save if changed?
  rescue => e
    puts "Error fetching fallback readme for project #{self.id} (#{self.url})"
    puts "  repository_url: #{repository_url}"
    puts "  Error: #{e.class} - #{e.message}"
    puts "  Backtrace:"
    puts e.backtrace.first(5)
  end

  def fetch_codemeta
    return unless repository.present?

    if codemeta_file_name.blank? || download_url.blank?
      fetch_codemeta_fallback
    else
      codemeta_content = load_codemeta
      if codemeta_content.present?
        self.codemeta = codemeta_content
        self.save if changed?
      else
        fetch_codemeta_fallback
      end
    end
  rescue => e
    puts "Error fetching codemeta for #{repository_url}"
    puts e.message
    puts e.backtrace
    fetch_codemeta_fallback
  end

  def fetch_codemeta_fallback
    return unless repository.present?

    codemeta_content = load_codemeta_fallback
    return unless codemeta_content.present?
    self.codemeta = codemeta_content
    self.save if changed?
  rescue => e
    puts "Error fetching fallback codemeta for project #{self.id} (#{self.url})"
    puts "  repository_url: #{repository_url}"
    puts "  Error: #{e.class} - #{e.message}"
    puts "  Backtrace:"
    puts e.backtrace.first(5)
  end

  def archive_url(path)
    return unless download_url.present?
    "https://archives.ecosyste.ms/api/v1/archives/contents?url=#{download_url}&path=#{path}"
  end

  def fetch_citation_file
    return unless repository.present?
    unless citation_file_name.present?
      update!(citation_file: nil) if citation_file.present?
      return
    end
    return unless download_url.present?
    conn = ecosystem_http_client(archive_url(citation_file_name))
    response = conn.get
    return unless response.success?
    json = JSON.parse(response.body)

    self.citation_file = json['contents']
    self.save
  rescue
    puts "Error fetching citation file for #{repository_url}"
  end

  def fetch_zenodo_file
    return unless repository.present?
    return unless zenodo_file_name.present?
    return unless download_url.present?
    conn = ecosystem_http_client(archive_url(zenodo_file_name))
    response = conn.get
    return unless response.success?
    json = JSON.parse(response.body)

    self.zenodo = json['contents']
    self.save
  rescue
    puts "Error fetching zenodo file for #{repository_url}"
  end

  def blob_url(path)
    return unless repository.present?
    ref = model_project? ? brief&.dig("revision") || repository.dig("metadata", "revision") : repository['default_branch']
    "#{repository['html_url']}/blob/#{ref}/#{path}"
  end 

  def raw_url(path)
    return unless repository.present?
    if model_project?
      ref = brief&.dig("revision") || repository.dig("metadata", "revision")
      return "#{repository['html_url']}/resolve/#{ref}/#{path}"
    end
    "#{repository['html_url']}/raw/#{repository['default_branch']}/#{path}"
  end 

  def fetch_swhids_async
    return unless persisted?
    return if gated?
    scope = Project.visible.with_repository.where(id: id)
    # Retries only go through projects:fetch_brief, so its LIMIT caps clone volume.
    if brief_scan_due? && !brief_retry_due? && scope.with_research_registry_match.exists?
      return RepositoryScanWorker.perform_async(id)
    end
    return unless scope.scientific.exists?
    return unless swhid_scan_due? || SwhidArchiveChecker.new(swhids).due? || SwhidArchiver.new(self).due?

    swhid_scan_due? ? RepositoryScanWorker.perform_async(id) : enqueue_swhid_check
  end

  def swhid_scan_due?
    swhids.nil? || swhids["status"].nil?
  end

  def enqueue_swhid_check
    return unless Project.visible.scientific.with_repository.exists?(id: id)

    if SwhidArchiveChecker.new(swhids).due?
      CheckSwhidBatchWorker.enqueue(id)
    elsif SwhidArchiver.new(self).due?
      CheckSwhidArchivalWorker.perform_async(id)
    end
  end

  def fetch_swhids(checkout:, origin:, clone_command:)
    return unless repository.present?

    result = ProjectSwhidScanner.new(self).scan(checkout: checkout, origin: origin, clone_command: clone_command)
    store_swhids(result)
  end

  def store_swhids(result)
    with_lock { update!(swhids: (swhids || {}).slice("origin_archive", "history_archive").merge(result)) }
    swhids
  end

  def check_swhid_archive(force: false)
    rate_limit = with_lock do
      checker = SwhidArchiveChecker.new(swhids)
      return unless force || checker.due?

      update!(swhids: checker.check(force: force))
      checker.rate_limit
    end
    raise rate_limit if rate_limit

    swhids
  end

  def brief_scan_due?
    return false if gated?

    return true if brief&.[]("status") == "gated"
    brief.nil? || (!brief.key?("dependencies") && !brief.key?("error")) || brief_retry_due?
  end

  def brief_retry_due?
    return false unless brief.is_a?(Hash) && brief.key?("error") && !brief.key?("dependencies")
    return false if brief["error"] == Project::BRIEF_TOO_LARGE_ERROR

    attempts = brief.fetch("attempts", 1).to_i
    attempted_at = Time.zone.parse(brief["attempted_at"].to_s)
    attempts < Project::BRIEF_RETRY_LIMIT && (attempted_at.nil? || attempted_at <= (Project::BRIEF_RETRY_COOLDOWN * attempts).ago)
  end

  def fetch_brief(checkout:)
    return unless repository.present?

    data = RepositoryBriefScan.call(checkout)
    previous_brief_dependencies = brief.is_a?(Hash) ? brief['dependencies'] : nil
    self.brief = data
    unless repository_from_package?
      extracted = RepositoryMetadata.new(readme: readme, brief: data).attributes.except("name")
      self.repository = extracted.merge(repository.reject { |_, value| value.blank? })
    end
    if previous_brief_dependencies != data['dependencies']
      self.dependencies_indexed_at = nil
      self.dependencies_index_error = nil
    end
    save
  rescue RepositoryCommand::Error, SystemCallError => error
    record_brief_error(error.message)
  rescue JSON::ParserError => e
    Rails.logger.warn "brief output not JSON for #{repository_url}: #{e.message}"
    record_brief_error("parse: #{e.message}")
  end

  def record_brief_error(msg)
    failure = { 'error' => msg.to_s[0, 500], 'attempted_at' => Time.now.utc.iso8601 }
    # A failed refresh says nothing about the software, so keep the last successful scan.
    if brief.is_a?(Hash) && brief.key?('dependencies') && !brief.key?('error')
      update_column(:brief, brief.merge('last_error' => failure))
    else
      attempts = brief.is_a?(Hash) && brief.key?('error') ? brief.fetch('attempts', 1).to_i : 0
      update_column(:brief, failure.merge('attempts' => attempts + 1))
    end
  end

  def sync_issues
    return unless repository.present?
    
    conn = ecosystem_http_client(issues_api_url)
    response = conn.get
    return unless response.success?
    issues_list_url = JSON.parse(response.body)['issues_url'] + '?per_page=1000&pull_request=false'
    # issues_list_url = issues_list_url + '&updated_after=' + last_synced_at.to_fs(:iso8601) if last_synced_at.present?

    conn = ecosystem_http_client(issues_list_url)
    response = conn.get
    return unless response.success?
    
    issues_json = JSON.parse(response.body)
    return unless issues_json.is_a?(Array)

    # TODO pagination
    # TODO upsert (plus unique index)

    issues_json.each do |issue|
      i = issues.find_or_create_by(number: issue['number']) 
      i.assign_attributes(issue)
      i.save(touch: false)
    end
  end

  def fetch_works
    works = {}
    readme_doi_urls.each do |url|
      openalex_url = "https://api.openalex.org/works/#{url}"
      conn = http_client(openalex_url)
      response = conn.get
      if response.success?
        works[url] = JSON.parse(response.body)
      else
        works[url] = nil
      end
    end
    self.works = works
    self.save
  end

  def sync_releases
    ProjectReleaseSync.enqueue(self)
  end
end
