require 'open3'

module Project::Sync
  extend ActiveSupport::Concern

  class_methods do
    def sync_least_recently_synced
      Project.should_sync.where(last_synced_at: nil).or(Project.should_sync.where("last_synced_at < ?", 1.day.ago)).order('last_synced_at asc nulls first').limit(500).each do |project|
        project.sync_async
      end
    end

    def sync_all
      Project.all.each do |project|
        project.sync_async
      end
    end

    def sync_dependencies(min_count: 10)
      dependencies = Project.map(&:dependency_packages).flatten(1).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse

      dependencies.each do |(ecosystem, package_name), count|
        puts "Checking #{ecosystem} #{package_name}"

        dependency = Dependency.find_or_create_by(ecosystem: ecosystem, name: package_name)

        dependency.update(count: count)

        next if dependency.package.present?

        dependency.sync_package if count > min_count
      end
    end
  end

  def sync
    return if hidden_owner?

    check_url
    return unless self.persisted?
    fetch_repository
    find_or_create_host
    fetch_owner
    find_or_create_owner
    return if hidden_owner?

    fetch_dependencies
    fetch_packages
    import_mentions
    fetch_readme
    combine_keywords
    fetch_commits
    fetch_events
    fetch_issue_stats
    sync_issues
    fetch_citation_file
    fetch_codemeta
    fetch_zenodo_file
    sync_releases
    update_committers
    update_keywords_from_contributors
    update(last_synced_at: Time.now, matching_criteria: matching_criteria?)
    update_score
    update_science_score
    ping
  end

  def sync_async
    return if hidden_owner?
    return unless persisted?

    SyncProjectWorker.perform_async(id)
  end

  def check_url
    conn = Faraday.new(url: url) do |faraday|
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?
    update!(url: response.env.url.to_s) 
    # TODO avoid duplicates
  rescue ActiveRecord::RecordInvalid => e
    puts "Duplicate url #{url}"
    puts e.class
    destroy
  rescue
    puts "Error checking url for #{url}"
  end

  def combine_keywords
    all_keywords = []
    all_keywords += repository["topics"] if repository.present?
    all_keywords += packages.map{|p| p["keywords"]}.flatten if packages.present?
    self.keywords = all_keywords.reject(&:blank?).uniq { |keyword| keyword.downcase }.dup
    self.save
  rescue FrozenError
    puts "Error combining keywords for #{repository_url}"
  end

  def ping
    ping_urls.each do |url|
      Faraday.get(url, nil, {'User-Agent' => 'science.ecosyste.ms'}) rescue nil
    end
  end

  def ping_urls
    ([repos_ping_url] + [issues_ping_url] + [commits_ping_url] + packages_ping_urls + [owner_ping_url]).compact.uniq
  end

  def repos_ping_url
    return unless repository.present?
    "https://repos.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping"
  end

  def issues_ping_url
    return unless repository.present?
    "https://issues.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping"
  end

  def commits_ping_url
    return unless repository.present?
    "https://commits.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping"
  end

  def packages_ping_urls
    return [] unless packages.present?
    packages.map do |package|
      "https://packages.ecosyste.ms/api/v1/registries/#{package['registry']['name']}/packages/#{package['name']}/ping"
    end
  end

  def owner_ping_url
    return unless repository.present?
    "https://repos.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/owner/#{repository['owner']}/ping"
  end

  def repos_api_url
    "https://repos.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def repos_url
    return unless repository.present?
    "https://repos.ecosyste.ms/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}"
  end

  def fetch_repository
    conn = ecosystem_http_client(repos_api_url)

    response = conn.get
    return unless response.success?
    self.repository = JSON.parse(response.body)
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
      self.update_column(:owner_id, owner_record.id)
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

    self.update_column(:owner_id, owner_record.id)
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
    self.packages = JSON.parse(response.body)
    self.save
  rescue
    puts "Error fetching packages for #{repository_url}"
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

  def fetch_dependencies
    return unless repository.present?
    conn = ecosystem_http_client(repository['manifests_url'])
    response = conn.get
    return unless response.success?
    self.dependencies = JSON.parse(response.body)
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
    conn = Faraday.new(url: archive_url(readme_file_name)) do |faraday|
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
      faraday.headers['User-Agent'] = 'explore.market.dev'
    end
    response = conn.get
    return unless response.success?
    json = JSON.parse(response.body)
    json['contents'].gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def load_codemeta
    return unless download_url.present?
    return unless codemeta_file_name.present?
    conn = Faraday.new(url: archive_url(codemeta_file_name)) do |faraday|
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
      faraday.headers['User-Agent'] = 'explore.market.dev'
    end
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

    conn = Faraday.new(url: url) do |faraday|
      faraday.response :follow_redirects
      faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?
    response.body.gsub("\u0000", '').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def load_codemeta_fallback
    return unless repository.present?

    file_name = codemeta_file_name.presence || 'codemeta.json'
    url = raw_url(file_name)

    return unless url.present?

    conn = Faraday.new(url: url) do |faraday|
      faraday.response :follow_redirects
      faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
      faraday.adapter Faraday.default_adapter
    end

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
    return unless citation_file_name.present?
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
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{path}"
  end 

  def raw_url(path)
    return unless repository.present?
    "#{repository['html_url']}/raw/#{repository['default_branch']}/#{path}"
  end 

  def fetch_brief
    return unless repository.present?

    clone_url = repository['clone_url'].presence || repository_url
    cmd = ['brief', '-json', '-depth', '1', clone_url]
    out, err, status = Open3.capture3(*cmd)
    unless status.success?
      Rails.logger.warn "brief failed for #{repository_url}: #{err.to_s.lines.last&.strip}"
      return
    end

    data = JSON.parse(out)
    self.brief = {
      'version' => data['version'],
      'languages' => data['languages'],
      'package_managers' => data['package_managers'],
      'tools' => data['tools'],
      'resources' => data['resources'],
      'manifests' => data['manifests'],
      'lines' => data['lines'],
    }
    save
  rescue Errno::ENOENT
    Rails.logger.warn "brief binary not found; skipping fetch_brief for #{repository_url}"
  rescue JSON::ParserError => e
    Rails.logger.warn "brief output not JSON for #{repository_url}: #{e.message}"
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
      conn = Faraday.new(url: openalex_url) do |faraday|
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
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
    return unless repository.present?
    return unless repository['releases_url'].present?

    conn = ecosystem_http_client(repository['releases_url'] + '?per_page=1000')
    response = conn.get
    return unless response.success?
    releases = JSON.parse(response.body)

    releases.each do |release|
      r = Release.find_or_create_by(project_id: id, uuid: release['uuid'])
      r.update(Release.sync_attributes(release))
    end
  end
end
