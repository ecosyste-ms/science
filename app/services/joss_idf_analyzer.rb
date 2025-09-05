require 'tf-idf-similarity'
require 'stopwords'
require 'json'

class JossIdfAnalyzer
  # Cache JOSS corpus IDF values as class variable
  @@joss_idf_cache = nil
  @@joss_idf_timestamp = nil
  @@build_mutex = Mutex.new
  CACHE_DURATION = 24.hours
  
  # Disk cache configuration
  CACHE_DIR = Rails.root.join('tmp', 'cache', 'joss_idf')
  CORPUS_CACHE_FILE = CACHE_DIR.join('corpus.json')
  IDF_CACHE_FILE = CACHE_DIR.join('idf_scores.json')
  LOCK_FILE = CACHE_DIR.join('.building.lock')

  class << self
    # Stage 1: Build JOSS corpus from all JOSS projects
    def build_joss_corpus(limit: nil)
      joss_projects = Project.with_joss.with_readme
      
      # Default to a reasonable sample size if not specified
      # Full corpus is too slow for real-time calculation without disk cache
      if limit
        # When limiting, use random sampling
        joss_projects = joss_projects.order('RANDOM()').limit(limit)
        return [] if joss_projects.empty?
        
        puts "Building JOSS corpus from #{joss_projects.count} projects..."
        
        # For limited queries, just load all at once
        documents = joss_projects.map { |project| extract_project_text(project) }
      else
        # For full corpus, use find_in_batches without order
        return [] if joss_projects.empty?
        
        puts "Building JOSS corpus from #{joss_projects.count} projects..."
        
        # Process in batches to avoid memory issues
        documents = []
        joss_projects.find_in_batches(batch_size: 100) do |batch|
          batch_docs = batch.map { |project| extract_project_text(project) }
          documents.concat(batch_docs)
        end
      end
      
      documents
    end

    # Stage 2: Calculate IDF values for JOSS corpus
    def calculate_joss_idf(force_refresh: false, limit: nil)
      # Use mutex to prevent concurrent builds
      @@build_mutex.synchronize do
        # Return memory cached values if available and not forcing refresh
        if !force_refresh && @@joss_idf_cache && @@joss_idf_timestamp && 
           (Time.current - @@joss_idf_timestamp) < CACHE_DURATION
          return @@joss_idf_cache
        end

        # Try to load from disk cache if not forcing refresh and no limit specified
        if !force_refresh && limit.nil? && (cached_scores = load_from_disk_cache)
          @@joss_idf_cache = cached_scores
          @@joss_idf_timestamp = Time.current
          return cached_scores
        end

        # Check if another process is building
        FileUtils.mkdir_p(CACHE_DIR)
        if File.exist?(LOCK_FILE) && !force_refresh
          lock_age = Time.current - File.mtime(LOCK_FILE)
          if lock_age < 5.minutes
            # Another process is building, wait and retry
            Rails.logger.info "Another process is building JOSS IDF cache, waiting..."
            sleep 2
            # Retry loading from cache
            if (cached_scores = load_from_disk_cache)
              @@joss_idf_cache = cached_scores
              @@joss_idf_timestamp = Time.current
              return cached_scores
            end
          else
            # Lock file is stale, remove it
            FileUtils.rm_f(LOCK_FILE)
          end
        end

        # Create lock file
        File.write(LOCK_FILE, Process.pid.to_s)

        begin
          # Build corpus (with or without limit)
          documents = build_joss_corpus(limit: limit)
          return {} if documents.empty?

          # Create TF-IDF model
          model = TfIdfSimilarity::TfIdfModel.new(documents)
          
          # Get all unique terms
          all_terms = documents.flat_map(&:terms).uniq
          
          # Calculate IDF for each term
          idf_scores = {}
          all_terms.each do |term|
            idf_scores[term] = model.idf(term)
          end

          # Cache the results in memory
          @@joss_idf_cache = idf_scores
          @@joss_idf_timestamp = Time.current

          # Save to disk cache if we processed the full corpus
          if limit.nil?
            save_to_disk_cache(idf_scores)
          end

          idf_scores
        ensure
          # Remove lock file
          FileUtils.rm_f(LOCK_FILE)
        end
      end
    end

    # Stage 3: Identify scientific indicator terms
    # Terms with low-to-moderate IDF are common in JOSS (scientific indicators)
    # Terms with high IDF are rare (project-specific)
    def identify_scientific_indicators(percentile: 0.05)
      idf_scores = calculate_joss_idf
      
      return [] if idf_scores.empty?

      # Sort by IDF (ascending - lower IDF means more common in JOSS)
      sorted_terms = idf_scores.sort_by { |_, score| score }
      
      # Get terms below the specified percentile (most common in JOSS)
      # Using a much smaller percentile to focus on truly discriminative terms
      cutoff_index = (sorted_terms.length * percentile).to_i
      scientific_terms = sorted_terms[0...cutoff_index]
      
      # Filter to keep meaningful scientific terms
      # Exclude very generic terms and URLs/metadata
      exclude_patterns = %w[joss published https githubcom badge statussvg svg png jpg gif http www com org net]
      
      scientific_terms.select do |term, score|
        term.length > 2 && 
        score > 1.0 && # More selective - must appear in good portion of JOSS projects
        score < 4.0 && # But not too rare
        !exclude_patterns.any? { |pattern| term.include?(pattern) }
      end.to_h
    end

    # Stage 4: Score a non-JOSS project based on JOSS IDF
    def score_project(project)
      return 0.0 unless project.present?
      
      # Get JOSS IDF values
      joss_idf = calculate_joss_idf
      return 0.0 if joss_idf.empty?

      # Get scientific indicator terms (using default percentile)
      scientific_indicators = identify_scientific_indicators
      
      # Extract and process project text
      doc = extract_project_text(project)
      
      # Calculate term frequencies for this project
      term_counts = Hash.new(0)
      doc.terms.each { |term| term_counts[term] += 1 }
      
      # Count how many scientific indicators are present
      indicators_found = 0
      weighted_score = 0.0
      
      scientific_indicators.each do |term, idf|
        if term_counts[term] > 0
          indicators_found += 1
          # Weight by inverse IDF (lower IDF = more common in JOSS = stronger indicator)
          weight = 1.0 / (1.0 + idf)
          weighted_score += weight
        end
      end
      
      # Calculate score based on percentage of indicators found
      return 0.0 if scientific_indicators.empty?
      
      # Two components:
      # 1. Percentage of indicators found (0-50 points)
      coverage_score = (indicators_found.to_f / scientific_indicators.length * 50)
      
      # 2. Weighted score based on importance (0-50 points)  
      max_weight = scientific_indicators.values.map { |idf| 1.0 / (1.0 + idf) }.sum
      importance_score = (weighted_score / max_weight * 50) if max_weight > 0
      
      total_score = coverage_score + (importance_score || 0)
      [total_score.round(2), 100.0].min  # Cap at 100
    end

    # Helper: Compare JOSS vs non-JOSS term distributions
    def compare_term_distributions(top_n: 100)
      joss_idf = calculate_joss_idf
      
      # Calculate IDF for non-JOSS projects
      non_joss_projects = Project.where(joss_metadata: nil).with_readme.limit(500)
      non_joss_docs = non_joss_projects.map { |p| extract_project_text(p) }
      
      if non_joss_docs.any?
        non_joss_model = TfIdfSimilarity::TfIdfModel.new(non_joss_docs)
        non_joss_terms = non_joss_docs.flat_map(&:terms).uniq
        
        non_joss_idf = {}
        non_joss_terms.each do |term|
          non_joss_idf[term] = non_joss_model.idf(term)
        end
      else
        non_joss_idf = {}
      end

      # Find terms that are common in JOSS but rare elsewhere
      scientific_signals = []
      
      joss_idf.each do |term, joss_score|
        non_joss_score = non_joss_idf[term] || Math.log(non_joss_docs.length + 1)
        
        # Lower IDF in JOSS than non-JOSS indicates scientific term
        if joss_score < non_joss_score && term.length > 3
          scientific_signals << {
            term: term,
            joss_idf: joss_score,
            non_joss_idf: non_joss_score,
            difference: non_joss_score - joss_score
          }
        end
      end
      
      # Sort by difference (higher difference = stronger scientific indicator)
      scientific_signals.sort_by { |s| -s[:difference] }.first(top_n)
    end

    # Clear the cache
    def clear_cache!
      @@joss_idf_cache = nil
      @@joss_idf_timestamp = nil
      clear_disk_cache!
    end
    
    # Disk cache management
    def save_to_disk_cache(idf_scores)
      FileUtils.mkdir_p(CACHE_DIR)
      
      # Save IDF scores with metadata
      cache_data = {
        version: 1,
        timestamp: Time.current.iso8601,
        project_count: Project.with_joss.with_readme.count,
        term_count: idf_scores.length,
        idf_scores: idf_scores
      }
      
      File.write(IDF_CACHE_FILE, cache_data.to_json)
      puts "Saved IDF cache to disk (#{idf_scores.length} terms)"
    end
    
    def load_from_disk_cache
      return nil unless File.exist?(IDF_CACHE_FILE)
      
      begin
        cache_data = JSON.parse(File.read(IDF_CACHE_FILE))
        
        # Check if cache is recent (within 7 days)
        cache_time = Time.parse(cache_data['timestamp'])
        if Time.current - cache_time > 7.days
          puts "Disk cache is stale (#{((Time.current - cache_time) / 1.day).round} days old)"
          return nil
        end
        
        puts "Loaded IDF cache from disk (#{cache_data['term_count']} terms from #{cache_data['project_count']} projects)"
        cache_data['idf_scores']
      rescue => e
        Rails.logger.error "Error loading disk cache: #{e.message}"
        nil
      end
    end
    
    def clear_disk_cache!
      FileUtils.rm_f(IDF_CACHE_FILE)
      FileUtils.rm_f(CORPUS_CACHE_FILE)
      puts "Cleared disk cache"
    end
    
    # Build full corpus and save to disk (for rake task)
    def build_and_cache_full_corpus
      puts "Building full JOSS corpus..."
      
      joss_projects = Project.with_joss.with_readme
      total = joss_projects.count
      puts "Processing #{total} JOSS projects with READMEs..."
      
      documents = []
      processed = 0
      
      # Use find_in_batches without order to avoid Sidekiq warning
      joss_projects.find_in_batches(batch_size: 100) do |batch|
        batch_docs = batch.map { |project| extract_project_text(project) }
        documents.concat(batch_docs)
        processed += batch.size
        
        if processed % 500 == 0
          puts "  Processed #{processed}/#{total} projects..."
        end
      end
      
      puts "Creating TF-IDF model..."
      model = TfIdfSimilarity::TfIdfModel.new(documents)
      
      # Get all unique terms
      puts "Extracting terms..."
      all_terms = documents.flat_map(&:terms).uniq
      
      # Calculate IDF for each term
      puts "Calculating IDF scores for #{all_terms.length} terms..."
      idf_scores = {}
      all_terms.each_with_index do |term, i|
        idf_scores[term] = model.idf(term)
        
        if (i + 1) % 10000 == 0
          puts "  Calculated #{i + 1}/#{all_terms.length} IDF scores..."
        end
      end
      
      # Save to disk
      save_to_disk_cache(idf_scores)
      
      # Also update memory cache
      @@joss_idf_cache = idf_scores
      @@joss_idf_timestamp = Time.current
      
      puts "Successfully cached #{idf_scores.length} terms from #{total} JOSS projects"
      idf_scores
    end

    private

    def extract_project_text(project)
      text_parts = []
      
      # Collect text from various sources
      text_parts << project.name if project.name.present?
      text_parts << project.description if project.description.present?
      # Use first 3000 chars of README for efficiency
      text_parts << project.readme[0..3000] if project.readme.present?
      
      # Add keywords (most important for classification)
      if project.keywords.present?
        text_parts << project.keywords.join(' ')
      end
      
      # Skip citation and package details for IDF calculation to improve performance
      # They don't add much signal for vocabulary analysis
      
      # Combine and clean text
      text = text_parts.join(' ')
      
      # Remove stopwords
      filter = Stopwords::Snowball::Filter.new('en')
      filtered_text = filter.filter(text.downcase.split).join(' ')
      
      TfIdfSimilarity::Document.new(filtered_text)
    end
  end
end