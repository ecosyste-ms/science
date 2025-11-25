require 'csv'

namespace :codemeta_research do
  desc 'Export detailed codemeta analysis to CSV (pipe to file)'
  task detailed_csv: :environment do
    csv = CSV.new($stdout)

    # Write header
    csv << [
      'project_id',
      'project_url',
      'project_name',
      'has_codemeta',
      'codemeta_version',
      'latest_release_tag',
      'latest_release_date',
      'total_releases',
      'version_match',
      'version_difference',
      'codemeta_file_path',
      'repository_stars',
      'repository_language'
    ]

    # Analyze all projects with codemeta
    Project.with_codemeta.includes(:releases).find_each do |project|
      codemeta_data = project.codemeta_json
      next unless codemeta_data

      codemeta_version = codemeta_data['version'] || codemeta_data['softwareVersion']
      latest_release = project.releases.order(published_at: :desc).first

      version_match = nil
      version_diff = nil

      if latest_release && codemeta_version.present?
        normalized_codemeta = normalize_version(codemeta_version)
        normalized_release = normalize_version(latest_release.tag_name)

        version_match = (normalized_codemeta == normalized_release)

        unless version_match
          version_diff = "codemeta: #{codemeta_version}, release: #{latest_release.tag_name}"
        end
      end

      csv << [
        project.id,
        project.url,
        project.name,
        true,
        codemeta_version,
        latest_release&.tag_name,
        latest_release&.published_at,
        project.releases.count,
        version_match,
        version_diff,
        project.codemeta_file_name,
        project.repository&.dig('stargazers_count'),
        project.repository&.dig('language')
      ]
    end
  end

  desc 'Export all releases for projects with codemeta (for tag-level analysis)'
  task releases_for_analysis: :environment do
    csv = CSV.new($stdout)

    # Write header - this will be the input for cloning and checking each tag
    csv << [
      'project_id',
      'project_url',
      'clone_url',
      'release_tag',
      'release_date',
      'default_branch',
      'current_codemeta_version'
    ]

    Project.with_codemeta.includes(:releases).find_each do |project|
      codemeta_data = project.codemeta_json
      current_version = codemeta_data ? (codemeta_data['version'] || codemeta_data['softwareVersion']) : nil

      project.releases.order(published_at: :asc).each do |release|
        csv << [
          project.id,
          project.url,
          project.repository&.dig('clone_url') || "#{project.url}.git",
          release.tag_name,
          release.published_at,
          project.repository&.dig('default_branch') || 'main',
          current_version
        ]
      end
    end
  end

  desc 'Export summary of projects with codemeta (for selective cloning)'
  task projects_summary: :environment do
    csv = CSV.new($stdout)

    # Write header
    csv << [
      'project_id',
      'project_url',
      'clone_url',
      'project_name',
      'total_releases',
      'current_codemeta_version',
      'codemeta_file_path',
      'stars',
      'language',
      'default_branch'
    ]

    Project.with_codemeta.includes(:releases).find_each do |project|
      codemeta_data = project.codemeta_json
      current_version = codemeta_data ? (codemeta_data['version'] || codemeta_data['softwareVersion']) : nil

      csv << [
        project.id,
        project.url,
        project.repository&.dig('clone_url') || "#{project.url}.git",
        project.name,
        project.releases.count,
        current_version,
        project.codemeta_file_name || 'codemeta.json',
        project.repository&.dig('stargazers_count'),
        project.repository&.dig('language'),
        project.repository&.dig('default_branch') || 'main'
      ]
    end
  end

  desc 'Generate summary report'
  task report: :environment do
    stats = {
      total_projects: Project.count,
      projects_with_codemeta: 0,
      projects_with_releases: 0,
      projects_with_both: 0,
      version_matches: 0,
      version_mismatches: 0,
      version_missing: 0,
      codemeta_parse_errors: 0
    }

    version_diffs = []

    Project.with_codemeta.includes(:releases).find_each do |project|
      stats[:projects_with_codemeta] += 1

      codemeta_data = project.codemeta_json
      unless codemeta_data
        stats[:codemeta_parse_errors] += 1
        next
      end

      codemeta_version = codemeta_data['version'] || codemeta_data['softwareVersion']
      latest_release = project.releases.order(published_at: :desc).first

      has_releases = project.releases.any?
      stats[:projects_with_releases] += 1 if has_releases
      stats[:projects_with_both] += 1 if has_releases

      if latest_release && codemeta_version.present?
        normalized_codemeta = normalize_version(codemeta_version)
        normalized_release = normalize_version(latest_release.tag_name)

        version_match = (normalized_codemeta == normalized_release)

        if version_match
          stats[:version_matches] += 1
        else
          stats[:version_mismatches] += 1
          version_diffs << {
            project: project.url,
            codemeta: codemeta_version,
            release: latest_release.tag_name,
            release_date: latest_release.published_at
          }
        end
      elsif codemeta_version.blank?
        stats[:version_missing] += 1
      end
    end

    # Output report
    puts "=" * 80
    puts "CodeMeta Research Analysis Report"
    puts "=" * 80
    puts "Generated: #{Time.now}"
    puts ""

    puts "DATASET OVERVIEW"
    puts "-" * 80
    puts "Total projects in database: #{stats[:total_projects]}"
    puts "Projects with codemeta files: #{stats[:projects_with_codemeta]}"
    puts "Projects with releases: #{stats[:projects_with_releases]}"
    puts "Projects with both codemeta and releases: #{stats[:projects_with_both]}"
    puts ""

    puts "VERSION ACCURACY ANALYSIS"
    puts "-" * 80
    puts "Projects analyzed: #{stats[:projects_with_codemeta]}"
    puts "Codemeta parse errors: #{stats[:codemeta_parse_errors]}"
    puts "Projects missing version field: #{stats[:version_missing]}"
    puts ""

    if stats[:projects_with_both] > 0
      puts "VERSION COMPARISON (projects with both codemeta and releases)"
      puts "-" * 80
      total_comparable = stats[:version_matches] + stats[:version_mismatches]
      puts "Total comparable: #{total_comparable}"
      puts "Version matches: #{stats[:version_matches]} (#{percentage(stats[:version_matches], total_comparable)}%)"
      puts "Version mismatches: #{stats[:version_mismatches]} (#{percentage(stats[:version_mismatches], total_comparable)}%)"
      puts ""
    end

    puts "KEY FINDINGS"
    puts "-" * 80

    if stats[:version_mismatches] > 0
      mismatch_rate = percentage(stats[:version_mismatches], stats[:projects_with_both])
      puts "• #{mismatch_rate}% of projects with both codemeta and releases have version mismatches"
    end

    if stats[:version_missing] > 0
      missing_rate = percentage(stats[:version_missing], stats[:projects_with_codemeta])
      puts "• #{missing_rate}% of codemeta files are missing version information"
    end

    puts ""
    puts "SAMPLE VERSION MISMATCHES (first 20)"
    puts "-" * 80
    version_diffs.first(20).each do |diff|
      puts "Project: #{diff[:project]}"
      puts "  CodeMeta version: #{diff[:codemeta]}"
      puts "  Latest release: #{diff[:release]} (#{diff[:release_date]&.strftime('%Y-%m-%d')})"
      puts ""
    end
  end

  desc 'Analyze codemeta at each tag by cloning repos (optional: limit=N, base_dir=/path)'
  task analyze_tags: :environment do
    limit = ENV['limit']&.to_i
    base_dir = ENV['base_dir'] || Dir.mktmpdir('codemeta_research')

    csv = CSV.new($stdout)
    csv << [
      'project_id',
      'project_url',
      'release_tag',
      'release_date',
      'codemeta_exists',
      'codemeta_version',
      'version_matches_tag',
      'codemeta_file_path',
      'error'
    ]

    projects = Project.with_codemeta.includes(:releases).where.not(releases: { id: nil })
    projects = projects.limit(limit) if limit

    total = limit || projects.count
    processed = 0

    projects.find_each do |project|
      processed += 1
      $stderr.puts "[#{processed}/#{total}] Analyzing #{project.url}..."

      results = project.clone_and_analyze_codemeta(base_dir: base_dir)

      results.each do |result|
        csv << [
          result[:project_id],
          result[:project_url],
          result[:release_tag],
          result[:release_date],
          result[:codemeta_exists],
          result[:codemeta_version],
          result[:version_matches_tag],
          result[:codemeta_file_path],
          result[:error]
        ]
      end
    end

    $stderr.puts ""
    $stderr.puts "Analysis complete! Processed #{processed} projects."
    $stderr.puts "Repos cloned to: #{base_dir}"
  end

  desc 'Analyze git commit history of codemeta files (optional: limit=N, base_dir=/path)'
  task analyze_history: :environment do
    limit = ENV['limit']&.to_i
    base_dir = ENV['base_dir'] || Dir.mktmpdir('codemeta_research')

    csv = CSV.new($stdout)
    csv << [
      'project_id',
      'project_url',
      'file_path',
      'commit_hash',
      'commit_date',
      'author_name',
      'author_email',
      'commit_message',
      'codemeta_version',
      'parse_error'
    ]

    projects = Project.with_codemeta
    projects = projects.limit(limit) if limit

    total = limit || projects.count
    processed = 0

    projects.find_each do |project|
      processed += 1
      $stderr.puts "[#{processed}/#{total}] Analyzing history of #{project.url}..."

      results = project.analyze_codemeta_history(base_dir: base_dir)

      results.each do |result|
        csv << [
          result[:project_id],
          result[:project_url],
          result[:file_path],
          result[:commit_hash],
          result[:commit_date],
          result[:author_name],
          result[:author_email],
          result[:commit_message],
          result[:codemeta_version],
          result[:parse_error] || result[:error]
        ]
      end
    end

    $stderr.puts ""
    $stderr.puts "Analysis complete! Processed #{processed} projects."
    $stderr.puts "Repos cloned to: #{base_dir}"
  end

  def normalize_version(version_string)
    return nil if version_string.blank?
    version_string.to_s.strip.downcase.gsub(/^v/, '').gsub(/^version[-_\s]*/i, '')
  end

  def percentage(numerator, denominator)
    return 0 if denominator.zero?
    ((numerator.to_f / denominator) * 100).round(1)
  end
end
