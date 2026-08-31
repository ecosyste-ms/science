require 'csv'
require 'matrix'
require 'tf-idf-similarity'
require 'stopwords'
require 'github/markup'

class Project < ApplicationRecord
  SCIENCE_SCORE_THRESHOLD = 20
  DOI_IMAGE_SUFFIX_PATTERN = /\.(?:gif|jpe?g|png|svg|webp)(?:[?#]\S*)?\z/i
  ENCODED_DOI_SEPARATOR_PATTERN = /(10\.\d{4,9})%2f/i
  DOI_MARKDOWN_LINK_BOUNDARY_PATTERN = /\]\s*\(/
  DOI_ASCIIDOC_IMAGE_BOUNDARY_PATTERN = /\[image:/i
  DOI_HTTP_URL_PATTERN = %r{https?://[^\s<>"']+}i
  DOI_RESOLVER_URL_PATTERN = %r{
    \Ahttps?://(?:www\.|dx\.)?doi\.org/[^\s<>"']+
  }ix
  DOI_RESOLVER_QUERY_PATTERN = %r{
    ((?:https?://)?(?:www\.|dx\.)?doi\.org/[^\s?#]+)[?#]\S+
  }ix
  DOI_HTML_TAG_PATTERN = %r{</?[a-z][^>]*>}i
  ARXIV_REFERENCE_PATTERN = %r{
    (?:
      arxiv:\s*|
      https?://(?:www\.|export\.)?arxiv\.org/(?:abs|pdf)/
    )
    [^\s?#<>"')\]]+
  }ix
  ARXIV_VERSION_PATTERN = /v\d+\z/i

  include EcosystemApiClient
  include Project::Importers
  include Project::Sync
  include Project::Citation
  include Project::Scoring
  include Project::Classification

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
  counter_culture :owner_record,
    column_name: ->(project) { :projects_count if project.science_score.to_f >= SCIENCE_SCORE_THRESHOLD },
    column_names: -> { { Project.scientific => :projects_count } }

  has_many :issues, dependent: :delete_all
  has_many :releases, dependent: :delete_all
  has_many :project_fields, dependent: :destroy
  has_many :fields, through: :project_fields
  has_many :project_open_alex_topics, dependent: :delete_all
  has_many :open_alex_topics, through: :project_open_alex_topics
  has_many :mentions, dependent: :destroy
  has_many :papers, through: :mentions
  has_many :dependency_records, class_name: 'Dependency', dependent: :nullify
  has_many :project_dependencies, dependent: :delete_all
  has_many :project_authors, dependent: :delete_all
  has_many :repository_aliases,
    class_name: "ProjectRepositoryAlias",
    dependent: :delete_all
  has_many :dependency_package_records, through: :project_dependencies, source: :package
  has_many :published_package_records,
    class_name: "Package",
    foreign_key: :published_by_project_id,
    dependent: :nullify
  has_many :votes, dependent: :delete_all

  before_save :reset_repository_alias_index,
    if: :will_save_change_to_repository?
  before_save :reset_citation_author_index,
    if: :will_save_change_to_citation_file?

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
  scope :needing_brief_dependencies, -> {
    where("brief IS NULL OR (NOT (brief ? 'dependencies') AND NOT (brief ? 'error'))")
  }
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
  scope :with_research_organization_owner, -> { joins(:owner_record).merge(Owner.institutional) }
  scope :scientific, -> { where('science_score >= ?', SCIENCE_SCORE_THRESHOLD) }
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

  def self.extract_dois(value)
    text = value.to_s
      .gsub(DOI_MARKDOWN_LINK_BOUNDARY_PATTERN, " ")
      .gsub(DOI_ASCIIDOC_IMAGE_BOUNDARY_PATTERN, " ")
      .gsub(DOI_RESOLVER_QUERY_PATTERN, '\\1')
      .gsub(ENCODED_DOI_SEPARATOR_PATTERN, '\\1/')
    extractable_text = text
      .gsub(DOI_HTTP_URL_PATTERN) do |url|
        url.match?(DOI_RESOLVER_URL_PATTERN) ? url : " "
      end
      .gsub(DOI_HTML_TAG_PATTERN, " ")

    Identifiers::DOI.extract(extractable_text)
      .reject { |doi| doi.match?(DOI_IMAGE_SUFFIX_PATTERN) }
      .uniq
  end

  def self.extract_arxiv_ids(value)
    value.to_s.scan(ARXIV_REFERENCE_PATTERN).flat_map do |reference|
      normalized_reference = reference
        .sub(/[.,;:]+\z/, "")
        .sub(/\.pdf\z/i, "")
      Identifiers::ArxivId.extract(normalized_reference)
    end.map { |identifier| identifier.sub(ARXIV_VERSION_PATTERN, "") }.uniq
  end

  def self.arxiv_doi(identifier)
    "10.48550/arXiv.#{identifier.sub(ARXIV_VERSION_PATTERN, "")}"
  end

  def self.extract_orcids(*values)
    Identifiers::ORCID.extract(values.compact.join("\n")).uniq
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

  def to_s
    name.presence || url
  end

  def repository_url
    repo_url = github_pages_to_repo_url(url)
    return repo_url if repo_url.present?
    url
  end

  def reset_repository_alias_index
    self.repository_aliases_indexed_at = nil
    self.repository_aliases_index_error = nil
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

  def description
    return read_attribute(:description) if read_attribute(:description).present?
    return unless repository.present?
    repository["description"]
  end

  # TODO fetch repo dependencies
  # TODO fetch repo tags

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
    ((issues_stats['issue_author_associations_count'] || {}).keys + (issues_stats['pull_request_author_associations_count'] || {}).keys).uniq
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
    (issues_stats['past_year_issues_count'] - (issues_stats['past_year_bot_issues_count'] || 0)) > 0
  end

  def pull_requests_this_year?
    return false unless issues_stats.present?
    return false unless issues_stats['past_year_pull_requests_count'].present?
    (issues_stats['past_year_pull_requests_count'] - (issues_stats['past_year_bot_pull_requests_count'] || 0)) > 0
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

  def readme_url
    return unless repository.present?
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{readme_file_name}"
  end

  def commiter_domains
    return unless commits.present?
    return unless commits['committers'].present?
    commits['committers'].map{|c| c['email'].to_s.split('@')[1].try(:downcase) }.reject{|e| e.nil? || ignored_domains.include?(e) || e.ends_with?('.local') || e.split('.').length ==1  }.group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
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
    ScienceScoreCalculator.academic_domain?(domain)
  end

  def ignored_domains
    ['users.noreply.github.com', "googlemail.com", "gmail.com", "hotmail.com", "outlook.com","yahoo.com","protonmail.com","web.de","example.com","live.com","icloud.com","hotmail.fr","yahoo.se","yahoo.fr"]
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
    readme_urls.select do |url|
      doi_domains.include?(URI.parse(url).host.to_s.downcase)
    end.uniq
  end

  def dois
    self.class.extract_dois(readme)
  end

  def arxiv_ids
    self.class.extract_arxiv_ids(readme)
  end

  def orcids
    self.class.extract_orcids(
      readme,
      citation_file,
      codemeta,
      zenodo,
      joss_metadata&.to_json
    )
  end

  def open_alex_readme_dois
    (
      dois + arxiv_ids.map { |identifier| self.class.arxiv_doi(identifier) }
    ).map(&:downcase).uniq
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
