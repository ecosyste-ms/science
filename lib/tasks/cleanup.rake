namespace :cleanup do
  desc 'Clean up project names that contain descriptions after colon'
  task :project_names => :environment do
    projects_with_colons = Project.where('name LIKE ?', '%:%')
    
    puts "Found #{projects_with_colons.count} projects with colons in their names"
    
    cleaned_count = 0
    projects_with_colons.find_each do |project|
      original_name = project.name
      
      # Extract just the name part before the colon
      # Also handle cases where the name might have whitespace
      clean_name = original_name.split(':').first.strip
      
      # Skip if the clean name is empty or too short
      next if clean_name.blank? || clean_name.length < 2
      
      # Update the name
      if project.update(name: clean_name)
        cleaned_count += 1
        puts "Updated: '#{original_name}' -> '#{clean_name}'"
      else
        puts "Failed to update: #{original_name}"
      end
    end
    
    puts "\nCleaned #{cleaned_count} project names"
    
    # Also fill in missing names from packages or URLs
    puts "\nFilling in missing names..."
    missing_names = Project.where(name: [nil, ''])
    filled_from_packages = 0
    filled_from_urls = 0
    
    missing_names.find_each do |project|
      # First try to get name from packages
      if project.packages.present?
        # Sort packages by average_ranking (lower is better/more popular)
        valid_packages = project.packages.select do |pkg| 
          pkg['name'].present? && !pkg['name'].empty? && !pkg['name'].start_with?('github.com/')
        end
        
        if valid_packages.any?
          # Extract repo name from URL for comparison
          repo_name = project.url.split('/').last.downcase.gsub(/\.git$/, '')
          
          # Sort packages by:
          # 1. Exact match with repo name (highest priority)
          # 2. Average ranking (lower is better)
          # 3. Alphabetical as tiebreaker
          sorted_packages = valid_packages.sort_by do |pkg|
            name = pkg['name'].downcase
            ranking = pkg['average_ranking'] || 999999.0
            
            # Give bonus if name exactly matches repo name
            exact_match_bonus = (name == repo_name) ? 0 : 1000000
            
            [exact_match_bonus, ranking, name]
          end
          
          # Use the best package name
          best_package = sorted_packages.first
          package_name = best_package['name']
          ranking = best_package['average_ranking']
          
          if project.update(name: package_name)
            filled_from_packages += 1
            ranking_info = ranking ? " (rank: #{ranking.round(2)})" : " (no ranking)"
            puts "Set name from package: #{project.url} -> '#{package_name}'#{ranking_info}"
            next
          end
        end
      end
      
      # Fall back to extracting from URL
      repo_name = project.url.split('/').last.gsub(/\.git$/, '')
      
      if repo_name.present? && project.update(name: repo_name)
        filled_from_urls += 1
        puts "Set name from URL: #{project.url} -> '#{repo_name}'"
      end
    end
    
    puts "Filled #{filled_from_packages} names from packages"
    puts "Filled #{filled_from_urls} names from URLs"
    puts "Total filled: #{filled_from_packages + filled_from_urls}"
  end
  
  desc 'Show projects with colons in names without updating'
  task :preview_names => :environment do
    projects_with_colons = Project.where('name LIKE ?', '%:%').limit(50)
    
    puts "Preview of name changes (first 50):\n\n"
    projects_with_colons.each do |project|
      original_name = project.name
      clean_name = original_name.split(':').first.strip
      puts "#{project.url}"
      puts "  Original: #{original_name}"
      puts "  Cleaned:  #{clean_name}"
      puts ""
    end
    
    total = Project.where('name LIKE ?', '%:%').count
    puts "Total projects with colons: #{total}"
  end
end