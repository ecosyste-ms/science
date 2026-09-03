module Project::Importers
  extend ActiveSupport::Concern

  class_methods do
    def import_from_csv(url)
      conn = Faraday.new(url: url) do |faraday|
        faraday.request :instrumentation
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

    def import_science_csv(file_path = 'data/science.csv', batch_size: 1000, sync: false)
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

    def discover_via_topics(limit=100)
      relevant_keywords.shuffle.first(limit).each do |topic|
        import_topic(topic)
      end
    end

    def discover_via_keywords(limit=100)
      relevant_keywords.shuffle.first(limit).each do |topic|
        import_keyword(topic)
      end
    end

    def import_topic(topic)
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

    def import_keyword(keyword)
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

    def import_org(host, org)
      resp = ecosystem_http_get("https://repos.ecosyste.ms/api/v1/hosts/#{host}/owners/#{org}/repositories?per_page=100")
      if resp.status == 200
        data = JSON.parse(resp.body)
        urls = data.map{|p| p['html_url'] }.uniq.reject(&:blank?)
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

    def import_from_cran
      import_from_registry('cran.r-project.org', 'CRAN')
    end

    def import_from_bioconductor
      import_from_registry('bioconductor.org', 'Bioconductor')
    end

    def import_from_conda_forge
      import_from_registry('conda-forge.org', 'conda-forge')
    end

    def top_joss_topics(limit = 50)
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

    def import_all_joss_topics
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

    def import_from_package_keyword(keyword, max_pages = 10)
      puts "Starting package keyword import for '#{keyword}'..."
      page = 1
      total_created = 0
      total_existing = 0
      total_skipped = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://packages.ecosyste.ms/api/v1/keywords/#{CGI.escape(keyword)}?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

    def import_all_joss_keywords
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

    def github_owners(min_science_score = 20)
      # Extract unique GitHub owner names from projects with reasonable science score
      owners = []

      scope = Project.visible.with_repository
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

    def scientific_github_owners
      # Convenience method for owners from scientific projects (score >= 20)
      github_owners(20)
    end

    def import_from_ost
      puts "Importing reviewed projects from OST..."
      page = 1
      total_imported = 0

      loop do
        url = "https://ost.ecosyste.ms/api/v1/projects?reviewed=true&page=#{page}"
        conn = Faraday.new(url: url) do |faraday|
          faraday.headers['User-Agent'] = 'science.ecosyste.ms'
          faraday.request :instrumentation
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

    def import_from_github_owner(owner, max_pages = 10)
      puts "Starting GitHub owner import for '#{owner}'..."
      page = 1
      total_created = 0
      total_existing = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/#{owner}/repositories?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

    def import_from_papers
      puts "Starting papers.ecosyste.ms import..."
      page = 1
      total_created = 0
      total_existing = 0
      total_skipped = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://papers.ecosyste.ms/api/v1/projects?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

    def import_all_github_owners(limit = nil, min_science_score = 20)
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

    def import_from_github_topic(topic, max_pages = 10)
      puts "Starting GitHub topic import for '#{topic}'..."
      page = 1
      total_created = 0
      total_existing = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/topics/#{topic}?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

    def import_from_registry(registry, registry_name)
      puts "Starting #{registry_name} import of GitHub projects..."
      page = 1
      total_created = 0
      total_existing = 0
      total_skipped = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://packages.ecosyste.ms/api/v1/registries/#{registry}/packages?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

    def import_from_joss
      puts "Starting JOSS import..."
      page = 1
      total_created = 0
      total_existing = 0
      total_ambiguous = 0

      loop do
        puts "Fetching page #{page}..."
        url = "https://joss.theoj.org/papers/published.json?page=#{page}"

        conn = Faraday.new(url: url) do |faraday|
          faraday.request :instrumentation
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

          repo_url = RepositoryUrlNormalizer.normalize(
            paper['software_repository']
          )
          next if repo_url.blank?

          matching_projects = projects_by_repository_url(repo_url)
          source_project_id = joss_source_project_id(paper['doi'])
          existing_project = matching_projects.find do |project|
            project.id == source_project_id
          end
          if existing_project.nil? && source_project_id.nil? &&
              matching_projects.one?
            existing_project = matching_projects.first
          end

          if existing_project
            total_existing += 1
            metadata_updated = existing_project.update(
              joss_metadata: paper
            )
            if metadata_updated && existing_project.saved_change_to_joss_metadata?
              existing_project.update_science_score
            end
          elsif source_project_id || matching_projects.many?
            total_ambiguous += 1
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
      puts "Total ambiguous repositories skipped: #{total_ambiguous}"
      puts "Grand total: #{total_created + total_existing}"
    end

    def projects_by_repository_url(value)
      normalized_url = RepositoryUrlNormalizer.normalize(value)
      return [] if normalized_url.blank?

      variants = [
        normalized_url,
        "#{normalized_url}/",
        "#{normalized_url}.git",
        "#{normalized_url}.git/",
      ]
      direct_ids = Project.where(url: variants).pluck(:id)
      alias_ids = ProjectRepositoryAlias
        .where(url: normalized_url)
        .distinct
        .limit(2)
        .pluck(:project_id)
      Project.where(id: (direct_ids + alias_ids).uniq).order(:id).to_a
    end

    def joss_source_project_id(value)
      doi = Project.extract_dois(value).first&.downcase
      return if doi.blank?

      MentionSource
        .joins(:mention)
        .where(source: JossPublicationIndexer::SOURCE, source_identifier: doi)
        .pick("mentions.project_id")
    end
  end
end
