require 'csv'

namespace :projects do
  desc 'sync projects'
  task :sync => :environment do
    Project.sync_least_recently_synced
  end

  desc 'sync reviewed projects'
  task :sync_reviewed => :environment do
    Project.sync_least_recently_synced
  end

  desc 'run all discovery importers'
  task :import => %i[import_joss import_papers import_cran import_bioconductor import_conda_forge import_ost]

  desc 'import projects from JOSS'
  task :import_joss => :environment do
    Project.import_from_joss
  end

  desc 'import projects from papers.ecosyste.ms'
  task :import_papers => :environment do
    Project.import_from_papers
  end

  desc 'import projects from CRAN with GitHub repositories'
  task :import_cran => :environment do
    Project.import_from_cran
  end

  desc 'import projects from Bioconductor with GitHub repositories'
  task :import_bioconductor => :environment do
    Project.import_from_bioconductor
  end

  desc 'import projects from conda-forge with GitHub repositories'
  task :import_conda_forge => :environment do
    Project.import_from_conda_forge
  end

  desc 'import projects from a GitHub topic'
  task :import_github_topic, [:topic] => :environment do |t, args|
    topic = args[:topic] || 'science'
    Project.import_from_github_topic(topic)
  end

  desc 'import projects from top 50 JOSS topics'
  task :import_all_joss_topics => :environment do
    Project.import_all_joss_topics
  end

  desc 'import projects from a package keyword'
  task :import_package_keyword, [:keyword] => :environment do |t, args|
    keyword = args[:keyword] || 'science'
    Project.import_from_package_keyword(keyword)
  end

  desc 'import projects from top 50 JOSS keywords via packages'
  task :import_all_joss_keywords => :environment do
    Project.import_all_joss_keywords
  end

  desc 'import projects from a GitHub owner'
  task :import_github_owner, [:owner] => :environment do |t, args|
    if args[:owner].blank?
      puts "Please provide an owner name. Usage: rake projects:import_github_owner[underworldcode]"
      exit 1
    end
    Project.import_from_github_owner(args[:owner])
  end

  desc 'import projects from all GitHub owners'
  task :import_all_github_owners, [:limit, :min_score] => :environment do |t, args|
    limit = args[:limit].to_i if args[:limit].present?
    min_score = args[:min_score].present? ? args[:min_score].to_i : 50
    Project.import_all_github_owners(limit, min_score)
  end

  desc 'list all unique GitHub owners'
  task :list_github_owners, [:min_score] => :environment do |t, args|
    min_score = args[:min_score].present? ? args[:min_score].to_i : 50
    owners = Project.github_owners(min_score)
    puts "Found #{owners.length} unique GitHub owners (science score >= #{min_score}):"
    owners.each { |owner| puts "  #{owner}" }
  end

  desc 'discover projects'
  task :discover => :environment do
    Project.discover_via_topics
    Project.discover_via_keywords
  end

  desc 'discover repositories linked from citation and metadata files'
  task :import_metadata_repositories => :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', 'false'))
    counts = MetadataRepositoryImporter.sync!(dry_run: dry_run)
    label = dry_run ? "Metadata repository dry run" : "Metadata repository import"
    puts "#{label}: #{counts.inspect}"
  end

  desc 'index stored direct dependencies (LIMIT=250 RETRY_ERRORS=false)'
  task :sync_dependencies => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = Project.sync_dependencies(
      limit: ENV.fetch('LIMIT', ProjectDependencyIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Project dependencies: #{result.inspect}"
  end

  desc 'index stored CFF authors (LIMIT=250 RETRY_ERRORS=false)'
  task :sync_citation_authors => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = Project.sync_citation_authors(
      limit: ENV.fetch('LIMIT', ProjectCitationAuthorIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Project citation authors: #{result.inspect}"
  end

  desc 'rescore stored citation metadata (LIMIT=250 AFTER_ID=0)'
  task :rescore_citations => :environment do
    result = Project.rescore_citations(
      limit: ENV.fetch('LIMIT', Project::Scoring::CITATION_RESCORE_DEFAULT_LIMIT),
      after_id: ENV.fetch('AFTER_ID', '0')
    )
    puts "Project citation scores: #{result.inspect}"
  end

  desc 'rescore overlapping science signals (LIMIT=250 AFTER_ID=0)'
  task :rescore_overlapping_science_signals => :environment do
    result = Project.rescore_overlapping_science_signals(
      limit: ENV.fetch('LIMIT', Project::Scoring::CITATION_RESCORE_DEFAULT_LIMIT),
      after_id: ENV.fetch('AFTER_ID', '0')
    )
    puts "Project overlapping science signals: #{result.inspect}"
  end

  desc 'index stored JOSS publications and authors (LIMIT=250 RETRY_ERRORS=false)'
  task :sync_joss_publications => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = Project.sync_joss_publications(
      limit: ENV.fetch('LIMIT', JossPublicationIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "JOSS publications: #{result.inspect}"
  end

  desc 'index stored repository contributors (LIMIT=250 RETRY_ERRORS=false)'
  task :sync_contributors => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = Project.sync_contributors(
      limit: ENV.fetch('LIMIT', ProjectContributorIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Project contributors: #{result.inspect}"
  end

  desc 'link project authors and developer accounts (LIMIT=250 RETRY_ERRORS=false)'
  task :sync_author_identities => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = Project.sync_author_identities(
      limit: ENV.fetch('LIMIT', AuthorIdentityIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Author identities: #{result.inspect}"
  end

  desc 'index stored repository aliases (LIMIT=500 RETRY_ERRORS=false)'
  task :sync_repository_aliases => :environment do
    retry_errors = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('RETRY_ERRORS', 'false')
    )
    result = ProjectRepositoryAliasIndexer.sync_batch!(
      limit: ENV.fetch('LIMIT', ProjectRepositoryAliasIndexer::DEFAULT_LIMIT),
      retry_errors: retry_errors
    )
    puts "Project repository aliases: #{result.inspect}"
  end

  desc 'enqueue brief scans (LIMIT=50 COHORT=all SHARD_COUNT=1 SHARD=0)'
  task :fetch_brief => :environment do
    enqueuer = BriefScanEnqueuer.new(
      limit: ENV.fetch('LIMIT', '50'),
      cohort: ENV.fetch('COHORT', 'all'),
      shard_count: ENV.fetch('SHARD_COUNT', '1'),
      shard: ENV.fetch('SHARD', '0')
    )
    enqueued = enqueuer.enqueue

    puts "Enqueued #{enqueued} Brief jobs (cohort=#{enqueuer.cohort}, shard=#{enqueuer.shard}/#{enqueuer.shard_count})"
  rescue ArgumentError => error
    abort error.message
  end

  desc 'import reviewed projects from OST (Open Sustainable Technology)'
  task :import_ost => :environment do
    Project.import_from_ost
  end

  desc 'export keywords from JOSS projects to CSV'
  task :export_joss_keywords => :environment do
    projects = Project.with_joss

    puts CSV.generate_line(['url', 'name', 'joss_tags', 'repository_topics', 'combined_keywords'])
    projects.find_each do |project|
      joss_tags = project.joss_metadata['tags']&.split(',')&.map(&:strip)&.join('; ') || ''
      repo_topics = project.repository&.dig('topics')&.join('; ') || ''
      combined = project.keywords&.join('; ') || ''
      puts CSV.generate_line([project.url, project.name, joss_tags, repo_topics, combined])
    end
  end
end
