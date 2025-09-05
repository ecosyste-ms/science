class FieldClassifier
  MAX_FIELDS_PER_PROJECT = 3
  PRIMARY_THRESHOLD = 0.3
  SECONDARY_THRESHOLD = 0.4
  RELATIVE_THRESHOLD = 0.5 # Secondary must be at least 50% of primary score

  def initialize
    @fields = Field.all.to_a
  end

  def classify_and_save(project)
    # Clear existing classifications
    project.project_fields.destroy_all
    
    # Get field scores
    field_scores = classify_project(project)
    
    # Save classifications
    field_scores.each do |field, score, signals|
      project.project_fields.create!(
        field: field,
        confidence_score: score,
        match_signals: signals
      )
    end
    
    field_scores
  end

  def classify_project(project)
    field_scores = calculate_all_field_scores(project)
    
    # Sort by score descending
    ranked_fields = field_scores.sort_by { |_, score, _| -score }
    
    # Get primary field
    primary = ranked_fields.first
    return [] if primary.nil? || primary[1] < PRIMARY_THRESHOLD
    
    # Get additional fields
    selected_fields = [primary]
    
    ranked_fields[1..].each do |field, score, signals|
      break if selected_fields.size >= MAX_FIELDS_PER_PROJECT
      break if score < SECONDARY_THRESHOLD
      break if score < (primary[1] * RELATIVE_THRESHOLD)
      
      selected_fields << [field, score, signals]
    end
    
    selected_fields
  end

  private

  def calculate_all_field_scores(project)
    @fields.map do |field|
      score, signals = calculate_field_score(project, field)
      [field, score, signals]
    end
  end

  def calculate_field_score(project, field)
    signals = {}
    
    # 1. Keyword matching (40% weight)
    if project.keywords.present?
      signals[:keywords] = calculate_keyword_match(
        project.keywords.map(&:downcase),
        field.keywords.map(&:downcase)
      )
    end
    
    # 2. README content matching (30% weight)
    if project.readme.present?
      readme_terms = extract_readme_terms(project.readme)
      signals[:readme] = calculate_term_match(
        readme_terms,
        field.keywords.map(&:downcase)
      )
    end
    
    # 3. Package/dependency matching (20% weight)
    if project.packages.present? || project.dependencies.present?
      project_packages = extract_package_names(project)
      signals[:packages] = calculate_package_match(
        project_packages,
        field.packages.map(&:downcase)
      )
    end
    
    # 4. Scientific indicators (10% weight)
    if project.readme.present? || project.description.present?
      content = [project.readme, project.description].compact.join(' ')
      signals[:indicators] = calculate_indicator_match(
        content.downcase,
        field.indicators.map(&:downcase)
      )
    end
    
    # Calculate weighted score
    weights = {
      keywords: 0.4,
      readme: 0.3,
      packages: 0.2,
      indicators: 0.1
    }
    
    total_score = 0.0
    total_weight = 0.0
    
    signals.each do |signal_type, score|
      weight = weights[signal_type] || 0
      total_score += score * weight
      total_weight += weight if score > 0
    end
    
    # Normalize by actual weights used
    final_score = total_weight > 0 ? total_score / total_weight : 0.0
    
    [final_score, signals]
  end

  def calculate_keyword_match(project_keywords, field_keywords)
    return 0.0 if project_keywords.empty? || field_keywords.empty?
    
    # Normalize keywords by splitting on hyphens and underscores
    normalized_project = project_keywords.flat_map { |k| k.split(/[-_]/) }.uniq
    normalized_field = field_keywords
    
    # Direct matches
    direct_matches = (normalized_project & normalized_field).size
    
    # Partial matches (substring)
    partial_matches = 0
    normalized_project.each do |pk|
      next if pk.length < 4  # Skip very short words
      normalized_field.each do |fk|
        next if fk.length < 4
        # Check if one contains the other (but not if they're already counted as direct)
        if !normalized_field.include?(pk) && !normalized_project.include?(fk)
          if pk.include?(fk) || fk.include?(pk)
            partial_matches += 0.5
          end
        end
      end
    end
    
    # Score based on how many field keywords we found evidence for
    matches_found = direct_matches + (partial_matches * 0.5)
    match_score = matches_found / field_keywords.size.to_f
    [match_score, 1.0].min
  end

  def calculate_term_match(readme_terms, field_keywords)
    return 0.0 if readme_terms.empty? || field_keywords.empty?
    
    matches = 0
    field_keywords.each do |keyword|
      matches += 1 if readme_terms.include?(keyword)
    end
    
    # Score based on percentage of field keywords found
    matches.to_f / field_keywords.size
  end

  def calculate_package_match(project_packages, field_packages)
    return 0.0 if project_packages.empty? || field_packages.empty?
    
    # Strong signal if packages match
    matches = (project_packages & field_packages).size
    
    # If any package matches, it's a strong indicator
    matches > 0 ? [0.8 + (0.2 * matches / field_packages.size.to_f), 1.0].min : 0.0
  end

  def calculate_indicator_match(content, indicators)
    return 0.0 if content.empty? || indicators.empty?
    
    matches = 0
    indicators.each do |indicator|
      matches += 1 if content.include?(indicator)
    end
    
    matches.to_f / indicators.size
  end

  def extract_readme_terms(readme)
    # Extract significant terms from README
    # Remove common words, keep scientific terms
    text = readme.downcase
    
    # Remove URLs, code blocks, special characters
    text = text.gsub(/https?:\/\/\S+/, '')
               .gsub(/```[\s\S]*?```/, '')
               .gsub(/`[^`]+`/, '')
               .gsub(/[^a-z\s-]/, ' ')
    
    # Split into words and filter
    words = text.split(/\s+/)
                .select { |w| w.length > 3 }
                .uniq
    
    # Remove very common words
    stopwords = %w[this that these those have been were what when where which while 
                   with from into onto upon about after before during under above below
                   between through against toward towards upon beneath beside besides]
    
    words - stopwords
  end

  def extract_package_names(project)
    packages = []
    
    # From packages
    if project.packages.present?
      project.packages.each do |pkg|
        packages << pkg['name'].downcase if pkg['name'].present?
      end
    end
    
    # From dependencies
    if project.dependencies.present?
      project.dependencies.each do |dep|
        if dep['dependencies'].present?
          dep['dependencies'].each do |d|
            packages << d['package_name'].downcase if d['package_name'].present?
          end
        end
      end
    end
    
    packages.uniq
  end
end