namespace :joss_idf do
  desc "Build and cache full JOSS corpus IDF scores to disk"
  task build_cache: :environment do
    puts "Starting JOSS IDF corpus cache build at #{Time.current}"
    puts "=" * 60
    
    start_time = Time.current
    
    # Build and cache the full corpus
    JossIdfAnalyzer.build_and_cache_full_corpus
    
    elapsed = Time.current - start_time
    puts "=" * 60
    puts "Cache build completed in #{elapsed.round(2)} seconds"
  end

  desc "Clear JOSS IDF cache (memory and disk)"
  task clear_cache: :environment do
    puts "Clearing JOSS IDF cache..."
    JossIdfAnalyzer.clear_cache!
    puts "Cache cleared successfully"
  end

  desc "Show JOSS IDF cache statistics"
  task stats: :environment do
    cache_file = JossIdfAnalyzer::IDF_CACHE_FILE
    
    if File.exist?(cache_file)
      cache_data = JSON.parse(File.read(cache_file))
      cache_time = Time.parse(cache_data['timestamp'])
      age_days = ((Time.current - cache_time) / 1.day).round(1)
      
      puts "JOSS IDF Cache Statistics:"
      puts "=" * 40
      puts "Cache file: #{cache_file}"
      puts "Created: #{cache_time.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "Age: #{age_days} days"
      puts "Projects analyzed: #{cache_data['project_count']}"
      puts "Unique terms: #{cache_data['term_count']}"
      puts "File size: #{(File.size(cache_file) / 1024.0 / 1024.0).round(2)} MB"
      
      # Show sample of top scientific indicators
      if cache_data['idf_scores']
        scores = cache_data['idf_scores']
        sorted = scores.sort_by { |_, v| v }
        
        puts "\nTop 20 most common JOSS terms (lowest IDF):"
        sorted.first(20).each do |term, idf|
          puts "  #{term}: #{idf.round(3)}"
        end
      end
    else
      puts "No cache file found at #{cache_file}"
      puts "Run 'rake joss_idf:build_cache' to create the cache"
    end
  end

  desc "Test JOSS vocabulary similarity scoring on sample projects"
  task test: :environment do
    puts "Testing JOSS vocabulary similarity scoring..."
    
    # Ensure cache exists
    unless File.exist?(JossIdfAnalyzer::IDF_CACHE_FILE)
      puts "Cache not found, building now..."
      JossIdfAnalyzer.build_and_cache_full_corpus
    end
    
    # Test on a few JOSS and non-JOSS projects
    joss_sample = Project.with_joss.with_readme.limit(5)
    non_joss_sample = Project.where(joss_metadata: nil).with_readme.limit(5)
    
    puts "\nJOSS Projects (should have high similarity):"
    puts "-" * 40
    joss_sample.each do |project|
      score = JossIdfAnalyzer.score_project(project)
      puts "#{project.name}: #{score.round(1)}%"
    end
    
    puts "\nNon-JOSS Projects (varied similarity expected):"
    puts "-" * 40
    non_joss_sample.each do |project|
      score = JossIdfAnalyzer.score_project(project)
      puts "#{project.name}: #{score.round(1)}%"
    end
  end
end