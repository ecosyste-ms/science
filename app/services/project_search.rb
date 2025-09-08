class ProjectSearch
  attr_reader :query, :limit

  def initialize(query, limit = 10)
    @query = query.to_s.strip.downcase
    @limit = limit
  end

  def search
    return [] if query.blank?
    
    results = []
    repo_name = extract_repo_name(query)
    
    # Always check for package matches first (most authoritative)
    package_results = exact_package_matches
    results += package_results
    
    # Then check other match types if we need more results
    if package_results.empty?
      results += exact_name_matches
      results += exact_repo_matches(repo_name) if results.empty?
    end
    
    results += partial_name_matches(results) if results.size < limit
    results += partial_repo_matches(repo_name, results) if results.size < limit
    results += contains_matches(results) if results.size < limit
    
    # Sort and limit
    results.sort_by { |r| 
      [-r[:confidence], -project_quality_score(r[:project])] 
    }.first(limit)
  end

  private

  def extract_repo_name(query)
    if query.include?('/')
      query.split('/').last.gsub(/\.git$/, '')
    else
      query
    end
  end

  def exact_repo_matches(repo_name)
    projects = Project.where('science_score > 0')  # Include all projects with any science score
      .where("url ILIKE ?", "%/#{repo_name}")
      .select(:id, :name, :url, :description, :science_score, :score, :repository, :packages)
    
    projects.filter_map do |project|
      repo_end = project.url.split('/').last
      next unless repo_end.downcase == repo_name.downcase
      
      build_result(project, calculate_confidence(project, 100), 'exact_repo_name', repo_end)
    end
  end

  def exact_name_matches
    projects = Project.where('science_score > 0')
      .where('name ILIKE ?', query)
      .select(:id, :name, :url, :description, :science_score, :score, :repository, :packages)
    
    projects.map do |project|
      build_result(project, calculate_confidence(project, 100), 'exact_name', project.name)
    end
  end

  def exact_package_matches
    # Use PostgreSQL's JSON operators to search within the packages array
    # We use json_array_elements to expand the array and search each element
    projects = Project.where('science_score > 0')
      .where("EXISTS (SELECT 1 FROM json_array_elements(packages) AS pkg WHERE LOWER(pkg->>'name') = ?)", query.downcase)
      .select(:id, :name, :url, :description, :science_score, :score, :repository, :packages)
    
    projects.map do |project|
      # Find the matching package name for display
      matching_package = project.packages.find { |pkg| pkg['name']&.downcase == query.downcase }
      package_name = matching_package ? matching_package['name'] : query
      
      # Package name match is very high confidence - start at 110 to ensure it beats repo matches
      base_confidence = 110
      base_confidence -= 60 if is_fork?(project)  # Forks still get penalized
      base_confidence -= 10 if (project.science_score || 0) < 30  # Only penalize very low science scores
      
      {
        project: project,
        confidence: [base_confidence, 100].min,  # Cap at 100
        match_type: is_fork?(project) ? 'fork_exact_package_name' : 'exact_package_name',
        match_value: package_name
      }
    end
  end

  def partial_name_matches(existing_results)
    excluded_ids = existing_results.map { |r| r[:project].id }
    
    projects = Project.where('science_score > 0')
      .where('name ILIKE ?', "#{query}%")
      .where.not(id: excluded_ids)
      .limit(limit - existing_results.size)
      .select(:id, :name, :url, :description, :science_score, :score, :repository)
    
    projects.map do |project|
      build_result(project, calculate_confidence(project, 75), 'name_starts_with', project.name)
    end
  end

  def partial_repo_matches(repo_name, existing_results)
    excluded_ids = existing_results.map { |r| r[:project].id }
    
    projects = Project.where('science_score > 0')
      .where("url ILIKE ?", "%/#{repo_name}%")
      .where.not(id: excluded_ids)
      .limit(limit - existing_results.size)
      .select(:id, :name, :url, :description, :science_score, :score, :repository)
    
    projects.filter_map do |project|
      repo_end = project.url.split('/').last
      next unless repo_end.downcase.start_with?(repo_name.downcase)
      
      build_result(project, calculate_confidence(project, 70), 'repo_name_starts_with', repo_end)
    end
  end

  def contains_matches(existing_results)
    excluded_ids = existing_results.map { |r| r[:project].id }
    
    projects = Project.where('science_score > 0')
      .where('name ILIKE ?', "%#{query}%")
      .where.not(id: excluded_ids)
      .limit(limit - existing_results.size)
      .select(:id, :name, :url, :description, :science_score, :score, :repository)
    
    projects.map do |project|
      build_result(project, calculate_confidence(project, 50), 'name_contains', project.name)
    end
  end

  def calculate_confidence(project, base_confidence)
    confidence = base_confidence
    
    # Deduct for forks
    confidence -= 60 if is_fork?(project)
    
    # Deduct for low science score
    confidence -= 15 if (project.science_score || 0) < 70
    
    [confidence, 10].max # Minimum 10% confidence
  end

  def is_fork?(project)
    project.repository && project.repository['fork'] == true
  end

  def project_quality_score(project)
    science_val = project.science_score || 0
    score_val = project.score || 0
    score_val = 0 if score_val.infinite? || score_val.nan?
    science_val + score_val
  end

  def build_result(project, confidence, match_type, match_value)
    actual_match_type = is_fork?(project) ? "fork_#{match_type}" : match_type
    
    {
      project: project,
      confidence: confidence,
      match_type: actual_match_type,
      match_value: match_value
    }
  end
end