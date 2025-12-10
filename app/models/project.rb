require 'csv'
require 'matrix'
require 'tf-idf-similarity'
require 'stopwords'
require 'github/markup'

class Project < ApplicationRecord
  include EcosystemApiClient

  validates :url, presence: true, uniqueness: { case_sensitive: false }

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

  has_many :good_first_issues, -> { good_first_issue }, class_name: 'Issue'

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

  scope :with_keywords_from_contributors, -> { where.not(keywords_from_contributors: []) }
  scope :without_keywords_from_contributors, -> { where(keywords_from_contributors: []) }
  
  scope :with_joss, -> { where.not(joss_metadata: nil) }
  scope :scientific, -> { where('science_score >= ?', 20) }
  scope :highly_scientific, -> { where('science_score >= ?', 75) }
  scope :should_sync, -> { where('last_synced_at IS NULL OR science_score IS NULL OR science_score > 0') }

  def self.import_from_csv(url)
    conn = Faraday.new(url: url) do |faraday|
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?
    csv = response.body
    csv_data = CSV.new(csv, headers: true)

    csv_data.each do |row|
      next if row['git_url'].blank?
      project = Project.find_or_create_by(url: row['git_url'].downcase)
      project.name = row['project_name']
      project.description = row['oneliner']
      project.rubric = row['rubric']
      project.save
      project.sync_async unless project.last_synced_at.present?
    end
  end

  def self.import_science_csv(file_path = 'data/science.csv', batch_size: 1000, sync: false)
    unless File.exist?(file_path)
      puts "File not found: #{file_path}"
      return
    end

    imported_count = 0
    existing_count = 0
    failed_count = 0
    projects_to_sync = []
    
    CSV.foreach(file_path, headers: true).with_index do |row, index|
      next if row['HTML URL'].blank?
      
      url = row['HTML URL'].downcase
      
      begin
        project = Project.find_or_initialize_by(url: url)
        
        if project.new_record?
          if project.save
            imported_count += 1
            projects_to_sync << project.id if sync
          else
            failed_count += 1
            puts "Failed to save: #{url} - #{project.errors.full_messages.join(', ')}"
          end
        else
          existing_count += 1
        end
        
        # Print progress every batch_size rows
        if (index + 1) % batch_size == 0
          puts "Processed #{index + 1} rows: #{imported_count} imported, #{existing_count} existing, #{failed_count} failed"
          
          # Trigger sync for batch if requested
          if sync && projects_to_sync.any?
            puts "  Queuing sync for #{projects_to_sync.length} projects..."
            projects_to_sync.each { |id| SyncProjectWorker.perform_async(id) }
            projects_to_sync = []
          end
        end
      rescue => e
        failed_count += 1
        puts "Error processing row #{index + 1}: #{e.message}"
      end
    end
    
    # Sync remaining projects
    if sync && projects_to_sync.any?
      puts "Queuing sync for final #{projects_to_sync.length} projects..."
      projects_to_sync.each { |id| SyncProjectWorker.perform_async(id) }
    end
    
    puts "\n=== Import Complete ==="
    puts "Imported: #{imported_count} new projects"
    puts "Existing: #{existing_count} projects already in database"
    puts "Failed: #{failed_count} projects"
    puts "Total in database: #{Project.count}"
    
    { imported: imported_count, existing: existing_count, failed: failed_count }
  end

  def self.discover_via_topics(limit=100)
    relevant_keywords.shuffle.first(limit).each do |topic|
      import_topic(topic)
    end
  end

  def self.discover_via_keywords(limit=100)
    relevant_keywords.shuffle.first(limit).each do |topic|
      import_keyword(topic)
    end
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

  def self.sync_least_recently_synced_reviewed
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
    check_url
    return unless self.persisted?
    fetch_repository
    find_or_create_host
    fetch_owner
    find_or_create_owner
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
    sync_releases
    update_committers
    update_keywords_from_contributors
    update(last_synced_at: Time.now, matching_criteria: matching_criteria?)
    update_score
    update_science_score
    ping
  end

  def sync_async
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

    owner_record = Owner.find_or_initialize_by(
      host: host,
      login: owner_data['login'].downcase
    )

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
      hidden: owner_data['hidden']
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

  def language
    return unless repository.present?
    repository['language']
  end

  def owner_name
    return unless repository.present?
    repository['owner']
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

  def self.import_topic(topic)
    resp = ecosystem_http_get("https://repos.ecosyste.ms/api/v1/topics/#{ERB::Util.url_encode(topic)}?per_page=100&sort=created_at&order=desc")
    if resp.status == 200
      data = JSON.parse(resp.body)
      urls = data['repositories'].map{|p| p['html_url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        existing_project = Project.find_by(url: url.downcase)
        if existing_project.present?
          #puts 'already exists'
        else
          project = Project.create(url: url.downcase)
          project.sync_async
        end
      end
    end
  end

  def self.import_keyword(keyword)
    resp = ecosystem_http_get("https://packages.ecosyste.ms/api/v1/keywords/#{ERB::Util.url_encode(keyword)}?per_page=100&sort=created_at&order=desc")
    if resp.status == 200
      data = JSON.parse(resp.body)
      urls = data['packages'].reject{|p| p['status'].present? }.map{|p| p['repository_url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        existing_project = Project.find_by(url: url.downcase)
        if existing_project.present?
          # puts 'already exists'
        else
          project = Project.create(url: url.downcase)
          project.sync_async
        end
      end
    end
  end

  def self.import_org(host, org)
    resp = ecosystem_http_get("https://repos.ecosyste.ms/api/v1/hosts/#{host}/owners/#{org}/repositories?per_page=100")
    if resp.status == 200
      data = JSON.parse(resp.body)
      urls = data.map{|p| p['html_url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        existing_project = Project.find_by(url: url)
        if existing_project.present?
          # puts 'already exists'
        else
          project = Project.create(url: url)
          project.sync_async
        end
      end
    end
  end

  def self.import_from_cran
    import_from_registry('cran.r-project.org', 'CRAN')
  end

  def self.import_from_bioconductor
    import_from_registry('bioconductor.org', 'Bioconductor')
  end

  def self.import_from_conda_forge
    import_from_registry('conda-forge.org', 'conda-forge')
  end

  def self.top_joss_topics(limit = 50)
    # Get all keywords/topics from JOSS projects
    joss_projects = Project.with_joss.with_keywords
    
    # Count frequency of each keyword
    keyword_counts = Hash.new(0)
    joss_projects.each do |project|
      project.keywords.each do |keyword|
        # Skip common/generic keywords that aren't useful topics
        next if keyword.blank?
        next if keyword.length < 3
        keyword_counts[keyword.downcase] += 1
      end
    end
    
    # Sort by frequency and take top N
    keyword_counts.sort_by { |_, count| -count }.first(limit).map(&:first)
  end

  def self.import_all_joss_topics
    topics = top_joss_topics(50)
    
    if topics.empty?
      puts "No topics found from JOSS projects"
      return
    end
    
    puts "Found #{topics.length} top topics from JOSS projects"
    puts "Topics: #{topics.join(', ')}"
    puts "\n" + "="*60 + "\n"
    
    total_stats = { created: 0, existing: 0 }
    
    topics.each_with_index do |topic, index|
      puts "\n[#{index + 1}/#{topics.length}] Importing topic: #{topic}"
      puts "-"*40
      
      # Import repositories for this topic
      stats = import_from_github_topic(topic)
      total_stats[:created] += stats[:created]
      total_stats[:existing] += stats[:existing]
      
      # Brief pause to avoid rate limiting
      sleep(1)
    end
    
    puts "\n" + "="*60
    puts "=== All JOSS Topics Import Complete ==="
    puts "Total new projects created: #{total_stats[:created]}"
    puts "Total existing projects found: #{total_stats[:existing]}"
    puts "Grand total: #{total_stats[:created] + total_stats[:existing]}"
  end

  def self.import_from_package_keyword(keyword, max_pages = 10)
    puts "Starting package keyword import for '#{keyword}'..."
    page = 1
    total_created = 0
    total_existing = 0
    total_skipped = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://packages.ecosyste.ms/api/v1/keywords/#{CGI.escape(keyword)}?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      data = JSON.parse(response.body)
      packages = data['packages'] || []
      break if packages.empty?
      
      packages.each do |package|
        # Skip if no repository URL
        if package['repository_url'].blank?
          total_skipped += 1
          next
        end
        
        # Only process GitHub repositories
        unless package['repository_url'].downcase.include?('github.com')
          total_skipped += 1
          next
        end
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = package['repository_url'].downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
        else
          project = Project.create(url: repo_url)
          if project.persisted?
            project.sync_async
            total_created += 1
            puts "  Created: #{repo_url}"
          else
            puts "  Failed to create: #{repo_url} - #{project.errors.full_messages.join(', ')}"
          end
        end
      end
      
      puts "Page #{page} processed - Created: #{total_created}, Existing: #{total_existing}, Skipped: #{total_skipped}"
      page += 1
      
      # Stop after max_pages
      if page > max_pages
        puts "Reached maximum page limit (#{max_pages})"
        break
      end
    end
    
    puts "\n=== Package Keyword '#{keyword}' Import Complete ==="
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Total packages skipped (no GitHub URL): #{total_skipped}"
    puts "Grand total GitHub projects: #{total_created + total_existing}"
    
    # Return stats for aggregation
    { created: total_created, existing: total_existing, skipped: total_skipped }
  end

  def self.import_all_joss_keywords
    keywords = top_joss_topics(50)
    
    if keywords.empty?
      puts "No keywords found from JOSS projects"
      return
    end
    
    puts "Found #{keywords.length} top keywords from JOSS projects"
    puts "Keywords: #{keywords.join(', ')}"
    puts "\n" + "="*60 + "\n"
    
    total_stats = { created: 0, existing: 0, skipped: 0 }
    
    keywords.each_with_index do |keyword, index|
      puts "\n[#{index + 1}/#{keywords.length}] Importing packages with keyword: #{keyword}"
      puts "-"*40
      
      # Import packages for this keyword
      stats = import_from_package_keyword(keyword)
      total_stats[:created] += stats[:created]
      total_stats[:existing] += stats[:existing]
      total_stats[:skipped] += stats[:skipped]
      
      # Brief pause to avoid rate limiting
      sleep(1)
    end
    
    puts "\n" + "="*60
    puts "=== All JOSS Keywords Package Import Complete ==="
    puts "Total new projects created: #{total_stats[:created]}"
    puts "Total existing projects found: #{total_stats[:existing]}"
    puts "Total packages skipped (no GitHub URL): #{total_stats[:skipped]}"
    puts "Grand total GitHub projects: #{total_stats[:created] + total_stats[:existing]}"
  end

  def self.github_owners(min_science_score = 20)
    # Extract unique GitHub owner names from projects with reasonable science score
    owners = []
    
    scope = Project.with_repository
    scope = scope.where('science_score >= ?', min_science_score) if min_science_score > 0
    
    scope.find_each do |project|
      # Match GitHub URLs and extract owner
      if project.url =~ /github\.com\/([^\/]+)\//i
        owner = $1.downcase
        owners << owner unless owner.blank?
      end
    end
    
    owners.uniq.sort
  end

  def self.scientific_github_owners
    # Convenience method for owners from scientific projects (score >= 20)
    github_owners(20)
  end

  def self.import_from_ost
    puts "Importing reviewed projects from OST..."
    page = 1
    total_imported = 0
    
    loop do
      url = "https://ost.ecosyste.ms/api/v1/projects?reviewed=true&page=#{page}"
      conn = Faraday.new(url: url) do |faraday|
        faraday.headers['User-Agent'] = 'science.ecosyste.ms'
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 1, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      begin
        response = conn.get
        break unless response.success?
        
        projects = JSON.parse(response.body)
        break if projects.empty?
        
        projects.each do |project_data|
          next unless project_data['url'].present?
          
          # Only import GitHub projects for now
          next unless project_data['url'].include?('github.com')
          
          existing = Project.find_by(url: project_data['url'])
          if existing.nil?
            project = Project.create(url: project_data['url'])
            if project.persisted?
              project.sync_async
              total_imported += 1
              puts "Imported: #{project_data['url']}"
            end
          else
            puts "Already exists: #{project_data['url']}"
          end
        end
        
        page += 1
        puts "Processed page #{page - 1}, total imported: #{total_imported}"
        
        # Safety limit
        break if page > 100
      rescue => e
        puts "Error on page #{page}: #{e.message}"
        break
      end
    end
    
    puts "Import complete. Total imported: #{total_imported}"
  end

  def self.packages_sorted_ids
    Rails.cache.fetch('packages_projects_ids', expires_in: 2.hours) do
      with_packages
        .where('science_score > 0')
        .sort_by { |p| p.packages.sum { |pkg| pkg['downloads'] || 0 } }
        .reverse
        .map(&:id)
    end
  end

  def self.packages_sorted
    project_ids = packages_sorted_ids
    Project.where(id: project_ids).index_by(&:id).values_at(*project_ids).compact
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
    total_projects = Project.count
    scored_projects = Project.where.not(science_score: nil).count

    # Science score distribution
    score_distribution = Project.group(:science_score).count
    scientific_count = Project.scientific.count
    highly_scientific_count = Project.highly_scientific.count

    # Calculate averages for scored projects
    median_score = Project.where.not(science_score: nil).median(:science_score) rescue nil

    # Repository stats
    with_repo_count = Project.with_repository.count
    with_readme_count = Project.with_readme.count
    with_packages_count = Project.with_packages.count

    # Citation and metadata file counts
    with_citation_count = Project.where.not(citation_file: nil).count
    with_codemeta_count = Project.with_codemeta_file.count
    with_zenodo_count = Project.with_zenodo_file.count

    # JOSS stats
    joss_count = Project.with_joss.count

    # Institutional owners stats
    institutional_owners_count = Owner.institutional.count

    # Language distribution (top 10)
    language_distribution = Project.with_repository
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

  def self.import_from_github_owner(owner, max_pages = 10)
    puts "Starting GitHub owner import for '#{owner}'..."
    page = 1
    total_created = 0
    total_existing = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/#{owner}/repositories?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      repositories = JSON.parse(response.body)
      break if repositories.empty?
      
      repositories.each do |repo|
        next if repo['html_url'].blank?
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = repo['html_url'].downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
        else
          project = Project.create(url: repo_url)
          if project.persisted?
            project.sync_async
            total_created += 1
            puts "  Created: #{repo_url}"
          else
            puts "  Failed to create: #{repo_url} - #{project.errors.full_messages.join(', ')}"
          end
        end
      end
      
      puts "Page #{page} processed - Created: #{total_created}, Existing: #{total_existing}"
      page += 1
      
      # Stop after max_pages
      if page > max_pages
        puts "Reached maximum page limit (#{max_pages})"
        break
      end
    end
    
    puts "\n=== GitHub Owner '#{owner}' Import Complete ==="
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Grand total: #{total_created + total_existing}"
    
    # Return stats for aggregation
    { created: total_created, existing: total_existing }
  end

  def self.import_from_papers
    puts "Starting papers.ecosyste.ms import..."
    page = 1
    total_created = 0
    total_existing = 0
    total_skipped = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://papers.ecosyste.ms/api/v1/projects?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      projects = JSON.parse(response.body)
      break if projects.empty?
      
      projects.each do |project|
        # Skip if no package field or package is null
        if project['package'].blank?
          total_skipped += 1
          next
        end
        
        # Extract repository URL from package field
        repository_url = project['package']['repository_url']
        
        # Skip if no repository URL
        if repository_url.blank?
          total_skipped += 1
          next
        end
        
        # Only process GitHub repositories
        unless repository_url.downcase.include?('github.com')
          total_skipped += 1
          next
        end
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = repository_url.downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
        else
          new_project = Project.create(url: repo_url)
          if new_project.persisted?
            new_project.sync_async
            total_created += 1
            puts "  Created: #{repo_url}"
          else
            puts "  Failed to create: #{repo_url} - #{new_project.errors.full_messages.join(', ')}"
          end
        end
      end
      
      puts "Page #{page} processed - Created: #{total_created}, Existing: #{total_existing}, Skipped: #{total_skipped}"
      page += 1
    end
    
    puts "\n=== Papers Import Complete ==="
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Total projects skipped (no GitHub URL): #{total_skipped}"
    puts "Grand total GitHub projects: #{total_created + total_existing}"
  end

  def self.import_all_github_owners(limit = nil, min_science_score = 20)
    owners = github_owners(min_science_score)
    owners = owners.first(limit) if limit
    
    if owners.empty?
      puts "No GitHub owners found with science score >= #{min_science_score}"
      return
    end
    
    puts "Found #{owners.length} unique GitHub owners (science score >= #{min_science_score})"
    puts "\n" + "="*60 + "\n"
    
    total_stats = { created: 0, existing: 0 }
    
    owners.each_with_index do |owner, index|
      puts "\n[#{index + 1}/#{owners.length}] Importing repositories from owner: #{owner}"
      puts "-"*40
      
      # Import repositories for this owner
      stats = import_from_github_owner(owner)
      total_stats[:created] += stats[:created]
      total_stats[:existing] += stats[:existing]
      
      # Brief pause to avoid rate limiting
      sleep(1)
    end
    
    puts "\n" + "="*60
    puts "=== All GitHub Owners Import Complete ==="
    puts "Total new projects created: #{total_stats[:created]}"
    puts "Total existing projects found: #{total_stats[:existing]}"
    puts "Grand total: #{total_stats[:created] + total_stats[:existing]}"
  end

  def self.import_from_github_topic(topic, max_pages = 10)
    puts "Starting GitHub topic import for '#{topic}'..."
    page = 1
    total_created = 0
    total_existing = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/topics/#{topic}?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      data = JSON.parse(response.body)
      repositories = data['repositories'] || []
      break if repositories.empty?
      
      repositories.each do |repo|
        next if repo['html_url'].blank?
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = repo['html_url'].downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
        else
          project = Project.create(url: repo_url)
          if project.persisted?
            project.sync_async
            total_created += 1
            puts "  Created: #{repo_url}"
          else
            puts "  Failed to create: #{repo_url} - #{project.errors.full_messages.join(', ')}"
          end
        end
      end
      
      puts "Page #{page} processed - Created: #{total_created}, Existing: #{total_existing}"
      page += 1
      
      # Stop after max_pages
      if page > max_pages
        puts "Reached maximum page limit (#{max_pages})"
        break
      end
    end
    
    puts "\n=== GitHub Topic '#{topic}' Import Complete ==="
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Grand total: #{total_created + total_existing}"
    
    # Return stats for aggregation
    { created: total_created, existing: total_existing }
  end

  def self.import_from_registry(registry, registry_name)
    puts "Starting #{registry_name} import of GitHub projects..."
    page = 1
    total_created = 0
    total_existing = 0
    total_skipped = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://packages.ecosyste.ms/api/v1/registries/#{registry}/packages?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      packages = JSON.parse(response.body)
      break if packages.empty?
      
      packages.each do |package|
        # Skip if no repository URL
        if package['repository_url'].blank?
          total_skipped += 1
          next
        end
        
        # Only process GitHub repositories
        unless package['repository_url'].downcase.include?('github.com')
          total_skipped += 1
          next
        end
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = package['repository_url'].downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
        else
          project = Project.create(url: repo_url)
          if project.persisted?
            project.sync_async
            total_created += 1
            puts "  Created: #{repo_url}"
          else
            puts "  Failed to create: #{repo_url} - #{project.errors.full_messages.join(', ')}"
          end
        end
      end
      
      puts "Page #{page} processed - Created: #{total_created}, Existing: #{total_existing}, Skipped: #{total_skipped}"
      page += 1
    end
    
    puts "\n=== #{registry_name} Import Complete ==="
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Total packages skipped (no GitHub URL): #{total_skipped}"
    puts "Grand total GitHub projects: #{total_created + total_existing}"
  end

  def self.import_from_joss
    puts "Starting JOSS import..."
    page = 1
    total_created = 0
    total_existing = 0
    
    loop do
      puts "Fetching page #{page}..."
      url = "https://joss.theoj.org/papers/published.json?page=#{page}"
      
      conn = Faraday.new(url: url) do |faraday|
        faraday.response :follow_redirects
        faraday.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      papers = JSON.parse(response.body)
      break if papers.empty?
      
      papers.each do |paper|
        next if paper['software_repository'].blank?
        
        # Normalize the URL (lowercase and remove trailing slash)
        repo_url = paper['software_repository'].downcase.chomp('/')
        
        existing_project = Project.find_by(url: repo_url)
        if existing_project.present?
          total_existing += 1
          # Update JOSS metadata if project exists
          existing_project.update(
            joss_metadata: paper
          )
        else
          project = Project.create(
            url: repo_url,
            name: paper['title'],
            description: "#{paper['title']} - Published in JOSS (#{paper['year']})",
            joss_metadata: paper
          )
          if project.persisted?
            total_created += 1
            project.sync_async
          end
        end
      end
      
      puts "Page #{page}: #{papers.size} papers processed"
      page += 1
    end
    
    puts "JOSS import complete!"
    puts "Total new projects created: #{total_created}"
    puts "Total existing projects found: #{total_existing}"
    puts "Grand total: #{total_created + total_existing}"
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
    sql = <<-SQL
      SELECT category, sub_category, COUNT(*)
      FROM projects
      WHERE 1=1 
      GROUP BY category, sub_category
    SQL

    results = ActiveRecord::Base.connection.execute(sql)

    results.group_by { |row| row['category'] }.map do |category, rows|
      {
        category: category,
        count: rows.sum { |row| row['count'] },
        sub_categories: rows.map do |row|
          {
            sub_category: row['sub_category'],
            count: row['count']
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
      r.update(release.except('release_url'))
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

  def self.analyze_codemeta_patterns
    puts "Analyzing CodeMeta patterns across projects..."
    puts "=" * 80

    projects_with_codemeta = Project.where.not(codemeta: nil)
    total_projects = projects_with_codemeta.count

    puts "\nTotal projects with codemeta data: #{total_projects}"
    return if total_projects == 0

    # Data collection
    all_keywords = []
    all_categories = []
    all_subcategories = []

    keywords_by_project = []
    categories_by_project = []

    namespaced_keywords = { colon: [], slash: [], dot: [] }
    parse_errors = 0

    projects_with_codemeta.find_each do |project|
      data = project.codemeta_json

      if data.nil?
        parse_errors += 1
        next
      end

      # Extract keywords
      keywords = extract_array_or_string(data['keywords'])
      if keywords.any?
        all_keywords += keywords
        keywords_by_project << keywords.length

        # Analyze keyword patterns (only for string keywords)
        keywords.each do |kw|
          next unless kw.is_a?(String)
          namespaced_keywords[:colon] << kw if kw.include?(':')
          namespaced_keywords[:slash] << kw if kw.include?('/')
          namespaced_keywords[:dot] << kw if kw.match?(/\w+\.\w+/)
        end
      end

      # Extract applicationCategory
      category = extract_array_or_string(data['applicationCategory'])
      if category.any?
        all_categories += category
        categories_by_project << category
      end

      # Extract applicationSubCategory
      subcategory = extract_array_or_string(data['applicationSubCategory'])
      all_subcategories += subcategory if subcategory.any?
    end

    puts "\n" + "=" * 80
    puts "KEYWORDS ANALYSIS"
    puts "=" * 80

    if all_keywords.any?
      analyze_keywords(all_keywords, keywords_by_project, namespaced_keywords)
    else
      puts "No keywords found in codemeta data"
    end

    puts "\n" + "=" * 80
    puts "APPLICATION CATEGORY ANALYSIS"
    puts "=" * 80

    if all_categories.any?
      analyze_categories(all_categories, categories_by_project, "applicationCategory")
    else
      puts "No applicationCategory values found in codemeta data"
    end

    puts "\n" + "=" * 80
    puts "APPLICATION SUBCATEGORY ANALYSIS"
    puts "=" * 80

    if all_subcategories.any?
      analyze_categories(all_subcategories, [], "applicationSubCategory")
    else
      puts "No applicationSubCategory values found in codemeta data"
    end

    puts "\n" + "=" * 80
    puts "SUMMARY & RECOMMENDATIONS"
    puts "=" * 80

    puts "\nParse errors: #{parse_errors}" if parse_errors > 0

    # Recommendations
    puts "\nKey Findings:"
    if namespaced_keywords.values.flatten.any?
      puts "✓ Some projects ARE using structured/namespaced keywords"
      puts "  - #{namespaced_keywords[:colon].length} keywords with colons (e.g., 'domain:value')"
      puts "  - #{namespaced_keywords[:slash].length} keywords with slashes (e.g., 'category/value')"
      puts "  - #{namespaced_keywords[:dot].length} keywords with dots (e.g., 'namespace.value')"
    else
      puts "✗ No structured/namespaced keywords found"
      puts "  Projects are using simple, unstructured keywords"
    end

    if all_categories.any?
      category_types = categories_by_project.map { |cats| cats.is_a?(Array) ? cats.length : 1 }
      avg_categories = category_types.sum.to_f / category_types.length
      puts "\n✓ applicationCategory is being used (avg #{avg_categories.round(1)} per project)"
      if avg_categories > 1.2
        puts "  Most projects use multiple categories (arrays)"
      else
        puts "  Most projects use single category values"
      end
    else
      puts "\n✗ applicationCategory is rarely used"
    end

    puts "\n" + "=" * 80
  end

  def self.extract_array_or_string(value)
    return [] if value.nil?

    values = value.is_a?(Array) ? value : [value]

    # Flatten and convert to strings, handling various types
    values.flat_map do |v|
      case v
      when String
        v
      when Hash
        # Handle structured keywords (e.g., {"name": "keyword"} or URL objects)
        v['name'] || v['@value'] || v['value'] || v.to_s
      else
        v.to_s if v.present?
      end
    end.compact
  end

  def self.analyze_keywords(all_keywords, keywords_by_project, namespaced_keywords)
    puts "\nTotal keywords: #{all_keywords.length}"
    puts "Unique keywords: #{all_keywords.uniq.length}"
    puts "Average keywords per project: #{(all_keywords.length.to_f / keywords_by_project.length).round(2)}"

    # Top keywords
    keyword_counts = all_keywords.group_by(&:itself).transform_values(&:count).sort_by { |k, v| -v }
    puts "\nTop 50 most common keywords:"
    keyword_counts.first(50).each_with_index do |(keyword, count), index|
      puts "  #{index + 1}. #{keyword} (#{count} projects)"
    end

    # Structured keywords analysis
    puts "\n" + "-" * 80
    puts "STRUCTURED KEYWORDS ANALYSIS"
    puts "-" * 80

    total_projects_with_namespaced = [
      namespaced_keywords[:colon].map { |kw| kw.split(':').first }.uniq,
      namespaced_keywords[:slash].map { |kw| kw.split('/').first }.uniq,
      namespaced_keywords[:dot].map { |kw| kw.split('.').first }.uniq
    ].flatten.uniq.length

    puts "\nProjects using structured keywords: #{total_projects_with_namespaced}"

    if namespaced_keywords[:colon].any?
      puts "\nColon-separated keywords (#{namespaced_keywords[:colon].length} total):"
      colon_examples = namespaced_keywords[:colon].uniq.first(10)
      colon_examples.each { |kw| puts "  - #{kw}" }

      # Analyze namespaces
      namespaces = namespaced_keywords[:colon].map { |kw| kw.split(':').first }.group_by(&:itself).transform_values(&:count).sort_by { |k, v| -v }
      puts "\n  Common namespaces:"
      namespaces.first(10).each { |ns, count| puts "    #{ns}: #{count} keywords" }
    end

    if namespaced_keywords[:slash].any?
      puts "\nSlash-separated keywords (#{namespaced_keywords[:slash].length} total):"
      slash_examples = namespaced_keywords[:slash].uniq.first(10)
      slash_examples.each { |kw| puts "  - #{kw}" }
    end

    if namespaced_keywords[:dot].any?
      puts "\nDot-separated keywords (#{namespaced_keywords[:dot].length} total):"
      dot_examples = namespaced_keywords[:dot].uniq.first(10)
      dot_examples.each { |kw| puts "  - #{kw}" }
    end
  end

  def self.analyze_categories(all_categories, categories_by_project, label)
    puts "\nTotal #{label} values: #{all_categories.length}"
    puts "Unique #{label} values: #{all_categories.uniq.length}"

    # Check if mostly URLs or text
    url_count = all_categories.count { |cat| cat.to_s.start_with?('http://') || cat.to_s.start_with?('https://') }
    puts "URL-based values: #{url_count} (#{(url_count.to_f / all_categories.length * 100).round(1)}%)"
    puts "Text-based values: #{all_categories.length - url_count} (#{((all_categories.length - url_count).to_f / all_categories.length * 100).round(1)}%)"

    # Top categories
    category_counts = all_categories.group_by(&:itself).transform_values(&:count).sort_by { |k, v| -v }
    puts "\nTop 50 most common values:"
    category_counts.first(50).each_with_index do |(category, count), index|
      display_value = category.to_s.length > 80 ? category.to_s[0..77] + "..." : category.to_s
      puts "  #{index + 1}. #{display_value} (#{count} projects)"
    end

    # Distribution analysis
    puts "\nDistribution:"
    top_10_count = category_counts.first(10).sum { |k, v| v }
    puts "  Top 10 values account for: #{(top_10_count.to_f / all_categories.length * 100).round(1)}% of all values"

    singleton_count = category_counts.count { |k, v| v == 1 }
    puts "  Values appearing only once: #{singleton_count} (#{(singleton_count.to_f / category_counts.length * 100).round(1)}%)"

    if categories_by_project.any?
      multi_category_projects = categories_by_project.count { |cats| cats.is_a?(Array) && cats.length > 1 }
      puts "\nUsage pattern:"
      puts "  Projects with multiple values: #{multi_category_projects} (#{(multi_category_projects.to_f / categories_by_project.length * 100).round(1)}%)"
    end
  end

  def clone_and_analyze_codemeta(base_dir: nil)
    return [] unless repository.present?

    clone_url = repository['clone_url'] || "#{url}.git"
    repo_name = url.split('/').last(2).join('_')

    base_dir ||= Dir.mktmpdir('codemeta_research')
    repo_path = File.join(base_dir, repo_name)

    results = []

    begin
      # Clone if not already present
      unless Dir.exist?(repo_path)
        puts "Cloning #{url}..."
        system("git clone --quiet #{clone_url} #{repo_path}")
        unless $?.success?
          return [{ error: "Failed to clone repository", release_tag: nil }]
        end
      end

      # Get all tags from git
      tags = []
      Dir.chdir(repo_path) do
        # Fetch latest tags
        system("git fetch --tags --quiet 2>/dev/null")

        # Get tags sorted by creation date
        tag_output = `git tag --sort=creatordate`
        tags = tag_output.split("\n").map(&:strip).reject(&:empty?)
      end

      if tags.empty?
        return [{ error: "No tags found in repository", release_tag: nil }]
      end

      puts "  Found #{tags.count} tags"

      # Analyze each tag
      tags.each do |tag|
        puts "  Checking tag #{tag}..."

        result = {
          project_id: id,
          project_url: url,
          release_tag: tag,
          release_date: nil,
          codemeta_exists: false,
          codemeta_version: nil,
          version_matches_tag: nil,
          codemeta_file_path: nil,
          error: nil
        }

        begin
          # Get tag date
          Dir.chdir(repo_path) do
            tag_date = `git log -1 --format=%aI #{tag} 2>/dev/null`.strip
            result[:release_date] = Time.parse(tag_date) if tag_date.present?
          rescue ArgumentError
            # Invalid date, leave as nil
          end

          # Checkout the tag
          Dir.chdir(repo_path) do
            system("git checkout --quiet #{tag} 2>/dev/null")
            unless $?.success?
              result[:error] = "Failed to checkout tag"
              results << result
              next
            end

            # Look for codemeta files (order matters - prefer .json over .jsonld)
            codemeta_paths = ['codemeta.json', '.codemeta.json']
            codemeta_paths.each do |path|
              if File.exist?(path)
                result[:codemeta_exists] = true
                result[:codemeta_file_path] = path

                # Parse and extract version
                begin
                  data = JSON.parse(File.read(path))
                  codemeta_version = data['version'] || data['softwareVersion']

                  if codemeta_version.present?
                    result[:codemeta_version] = codemeta_version

                    # Normalize and compare versions
                    normalized_codemeta = normalize_version_string(codemeta_version)
                    normalized_tag = normalize_version_string(tag)
                    result[:version_matches_tag] = (normalized_codemeta == normalized_tag)
                  end
                rescue JSON::ParserError => e
                  result[:error] = "JSON parse error: #{e.message}"
                end

                break
              end
            end
          end
        rescue => e
          result[:error] = e.message
        end

        results << result
      end

    rescue => e
      results << { error: "Repository clone error: #{e.message}", release_tag: nil }
    end

    results
  end

  def normalize_version_string(version_string)
    return nil if version_string.blank?
    version_string.to_s.strip.downcase.gsub(/^v/, '').gsub(/^version[-_\s]*/i, '')
  end

  def analyze_codemeta_history(base_dir: nil)
    return [] unless repository.present?

    clone_url = repository['clone_url'] || "#{url}.git"
    repo_name = url.split('/').last(2).join('_')

    base_dir ||= Dir.mktmpdir('codemeta_research')
    repo_path = File.join(base_dir, repo_name)

    results = []

    begin
      # Clone if not already present
      unless Dir.exist?(repo_path)
        puts "Cloning #{url}..."
        system("git clone --quiet #{clone_url} #{repo_path}")
        unless $?.success?
          return [{ error: "Failed to clone repository" }]
        end
      end

      # Look for codemeta files
      codemeta_paths = ['codemeta.json', '.codemeta.json']

      Dir.chdir(repo_path) do
        system("git fetch --quiet 2>/dev/null")

        codemeta_paths.each do |file_path|
          # Check if file exists in current HEAD
          next unless system("git cat-file -e HEAD:#{file_path} 2>/dev/null")

          puts "  Analyzing history of #{file_path}..."

          # Get full git log for this file
          log_output = `git log --follow --format="%H|%aI|%an|%ae|%s" -- #{file_path}`

          log_output.split("\n").each do |line|
            parts = line.split("|", 5)
            next if parts.length < 5

            commit_hash = parts[0]
            commit_date = parts[1]
            author_name = parts[2]
            author_email = parts[3]
            commit_message = parts[4]

            # Get the file content at this commit
            file_content = `git show #{commit_hash}:#{file_path} 2>/dev/null`

            codemeta_version = nil
            codemeta_data = nil
            parse_error = nil

            if file_content.present?
              begin
                codemeta_data = JSON.parse(file_content)
                codemeta_version = codemeta_data['version'] || codemeta_data['softwareVersion']
              rescue JSON::ParserError => e
                parse_error = e.message
              end
            end

            result = {
              project_id: id,
              project_url: url,
              file_path: file_path,
              commit_hash: commit_hash,
              commit_date: Time.parse(commit_date),
              author_name: author_name,
              author_email: author_email,
              commit_message: commit_message,
              codemeta_version: codemeta_version,
              parse_error: parse_error
            }

            results << result
          end

          # Only analyze the first file we find
          break if results.any?
        end
      end

      if results.empty?
        results << { error: "No codemeta file found in repository history" }
      end

    rescue => e
      results << { error: "Repository analysis error: #{e.message}" }
    end

    results
  end
end
