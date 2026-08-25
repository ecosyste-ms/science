module Project::Scoring
  extend ActiveSupport::Concern

  class_methods do
    def calculate_idf(projects)
      return [] if projects.empty?

      # Prepare documents from projects
      documents = projects.map do |project|
        text_parts = []
        text_parts << project.name if project.name.present?
        text_parts << project.description if project.description.present?
        text_parts << project.preprocessed_readme if project.readme.present?
        text = text_parts.join(' ')

        # Remove stopwords
        filter = Stopwords::Snowball::Filter.new('en')
        filtered_text = filter.filter(text.downcase.split).join(' ')

        TfIdfSimilarity::Document.new(filtered_text)
      end

      # Create model
      model = TfIdfSimilarity::TfIdfModel.new(documents)

      # Get all terms from all documents
      all_terms = documents.flat_map(&:terms).uniq

      # Calculate IDF for each term
      idf_scores = {}
      all_terms.each do |term|
        idf_scores[term] = model.idf(term)
      end

      # Sort by IDF score (descending) and return as array of hashes
      idf_scores.sort_by { |_, score| -score }.map do |term, score|
        { term: term, score: score }
      end
    end
  end

  def update_score
    update_attribute :score, score_parts.sum
  end

  def update_science_score
    result = calculate_science_score_breakdown
    update(science_score: result[:score], science_score_breakdown: result)
  end

  def science_score_breakdown
    # Return stored breakdown from database
    # This method should only be called from views/API, never calculate on the fly
    breakdown = read_attribute(:science_score_breakdown)
    breakdown&.with_indifferent_access
  end

  def calculate_science_score_breakdown
    calculator = ScienceScoreCalculator.new(self)
    calculator.calculate
  end

  def joss_vocabulary_analysis
    JossVocabularyAnalyzer.analyze_project(self)
  end

  def joss_vocabulary_score
    joss_vocabulary_analysis[:score]
  end

  def score_parts
    [
      repository_score,
      packages_score,
      commits_score,
      dependencies_score,
      events_score
    ]
  end

  def repository_score
    return 0 unless repository.present?
    Math.log [
      (repository['stargazers_count'] || 0),
      (repository['open_issues_count'] || 0)
    ].sum
  end

  def packages_score
    return 0 unless packages.present?
    Math.log [
      packages.map{|p| p["downloads"] || 0 }.sum,
      packages.map{|p| p["dependent_packages_count"] || 0 }.sum,
      packages.map{|p| p["dependent_repos_count"] || 0 }.sum,
      packages.map{|p| p["docker_downloads_count"] || 0 }.sum,
      packages.map{|p| p["docker_dependents_count"] || 0 }.sum,
      packages.map{|p| p['maintainers'].map{|m| m['uuid'] } }.flatten.uniq.length
    ].sum
  end

  def commits_score
    return 0 unless commits.present?
    Math.log [
      (commits['total_committers'] || 0),
    ].sum
  end

  def dependencies_score
    return 0 unless dependencies.present?
    0
  end

  def events_score
    return 0 unless events.present?
    0
  end

  def calculate_idf
    # Use the class method with an array containing just this project
    self.class.calculate_idf([self])
  end

  def preprocessed_readme
    return '' unless readme.present?
    
    begin
      html_content = GitHub::Markup.render(readme_file_name, readme.force_encoding("UTF-8"))
      
      # Extract text from HTML
      text = Nokogiri::HTML(html_content).text.strip.downcase
      # remove URLs
      text = text.gsub(/https?:\/\/[^\s]+/, '')
      # normalize whitespace
      text.gsub(/\s+/, ' ')
    rescue => e
      puts "Error preprocessing readme for #{repository_url}"
      p e.message
      p e.backtrace
      # Return empty string if any error occurs during rendering or processing
      ''
    end
  end
end
