require 'csv'

namespace :projects do
  desc 'sync projects'
  task :sync => :environment do
    Project.sync_least_recently_synced
  end

  desc 'sync reviewed projects'
  task :sync_reviewed => :environment do
    Project.sync_least_recently_synced_reviewed
  end

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

  desc 'sync dependencies'
  task :sync_dependencies => :environment do
    Project.sync_dependencies
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