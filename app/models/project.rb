require 'csv'
require 'matrix'
require 'tf-idf-similarity'
require 'stopwords'
require 'github/markup'

class Project < ApplicationRecord
  include EcosystemApiClient
  include Project::Importers

  def self.sortable_columns
    {
      'projects.updated_at' => 'projects.updated_at',
      'projects.created_at' => 'projects.created_at',
      'updated_at' => 'updated_at',
      'created_at' => 'created_at',
      'last_synced_at' => 'last_synced_at',
      'name' => 'name',
      'score' => 'score',
      'science_score' => 'science_score',
    }
  end

  validates :url, presence: true, uniqueness: { case_sensitive: false }
  validate :owner_not_hidden

  belongs_to :host, optional: true
  belongs_to :owner_record, class_name: 'Owner', foreign_key: 'owner_id', optional: true

  counter_culture :host, column_name: :repositories_count
  counter_culture :owner_record, column_name: :projects_count

  has_many :issues, dependent: :delete_all
  has_many :releases, dependent: :delete_all
  has_many :project_fields, dependent: :destroy
  has_many :fields, through: :project_fields
  has_many :mentions, dependent: :destroy
  has_many :papers, through: :mentions
  has_many :dependency_records, class_name: 'Dependency', dependent: :nullify
  has_many :votes, dependent: :delete_all

  has_many :good_first_issues, -> { good_first_issue }, class_name: 'Issue'

  scope :visible, -> {
    where(owner_id: nil).or(where.not(owner_id: Owner.hidden.select(:id)))
  }
  scope :active, -> { where("(repository ->> 'archived') = ?", 'false') }
  scope :archived, -> { where("(repository ->> 'archived') = ?", 'true') }

  scope :language, ->(language) { where("(repository ->> 'language') = ?", language) }
  scope :owner, ->(owner) { where("(repository ->> 'owner') = ?", owner) }
  scope :keyword, ->(keyword) { where("keywords @> ARRAY[?]::varchar[]", keyword) }
  scope :matching_criteria, -> { where(matching_criteria: true) }
  scope :with_works, -> { where('length(works::text) > 2') }
  scope :with_repository, -> { where.not(repository: nil) }
  scope :without_repository, -> { where(repository: nil) }
  scope :with_commits, -> { where.not(commits: nil) }
  scope :with_keywords, -> { where.not(keywords: []) }
  scope :without_keywords, -> { where(keywords: []) }
  scope :with_packages, -> { where.not(packages: [nil, []]) }
  scope :with_readme, -> { where.not(readme: nil) }
  scope :without_readme, -> { where(readme: nil) }
  scope :with_codemeta_file, -> { where("repository IS NOT NULL").where("(repository::jsonb->'metadata'->'files'->>'codemeta') IS NOT NULL") }
  scope :with_codemeta, -> { where.not(codemeta: nil) }
  scope :with_citation_file, -> { where.not(citation_file: nil) }
  scope :with_zenodo_file, -> { where("repository IS NOT NULL").where("(repository::jsonb->'metadata'->'files'->>'zenodo') IS NOT NULL") }
  scope :with_zenodo, -> { where.not(zenodo: nil) }

  scope :with_keywords_from_contributors, -> { where.not(keywords_from_contributors: []) }
  scope :without_keywords_from_contributors, -> { where(keywords_from_contributors: []) }
  
  scope :with_joss, -> { where.not(joss_metadata: nil) }
  scope :scientific, -> { where('science_score >= ?', 20) }
  scope :highly_scientific, -> { where('science_score >= ?', 75) }
  scope :should_sync, -> { where('last_synced_at IS NULL OR science_score IS NULL OR science_score > 0') }

  def self.for_owner(host, login)
    normalized_login = login.downcase
    owner_ids = host.owners.where('lower(login) = ?', normalized_login).select(:id)

    scope = unscoped.where(owner_id: owner_ids)
    scope = scope.or(
      unscoped.where(host_id: host.id).where(
        "lower(repository ->> 'owner') = :login OR lower(owner ->> 'login') = :login",
        login: normalized_login
      )
    )

    host_urls = [host.url]
    host_urls << 'https://github.com' if host.name.casecmp?('GitHub')
    host_urls.compact.map { |url| url.downcase.chomp('/') }.uniq.each do |host_url|
      escaped_login = sanitize_sql_like(normalized_login)
      scope = scope.or(unscoped.where('lower(url) LIKE ?', "#{host_url}/#{escaped_login}/%"))
    end

    scope
  end

  def self.owner_details_from_url(url)
    uri = URI.parse(url.to_s)
    return [nil, nil] if uri.host.blank?

    if uri.host.downcase.end_with?('.github.io')
      return [Host.find_by_name('GitHub'), uri.host.split('.').first]
    end

    owner_login = uri.path.split('/').reject(&:blank?).first
    owner_host = Host.find_by_name(uri.host)
    owner_host ||= Host.find_by_name(uri.host.split('.').first)
    [owner_host, owner_login]
  rescue URI::InvalidURIError
    [nil, nil]
  end


  def self.keywords
    @keywords ||= Project.pluck(:keywords).flatten.group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
  end

  def self.ignore_words
    ['0x0lobersyko', '3d', 'tag1', 'tag2', 'accessibility', 'acertea', 'addon', 'ai', 'ajax', 'algorithms', 'amazon', 'anakjalanan', 'analysis', 'analytics', 'android', 'angular', 'animation', 
    'apache-spark', 'api', 'api-client', 'api-rest', 'api-wrapper', 'app', 'arduino', 'array', 'artificial-intelligence', 'ast', 'async', 'atmosphere', 'australia', 'auth', 'authentication', 
    'automation', 'awesome', 'awesome-list', 'aws', 'azure', 'babel', 'backend', 'bash', 'bash-script', 'bdd', 'benchmark', 'big-data', 'bitcoin', 'blockchain', 'boilerplate', 'bootstrap', 
    'bot', 'browser', 'bsd3', 'building', 'c', 'c-plus-plus', 'cache', 'canvas', 'chatgpt', 'check', 'chrome', 'citation', 'classification', 'cli', 'client', 'cloud', 'clustering', 'cmake', 
    'cms', 'cnc', 'cnn', 'code', 'collaboration', 'collection', 'color', 'colors', 'command', 'command-line', 'command-line-tool', 'compiler', 'component', 'components', 'computer-vision', 
    'computing', 'concurrency', 'config', 'configuration', 'console', 'containers', 'core', 'couchdb', 'course', 'cpp', 'cpu', 'cran', 'credit', 'cross-platform', 'crypto', 'csharp', 'css', 
    'cuda', 'cuda-fortran', 'd3', 'd3js', 'dashboard', 'dashboards', 'dask', 'data', 'data-analysis', 'data-analysis-python', 'data-science', 'data-visualization', 'database', 'datacube', 
    'dataset', 'datasets', 'date', 'debug', 'deep-learning', 'definition', 'deploy', 'design', 'design-system', 'devops', 'diff', 'digital-public-goods', 'directory', 'distributed-systems', 
    'django', 'docker', 'documentation', 'dom', 'dotnet', 'download', 'downloader', 'dts', 'earth-engine', 'editor', 'education', 'elasticsearch', 'electricity', 'electron', 'email', 'emoji', 
    'encryption', 'energy', 'energy-monitor', 'engineering', 'env', 'environment', 'epanet-python-toolkit', 'erp', 'error', 'es2015', 'es6', 'eslint', 'eslint-plugin', 'eslintconfig', 
    'eslintplugin', 'esp8266', 'ethereum', 'events', 'express', 'expressjs', 'extension', 'fabric', 'facebook', 'farm', 'fast', 'fastapi', 'fetch', 'file', 'filter', 'finance', 'firebase', 
    'first-good-issue', 'flask', 'flat-file-db', 'fleet-management', 'fluentui', 'flutter', 'font', 'food', 'forecast', 'forecasting', 'form', 'format', 'forms', 'fortran', 'framework', 
    'front-end', 'frontend', 'fs', 'function', 'functional', 'functional-programming', 'functions', 'game', 'gdal-python', 'generator', 'geographic-information-systems', 'geopython', 
    'geospatial', 'ggplot2', 'gis', 'git', 'github', 'github-action', 'github-actions', 'go', 'golang', 'google', 'google-cloud', 'google-earth-engine', 'gpt', 'gpu', 'gpu-acceleration', 
    'gpu-computing', 'grafana', 'graph', 'graphql', 'gtfs', 'gui', 'hacktoberfest', 'hacktoberfest2020', 'hacktoberfest2021', 'hash', 'helm', 'helpers', 'herojoker', 'hfc', 
    'high-performance-computing', 'home-assistant', 'home-automation', 'homeassistant', 'hooks', 'hpc', 'html', 'html5', 'http', 'https', 'hyper-function-component', 'i18n', 'icon', 'image', 
    'image-classification', 'image-database', 'image-processing', 'image-segmentation', 'immutable', 'import', 'indoxcapital', 'influxdb', 'infrastructure', 'input', 'integration-tests', 'io', 
    'iobroker', 'ios', 'iot', 'iot-platform', 'ipython-notebook', 'java', 'javascript', 'jest', 'jokiml', 'joss', 'jquery', 'js', 'json', 'jsx', 'julia', 'jupyter', 'jupyter-lab', 
    'jupyter-notebook', 'jupyter-notebooks', 'jupyterhub', 'jwt', 'k8s', 'kotlin', 'kubernetes', 'landsat', 'language', 'laravel', 'leaflet', 'leaflet-plugins', 'library', 'lidar', 
    'linear-programming', 'lint', 'linux', 'linux-foundation', 'llm', 'log', 'logger', 'logging', 'machine-learning', 'machine-learning-algorithms', 'machine-translation', 'macos', 
    'management', 'manuscript', 'map', 'mapbox', 'mapping', 'maps', 'markdown', 'material', 'math', 'matlab', 'matlab-python-interface', 'matplotlib', 'mechanical-engineering', 'mejarobot', 
    'metadata', 'metrics', 'mhkit-python', 'microservice', 'microservices', 'microsoft', 'middleware', 'ml', 'mobile', 'mocha', 'modbus', 'model', 'modeling', 'modelling', 'models', 'module', 
    'modules', 'mongodb', 'monitoring', 'monorepo', 'monte-carlo-simulation', 'mqtt', 'mypy', 'mysql', 'nasa', 'nasa-data', 'native', 'natural-language-processing', 'netcdf', 'network', 
    'neural-network', 'neural-networks', 'news', 'nextjs', 'nlp', 'nlp-library', 'node', 'node-js', 'nodejs', 'npm', 'npm-package', 'numba', 'number', 'numpy', 'nutrition', 'nuxt', 
    'nuxt-module', 'nuxtjs', 'object', 'object-detection', 'odoo', 'open-data', 'open-source', 'openai', 'openai-gym', 'openapi', 'openfoodfacts', 'opensource', 'openstreetmap', 
    'optimization', 'orm', 'osm', 'overview', 'package', 'package-manager', 'pandas', 'parse', 'parser', 'path', 'pdf', 'peer-reviewed', 'performance', 'php', 'pi0', 'pipeline', 'platform', 
    'plotting', 'plotting-in-python', 'plugin', 'pluto-notebooks', 'poetry', 'polyfill', 'postcss', 'postgis', 'postgres', 'postgresql', 'programming', 'prometheus', 'prometheus-exporter', 
    'promise', 'protobuf', 'proxy', 'public-good', 'public-goods', 'push', 'pwa', 'pyam', 'pypi-package', 'pyqt5', 'pyspark', 'python', 'python-3', 'python-awips', 'python-client', 
    'python-library', 'python-module', 'python-package', 'python-toolkit', 'python-wrapper', 'python-wrappers', 'python3', 'python3-package', 'pytorch', 'query', 'queue', 'r', 'r-package', 
    'rails', 'random', 'random-walk', 'raspberry-pi', 'raster', 'react', 'react-component', 'react-hooks', 'react-native', 'reactive', 'reactjs', 'real-time', 'redis', 'redux', 'regex', 
    'regression', 'remote-sensing', 'reproducible-research', 'request', 'rest', 'rest-api', 'risk', 'robotics', 'router', 'rpc', 'rstats', 'rstudio', 'ruby', 'ruby-on-rails', 'runtime', 
    'rust', 'rust-lang', 's3', 'sample', 'sample-code', 'sass', 'satellite', 'satellite-data', 'satellite-imagery', 'satellite-images', 'scala', 'scenario', 'schema', 'science', 
    'scientific', 'scientific-computations', 'scientific-computing', 'scientific-machine-learning', 'scientific-names', 'scientific-research', 'scientific-visualization', 
    'scientific-workflows', 'scikit-learn', 'scipy', 'script', 'scss', 'sdk', 'search', 'security', 'segmentation', 'self-driving-car', 'sentinel', 'sentinel-1', 'serialization', 
    'server', 'serverless', 'shell', 'simulation', 'smart-meter', 'smarthome', 'snakemake', 'sort', 'space', 'spark', 'spatial', 'spring', 'spring-boot', 'sql', 'sqlite', 'standard', 
    'state', 'static-analyzer', 'statistics', 'storage', 'stream', 'string', 'style', 'styled-components', 'styleguide', 'svelte', 'svg', 'swagger', 'swift', 'table', 'tailwindcss', 'task', 
    'tea', 'teanager', 'template', 'tensorflow', 'terminal', 'test', 'testing', 'text', 'text-mining', 'theme', 'threejs', 'time', 'time-series', 'time-series-analysis', 'time-series-forecasting', 
    'timeseries', 'tool', 'toolkit', 'tools', 'torch', 'transit', 'transport', 'tree', 'trends', 'ts', 'tuning', 'tutorial', 'type', 'types', 'typescript', 'typescript-definitions', 'typings', 
    'ui', 'uk', 'unicode', 'url', 'util', 'utilities', 'utility', 'utils', 'validate', 'validation', 'validator', 'vector', 'video', 'view', 'visualization', 'vue', 'vue-component', 'vue3', 
    'vuejs', 'web', 'web-components', 'web-framework', 'web3', 'webapp', 'webgl', 'webgl2', 'webpack', 'webservice', 'website', 'websocket', 'windows', 'workflow', 'wrapper', 'xarray', 'xml', 
    'yaml', 'yeoman-generator', 'yii2', 'zigbee', 'zsh','linter','bayesian','sonarqube', 'sonarqube-plugin', 'social', 'terraform', 'nginx', 'detection','tauri','repository', 'boost','privacy',
    'mqtt-client', 'julia-language', 'linter', 'mesh-generation', 'rlang', 'hardware', 'conda-forge', 'static-site-generator', 'spec', 'specification', 'cartocss', 'solver', 'evaluation', 'opengl',
    'navigation', 'iot-application', 'aframe', 'web-api', 'django-rest-framework', 'transmission', 'data-visualisation', 'streamlit', 'linear-algebra', 'streamlit-webapp', 'tutorials',
    'connector', 'oop', 'development', 'random-forest', 'machinelearning', 'heroku', 'france', 'photography', 'complex-systems', 'docusaurus', 'r-stats', 'shapefile', 'optuna', 'webxr',
    'berlin', 'pathways', 'list', 'tiles', 'hafas', 'arduino-library', 'audio-processing', 'leafletjs'
  ]
  end

  def self.stop_words
    []
  end

  def self.update_matching_criteria
    all.find_each(&:update_matching_criteria)
  end

  def update_matching_criteria
    update(matching_criteria: matching_criteria?)
  end


  def self.relevant_keywords
    keywords.select{|k,v| v > 1}.map(&:first) - ignore_words
  end

  def self.domain_keywords(domain)
    Project.where(rubric: domain).pluck(:keywords).flatten.group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
  end

  def self.sync_least_recently_synced
    Project.should_sync.where(last_synced_at: nil).or(Project.should_sync.where("last_synced_at < ?", 1.day.ago)).order('last_synced_at asc nulls first').limit(500).each do |project|
      project.sync_async
    end
  end

  def self.sync_all
    Project.all.each do |project|
      project.sync_async
    end
  end

  def to_s
    name.presence || url
  end

  def repository_url
    repo_url = github_pages_to_repo_url(url)
    return repo_url if repo_url.present?
    url
  end

  def github_pages_to_repo_url(github_pages_url)
    return if github_pages_url.blank?
    match = github_pages_url.chomp('/').match(/https?:\/\/(.+)\.github\.io\/(.+)/)
    return nil unless match
  
    username = match[1]
    repo_name = match[2]
  
    "https://github.com/#{username}/#{repo_name}"
  end

  def first_created
    return unless repository.present?
    Time.parse(repository['created_at'])
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

  def description
    return read_attribute(:description) if read_attribute(:description).present?
    return unless repository.present?
    repository["description"]
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

  # TODO fetch repo dependencies
  # TODO fetch repo tags

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

  def committers_names
    return [] unless commits.present?
    return [] unless commits["committers"].present?
    commits["committers"].map{|c| c["name"].downcase }.uniq
  end

  def committers
    return [] unless commits.present?
    return [] unless commits["committers"].present?
    commits["committers"].map{|c| [c["name"].downcase, c["count"]]}.each_with_object(Hash.new {|h,k| h[k] = 0}) { |(x,d),h| h[x] += d }
  end

  def raw_committers
    return [] unless commits.present?
    return [] unless commits["committers"].present?
    commits["committers"]
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

  def ignored_ecosystems
    ['actions', 'docker', 'homebrew']
  end

  def dependency_packages
    return [] unless dependencies.present?
    dependencies.map{|d| d["dependencies"]}.flatten.select{|d| d['direct'] }.reject{|d| ignored_ecosystems.include?(d['ecosystem']) }.map{|d| [d['ecosystem'],d["package_name"].downcase]}.uniq
  end

  def dependency_ecosystems
    return [] unless dependencies.present?
    dependencies.map{|d| d["dependencies"]}.flatten.select{|d| d['direct'] }.reject{|d| ignored_ecosystems.include?(d['ecosystem']) }.map{|d| d['ecosystem']}.uniq
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

  def language
    return unless repository.present?
    repository['language']
  end

  def language_with_default
    language.presence || 'Unknown'
  end

  def issue_stats
    i = read_attribute(:issues_stats) || {}
    JSON.parse(i.to_json, object_class: OpenStruct)
  end

  def update_score
    update_attribute :score, score_parts.sum
  end

  def update_science_score
    result = calculate_science_score_breakdown
    update(science_score: result[:score], science_score_breakdown: result)
  end

  def science_score_breakdown
    # Return stored breakdown from database
    # This method should only be called from views/API, never calculate on the fly
    breakdown = read_attribute(:science_score_breakdown)
    breakdown&.with_indifferent_access
  end

  def calculate_science_score_breakdown
    # This method should only be called from background jobs
    # It performs expensive calculations including JOSS IDF analysis
    calculator = ScienceScoreCalculator.new(self)
    calculator.calculate
  end

  def joss_idf_score
    # This method should only be called from background jobs via calculate_science_score_breakdown
    # It may trigger expensive corpus building if cache is not available
    JossIdfAnalyzer.score_project(self)
  end

  def primary_field
    project_fields.primary.first&.field
  end
  
  def all_fields_with_confidence
    project_fields.to_a
                  .sort_by { |pf| -pf.confidence_score }
                  .map { |pf| [pf.field, pf.confidence_score] }
  end
  
  def update_field_classifications
    FieldClassifier.new.classify_and_save(self)
  end

  def score_parts
    [
      repository_score,
      packages_score,
      commits_score,
      dependencies_score,
      events_score
    ]
  end

  def repository_score
    return 0 unless repository.present?
    Math.log [
      (repository['stargazers_count'] || 0),
      (repository['open_issues_count'] || 0)
    ].sum
  end

  def packages_score
    return 0 unless packages.present?
    Math.log [
      packages.map{|p| p["downloads"] || 0 }.sum,
      packages.map{|p| p["dependent_packages_count"] || 0 }.sum,
      packages.map{|p| p["dependent_repos_count"] || 0 }.sum,
      packages.map{|p| p["docker_downloads_count"] || 0 }.sum,
      packages.map{|p| p["docker_dependents_count"] || 0 }.sum,
      packages.map{|p| p['maintainers'].map{|m| m['uuid'] } }.flatten.uniq.length
    ].sum
  end

  def commits_score
    return 0 unless commits.present?
    Math.log [
      (commits['total_committers'] || 0),
    ].sum
  end

  def dependencies_score
    return 0 unless dependencies.present?
    0
  end

  def events_score
    return 0 unless events.present?
    0
  end

  def owner_name
    return unless repository.present?
    repository['owner']
  end

  def hidden_owner?
    return true if owner_record&.hidden?

    owner_data = read_attribute(:owner)
    return true if owner_data.is_a?(Hash) && owner_data['hidden'] == true

    repository_data = read_attribute(:repository)
    url_host, url_login = self.class.owner_details_from_url(url)
    owner_host = host || url_host
    owner_login = owner_data['login'] if owner_data.is_a?(Hash)
    owner_login ||= repository_data['owner'] if repository_data.is_a?(Hash)
    owner_login ||= url_login

    return false if owner_host.nil? || owner_login.blank?

    owner_host.owners.hidden.where('lower(login) = ?', owner_login.downcase).exists?
  end

  def owner_not_hidden
    errors.add(:url, 'belongs to a hidden owner') if hidden_owner?
  end

  def avatar_url
    return unless repository.present?
    repository['icon_url']
  end

  def matching_criteria?
    good_topics? && external_users? && open_source_license? && active?
  end

  def high_quality?
    external_users? && open_source_license? && active?
  end

  def matching_topics
    (keywords & Project.relevant_keywords)
  end

  def no_bad_topics?
    (keywords & Project.stop_words).blank?
  end

  def good_topics?
    matching_topics.length > 0
  end

  def packages_count
    return 0 unless packages.present?
    packages.length
  end

  def monthly_downloads
    return 0 unless packages.present?
    packages.select{|p| p['downloads_period'] == 'last-month' }.map{|p| p["downloads"] || 0 }.sum
  end

  def downloads
    return 0 unless packages.present?
    packages.map{|p| p["downloads"] || 0 }.sum
  end

  def issue_associations
    return [] unless issues_stats.present?
    (issues_stats['issue_author_associations_count'].keys + issues_stats['pull_request_author_associations_count'].keys).uniq
  end

  def external_users?
    issue_associations.any?{|a| a.to_s != 'OWNER' && a.to_s != 'MEMBER' }
  end

  def repository_license
    return nil unless repository.present?
    repository['license'] || repository.dig('metadata', 'files', 'license')
  end

  def packages_licenses
    return [] unless packages.present?
    packages.map{|p| p['licenses'] }.compact
  end


  def open_source_license?
    (packages_licenses + [repository_license]).compact.uniq.any?
  end

  def past_year_total_commits
    return 0 unless commits.present?
    commits['past_year_total_commits'] || 0
  end

  def past_year_total_commits_exclude_bots
    return 0 unless commits.present?
    past_year_total_commits - past_year_total_bot_commits
  end

  def past_year_total_bot_commits
    return 0 unless commits.present?
    commits['past_year_total_bot_commits'].presence || 0
  end

  def commits_this_year?
    return false unless repository.present?
    if commits.present?
      past_year_total_commits_exclude_bots > 0
    else
      return false unless repository['pushed_at'].present?
      repository['pushed_at'] > 1.year.ago 
    end
  end

  def issues_this_year?
    return false unless issues_stats.present?
    return false unless issues_stats['past_year_issues_count'].present?
    (issues_stats['past_year_issues_count'] - issues_stats['past_year_bot_issues_count']) > 0
  end

  def pull_requests_this_year?
    return false unless issues_stats.present?
    return false unless issues_stats['past_year_pull_requests_count'].present?
    (issues_stats['past_year_pull_requests_count'] - issues_stats['past_year_bot_pull_requests_count']) > 0
  end

  def archived?
    return false unless repository.present?
    repository['archived']
  end

  def active?
    return false if archived?
    commits_this_year? || issues_this_year? || pull_requests_this_year?
  end

  def fork?
    return false unless repository.present?
    repository['fork']
  end


  def self.packages_sorted_ids
    Rails.cache.fetch('packages_projects_ids', expires_in: 2.hours) do
      visible
        .with_packages
        .where('science_score > 0')
        .sort_by { |p| p.packages.sum { |pkg| pkg['downloads'] || 0 } }
        .reverse
        .map(&:id)
    end
  end

  def self.packages_sorted
    project_ids = packages_sorted_ids
    Project.visible.where(id: project_ids).index_by(&:id).values_at(*project_ids).compact
  end

  def self.all_package_and_project_names
    Rails.cache.fetch('all_package_and_project_names', expires_in: 2.hours) do
      projects = packages_sorted
      package_names = projects.flat_map { |p| p.packages.map { |pkg| pkg['name'] } }.compact
      project_names = projects.map(&:name).compact
      (package_names + project_names).map(&:downcase).uniq.sort
    end
  end

  def self.stats_summary
    scope = Project.visible
    total_projects = scope.count
    scored_projects = scope.where.not(science_score: nil).count

    # Science score distribution
    score_distribution = scope.group(:science_score).count
    scientific_count = scope.scientific.count
    highly_scientific_count = scope.highly_scientific.count

    # Calculate averages for scored projects
    median_score = scope.where.not(science_score: nil).median(:science_score) rescue nil

    # Repository stats
    with_repo_count = scope.with_repository.count
    with_readme_count = scope.with_readme.count
    with_packages_count = scope.with_packages.count

    # Citation and metadata file counts
    with_citation_count = scope.where.not(citation_file: nil).count
    with_codemeta_count = scope.with_codemeta_file.count
    with_zenodo_count = scope.with_zenodo_file.count

    # JOSS stats
    joss_count = scope.with_joss.count

    # Institutional owners stats
    institutional_owners_count = Owner.institutional.count

    # Language distribution (top 10)
    language_distribution = scope.with_repository
      .where('science_score > 0')
      .where.not(repository: nil)
      .where("repository->>'language' IS NOT NULL")
      .group("repository->>'language'")
      .count
      .sort_by { |_, count| -count }
      .first(10)

    {
      total_projects: total_projects,
      scored_projects: scored_projects,
      scientific_projects: scientific_count,
      highly_scientific_projects: highly_scientific_count,
      median_science_score: median_score,
      projects_with_repository: with_repo_count,
      projects_with_readme: with_readme_count,
      projects_with_packages: with_packages_count,
      projects_with_citation_file: with_citation_count,
      projects_with_codemeta: with_codemeta_count,
      projects_with_zenodo: with_zenodo_count,
      joss_projects: joss_count,
      institutional_owners: institutional_owners_count,
      score_distribution: score_distribution,
      top_languages: language_distribution
    }
  end


  def self.calculate_idf(projects)
    return [] if projects.empty?

    # Prepare documents from projects
    documents = projects.map do |project|
      text_parts = []
      text_parts << project.name if project.name.present?
      text_parts << project.description if project.description.present?
      text_parts << project.preprocessed_readme if project.readme.present?
      text = text_parts.join(' ')
      
      # Remove stopwords
      filter = Stopwords::Snowball::Filter.new('en')
      filtered_text = filter.filter(text.downcase.split).join(' ')
      
      TfIdfSimilarity::Document.new(filtered_text)
    end

    # Create model
    model = TfIdfSimilarity::TfIdfModel.new(documents)

    # Get all terms from all documents
    all_terms = documents.flat_map(&:terms).uniq

    # Calculate IDF for each term
    idf_scores = {}
    all_terms.each do |term|
      idf_scores[term] = model.idf(term)
    end

    # Sort by IDF score (descending) and return as array of hashes
    idf_scores.sort_by { |_, score| -score }.map do |term, score|
      { term: term, score: score }
    end
  end

  def calculate_idf
    # Use the class method with an array containing just this project
    self.class.calculate_idf([self])
  end

  def preprocessed_readme
    return '' unless readme.present?
    
    begin
      html_content = GitHub::Markup.render(readme_file_name, readme.force_encoding("UTF-8"))
      
      # Extract text from HTML
      text = Nokogiri::HTML(html_content).text.strip.downcase
      # remove URLs
      text = text.gsub(/https?:\/\/[^\s]+/, '')
      # normalize whitespace
      text.gsub(/\s+/, ' ')
    rescue => e
      puts "Error preprocessing readme for #{repository_url}"
      p e.message
      p e.backtrace
      # Return empty string if any error occurs during rendering or processing
      ''
    end
  end

  def citation_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['citation']
  end

  def codemeta_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['codemeta']
  end

  def zenodo_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['zenodo']
  end

  def codemeta_json
    return nil unless codemeta.present?
    JSON.parse(codemeta)
  rescue JSON::ParserError => e
    puts "Error parsing codemeta JSON for project #{id} (#{url}): #{e.message}"
    nil
  end

  def zenodo_json
    return nil unless zenodo.present?
    JSON.parse(zenodo)
  rescue JSON::ParserError => e
    puts "Error parsing zenodo JSON for project #{id} (#{url}): #{e.message}"
    nil
  end

  def citation_cff
    return nil unless citation_file.present?
    CFF::Index.read(citation_file)
  rescue StandardError => e
    puts "Error parsing CFF for project #{id} (#{url}): #{e.message}"
    nil
  end

  def cff_to_codemeta
    cff = citation_cff
    return nil unless cff

    {
      "@context" => "https://w3id.org/codemeta/3.0",
      "@type" => "SoftwareSourceCode",
      "name" => cff.title,
      "description" => cff.abstract,
      "author" => cff.authors.map { |author| person_to_codemeta(author) },
      "datePublished" => cff.date_released&.to_s,
      "softwareVersion" => cff.version,
      "codeRepository" => cff.repository_code,
      "keywords" => cff.keywords,
      "license" => cff.license&.to_s,
      "url" => cff.url
    }.compact
  rescue StandardError => e
    puts "Error converting CFF to CodeMeta for project #{id} (#{url}): #{e.message}"
    nil
  end

  def person_to_codemeta(person)
    result = {
      "@type" => person.is_a?(CFF::Entity) ? "Organization" : "Person"
    }

    if person.is_a?(CFF::Entity)
      result["name"] = person.name if person.name.present?
    else
      # CFF::Person has given_names and family_names
      name_parts = []
      name_parts << person.given_names if person.given_names.present?
      name_parts << person.family_names if person.family_names.present?
      result["name"] = name_parts.join(" ") if name_parts.any?
      result["givenName"] = person.given_names if person.given_names.present?
      result["familyName"] = person.family_names if person.family_names.present?
    end

    result["email"] = person.email if person.email.present?
    result["@id"] = person.orcid if person.orcid.present?
    result["affiliation"] = person.affiliation if person.affiliation.present?
    result
  end

  def exportable_metadata
    codemeta_json || cff_to_codemeta
  end

  def export_citation(format: 'bibtex')
    case format.to_s
    when 'bibtex'
      export_bibtex
    when 'apalike', 'apa'
      export_apalike
    else
      nil
    end
  rescue StandardError => e
    puts "Error exporting citation for project #{id} (#{url}) to #{format}: #{e.message}"
    nil
  end

  def export_bibtex
    return citation_cff.to_bibtex if citation_cff.present?
    nil
  end

  def export_apalike
    return citation_cff.to_apalike if citation_cff.present?
    nil
  end

  def download_url
    return unless repository.present?
    repository['download_url']
  end

  def readme_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['readme']
  end

  def readme_is_markdown?
    return unless readme_file_name.present?
    readme_file_name.downcase.ends_with?('.md') || readme_file_name.downcase.ends_with?('.markdown')
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

  def readme_url
    return unless repository.present?
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{readme_file_name}"
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

  def parse_citation_file
    return unless citation_file.present?
    CFF::Index.read(citation_file).as_json
  rescue
    puts "Error parsing citation file for #{repository_url}"
  end

  def blob_url(path)
    return unless repository.present?
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{path}"
  end 

  def raw_url(path)
    return unless repository.present?
    "#{repository['html_url']}/raw/#{repository['default_branch']}/#{path}"
  end 

  def commiter_domains
    return unless commits.present?
    return unless commits['committers'].present?
    commits['committers'].map{|c| c['email'].split('@')[1].try(:downcase) }.reject{|e| e.nil? || ignored_domains.include?(e) || e.ends_with?('.local') || e.split('.').length ==1  }.group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
  end

  def filtered_commiter_domains
    # Show top 20 domains plus any academic domains (even if not in top 20)
    all_domains = commiter_domains || []
    return [] if all_domains.empty?

    top_20 = all_domains.first(20)
    academic_domains = all_domains.select { |domain, _count| is_academic_domain?(domain) }

    # Combine and deduplicate while preserving order
    (top_20 + academic_domains).uniq
  end

  def is_academic_domain?(domain)
    return false unless domain.present?

    # Check if domain contains any academic pattern
    ScienceScoreCalculator::ACADEMIC_DOMAINS.any? do |pattern|
      domain.include?(pattern)
    end
  end

  def ignored_domains
    ['users.noreply.github.com', "googlemail.com", "gmail.com", "hotmail.com", "outlook.com","yahoo.com","protonmail.com","web.de","example.com","live.com","icloud.com","hotmail.fr","yahoo.se","yahoo.fr"]
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

    # TODO pagination
    # TODO upsert (plus unique index)

    issues_json.each do |issue|
      i = issues.find_or_create_by(number: issue['number']) 
      i.assign_attributes(issue)
      i.save(touch: false)
    end
  end

  def funding_links
    (package_funding_links + repo_funding_links + owner_funding_links + readme_funding_links).uniq
  end

  def package_funding_links
    return [] unless packages.present?
    packages.map{|pkg| pkg['metadata']['funding'] }.compact.map{|f| f.is_a?(Hash) ? f['url'] : f }.flatten.compact
  end

  def owner_funding_links
    return [] if repository.blank? || repository['owner_record'].blank? ||  repository['owner_record']["metadata"].blank?
    return [] unless repository['owner_record']["metadata"]['has_sponsors_listing']
    ["https://github.com/sponsors/#{repository['owner_record']['login']}"]
  end

  def repo_funding_links
    return [] if repository.blank? || repository['metadata'].blank? ||  repository['metadata']["funding"].blank?
    return [] if repository['metadata']["funding"].is_a?(String)
    repository['metadata']["funding"].map do |key,v|
      next if v.blank?
      case key
      when "github"
        Array(v).map{|username| "https://github.com/sponsors/#{username}" }
      when "tidelift"
        "https://tidelift.com/funding/github/#{v}"
      when "community_bridge"
        "https://funding.communitybridge.org/projects/#{v}"
      when "issuehunt"
        "https://issuehunt.io/r/#{v}"
      when "open_collective"
        "https://opencollective.com/#{v}"
      when "ko_fi"
        "https://ko-fi.com/#{v}"
      when "liberapay"
        "https://liberapay.com/#{v}"
      when "custom"
        v
      when "otechie"
        "https://otechie.com/#{v}"
      when "patreon"
        "https://patreon.com/#{v}"
      when "polar"
        "https://polar.sh/#{v}"
      when 'buy_me_a_coffee'
        "https://buymeacoffee.com/#{v}"
      when 'thanks_dev'
        "https://thanks.dev/#{v}"
      else
        v
      end
    end.flatten.compact
  end

  def readme_urls
    return [] unless readme.present?
    urls = URI.extract(readme.gsub(/[\[\]]/, ' '), ['http', 'https']).uniq
    # remove trailing garbage
    urls.map{|u| u.gsub(/\:$/, '').gsub(/\*$/, '').gsub(/\.$/, '').gsub(/\,$/, '').gsub(/\*$/, '').gsub(/\)$/, '').gsub(/\)$/, '').gsub('&nbsp;','') }
  end

  def readme_domains
    readme_urls.map{|u| URI.parse(u).host rescue nil }.compact.uniq
  end

  def funding_domains
    ['opencollective.com', 'ko-fi.com', 'liberapay.com', 'patreon.com', 'otechie.com', 'issuehunt.io', 'thanks.dev',
    'communitybridge.org', 'tidelift.com', 'buymeacoffee.com', 'paypal.com', 'paypal.me','givebutter.com', 'polar.sh']
  end

  def readme_funding_links
    urls = readme_urls.select{|u| funding_domains.any?{|d| u.include?(d) } || u.include?('github.com/sponsors') }.reject{|u| ['.svg', '.png'].include? File.extname(URI.parse(u).path) }
    # remove anchors
    urls = urls.map{|u| u.gsub(/#.*$/, '') }.uniq
    # remove sponsor/9/website from open collective urls
    urls = urls.map{|u| u.gsub(/\/sponsor\/\d+\/website$/, '') }.uniq
  end

  def doi_domains
    ['doi.org', 'dx.doi.org', 'www.doi.org']
  end

  def readme_doi_urls
    readme_urls.select{|u| doi_domains.include?(URI.parse(u).host) }.uniq
  end

  def dois
    readme_doi_urls.map{|u| URI.parse(u).path.gsub(/^\//, '') }.uniq
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
  
  def citation_counts
    works.select{|k,v| v.present? }.map{|k,v| [k, v['counts_by_year'].map{|h| h["cited_by_count"]}.sum] }.to_h
  end

  def total_citations
    citation_counts.values.sum
  end

  def first_work_citations
    citation_counts.values.first
  end

  def readme_image_urls
    return [] unless readme.present?
    urls = readme.scan(/!\[.*?\]\((.*?)\)/).flatten.compact.uniq

    # also sc`an for html images
    urls += readme.scan(/<img.*?src="(.*?)"/).flatten.compact.uniq

    # turn relative urls into absolute urls
    # remove anything after a space
    urls = urls.map{|u| u.split(' ').first }.compact.uniq
    
    urls = urls.map do |u|
      if !u.starts_with?('http')
        # if url starts with slash or alpha character, prepend repo url
        if u.starts_with?('/') || u.match?(/^[[:alpha:]]/)
          raw_url(u)
        end
      else
        u
      end
    end.compact
  end

  def update_committers
    return unless commits.present?
    return unless commits['committers'].present?
    commits['committers'].each do |committer|
      c = Contributor.find_or_create_by(email: committer['email'])
      if keywords.present?
        c.topics = (c.topics + keywords).uniq
      end
      
      c.categories = (c.categories + [category]).uniq if category
      c.sub_categories = (c.sub_categories + [sub_category]).uniq if sub_category
      c.update(committer.except('count'))
    end
  end

  def contributors
    return unless commits.present?
    return unless commits['committers'].present?
    Contributor.where(email: commits['committers'].map{|c| c['email'] }.uniq)
  end

  def contributor_topics(limit: 10, minimum: 3)
    return {} unless commits.present?
    return {} unless commits['committers'].present?
    return {} unless contributors.length > 1

    ignored_keywords = (keywords + Project.ignore_words).uniq

    all_topics = contributors.flat_map { |c| c.topics }.reject{|t| ignored_keywords.include?(t) }
    
    # Group by the stemmed version of the topic
    grouped_topics = all_topics.group_by { |topic| topic.stem }

    # For each group, keep one of the original topics and count the occurrences
    topic_counts = grouped_topics.map do |stemmed_topic, original_topics|
      [original_topics.first, original_topics.size]
    end.to_h

    popular_topics = topic_counts.reject{|t,c| c < minimum }.sort_by { |topic, count| -count }.first(limit).to_h
  end

  def update_keywords_from_contributors
    ct = contributor_topics(limit: 10, minimum: 3)
    update(keywords_from_contributors: ct.keys) if ct.present?
  end

  def self.unique_keywords_for_category(category)
    # Get all keywords from all categories
    all_keywords = Project.where.not(category: category).pluck(:keywords).flatten

    # Get keywords from the specific category
    category_keywords = Project.where(category: category).pluck(:keywords).flatten

    # Get keywords that only appear in the specific category
    unique_keywords = category_keywords - all_keywords

    # remove stop words
    unique_keywords = unique_keywords - ignore_words

    # Group the unique keywords by their values and sort them by the size of each group
    sorted_keywords = unique_keywords.group_by { |keyword| keyword }.sort_by { |keyword, occurrences| -occurrences.size }.map(&:first)
    sorted_keywords
  end

  def self.unique_keywords_for_sub_category(subcategory)
    # Get all keywords from all subcategory
    all_keywords = Project.where.not(sub_category: subcategory).pluck(:keywords).flatten

    # Get keywords from the specific subcategory
    subcategory_keywords = Project.where(sub_category: subcategory).pluck(:keywords).flatten

    # Get keywords that only appear in the specific subcategory
    unique_keywords = subcategory_keywords - all_keywords

    # remove stop words
    unique_keywords = unique_keywords - ignore_words

    # Group the unique keywords by their values and sort them by the size of each group
    sorted_keywords = unique_keywords.group_by { |keyword| keyword }.sort_by { |keyword, occurrences| -occurrences.size }.map(&:first)
    sorted_keywords
  end

  def self.all_category_keywords
    @all_category_keywords ||= Project.where.not(category: nil).pluck(:category).uniq.map do |category|
      {
        category: category,
        keywords: unique_keywords_for_category(category)
      }
    end
  end

  def self.all_sub_category_keywords
    @all_sub_category_keywords ||= Project.where.not(sub_category: nil).pluck(:sub_category).uniq.map do |subcategory|
      {
        sub_category: subcategory,
        keywords: unique_keywords_for_sub_category(subcategory)
      }
    end
  end

  def suggest_category
    return unless keywords.present?

    cat = Project.all_category_keywords.map do |category|
      {
        category: category[:category],
        score: (keywords & category[:keywords]).length
      }
    end.sort_by{|c| -c[:score] }.first
    return nil if cat[:score] == 0
    cat
  end

  def suggest_sub_category
    return unless keywords.present?

    cat = Project.all_sub_category_keywords.map do |subcategory|
      {
        sub_category: subcategory[:sub_category],
        score: (keywords & subcategory[:keywords]).length
      }
    end.sort_by{|c| -c[:score] }.first
    return nil if cat[:score] == 0
    cat
  end

  def self.category_tree
    results = visible.group(:category, :sub_category).count

    results.group_by { |(category, _), _| category }.map do |category, rows|
      {
        category: category,
        count: rows.sum { |_, count| count },
        sub_categories: rows.map do |(_, sub_category), count|
          {
            sub_category: sub_category,
            count: count
          }
        end
      }
    end
  end

  def self.sync_dependencies(min_count: 10)
    dependencies = Project.map(&:dependency_packages).flatten(1).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse

    dependencies.each do |(ecosystem, package_name), count|
      puts "Checking #{ecosystem} #{package_name}"

      dependency = Dependency.find_or_create_by(ecosystem: ecosystem, name: package_name)

      dependency.update(count: count)

      next if dependency.package.present?

      dependency.sync_package if count > min_count
    end
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

  def import_mentions
    return [] unless packages.present?

    created_mentions = []

    packages.each do |package|
      next unless package['ecosystem'].present? && package['name'].present?

      ecosystem = package['ecosystem']
      name = package['name']

      puts "Fetching mentions for #{ecosystem}/#{name}"

      page = 1
      per_page = 1000

      loop do
        mentions_url = "https://papers.ecosyste.ms/api/v1/projects/#{ecosystem}/#{name}/mentions?page=#{page}&per_page=#{per_page}"
        conn = ecosystem_http_client(mentions_url)

        response = conn.get
        break unless response.success?

        mentions_data = JSON.parse(response.body)
        break if mentions_data.empty?

        mentions_data.each do |mention_data|
          next unless mention_data['paper_url'].present?

          # Fetch and create/update paper
          paper = fetch_or_create_paper(mention_data['paper_url'])
          next unless paper

          # Create mention if it doesn't exist
          mention = Mention.find_or_create_by(paper: paper, project: self)
          created_mentions << mention
        end

        # If we got fewer results than per_page, we're on the last page
        break if mentions_data.length < per_page

        page += 1
      end
    end

    created_mentions
  rescue => e
    puts "Error importing mentions: #{e.message}"
    []
  end

  def fetch_or_create_paper(paper_url)
    conn = ecosystem_http_client(paper_url)
    response = conn.get
    return unless response.success?

    paper_data = JSON.parse(response.body)

    paper = Paper.find_or_initialize_by(doi: paper_data['doi']) if paper_data['doi'].present?
    paper ||= Paper.find_or_initialize_by(openalex_id: paper_data['openalex_id']) if paper_data['openalex_id'].present?
    paper ||= Paper.new

    paper.assign_attributes(
      doi: paper_data['doi'],
      openalex_id: paper_data['openalex_id'],
      title: paper_data['title'],
      publication_date: paper_data['publication_date'],
      openalex_data: paper_data['openalex_data'],
      last_synced_at: Time.now
    )

    paper.save
    paper
  rescue => e
    puts "Error fetching paper from #{paper_url}: #{e.message}"
    nil
  end

end
