require 'test_helper'

class JossIdfAnalyzerTest < ActiveSupport::TestCase
  def setup
    # Clear cache before each test
    JossIdfAnalyzer.clear_cache!
    
    # Create JOSS projects with scientific content
    @joss_project1 = Project.create!(
      url: 'https://github.com/test/joss1',
      name: 'Scientific Algorithm Package',
      description: 'A computational framework for numerical simulations',
      readme: 'This package implements statistical algorithms for data analysis and machine learning applications.',
      joss_metadata: { 'title' => 'Test Paper 1' },
      keywords: ['simulation', 'algorithm', 'computational']
    )
    
    @joss_project2 = Project.create!(
      url: 'https://github.com/test/joss2', 
      name: 'Climate Modeling Tool',
      description: 'Tools for climate data analysis and visualization',
      readme: 'Research software for analyzing empirical climate datasets using statistical methods.',
      joss_metadata: { 'title' => 'Test Paper 2' },
      keywords: ['climate', 'analysis', 'research']
    )
    
    @joss_project3 = Project.create!(
      url: 'https://github.com/test/joss3',
      name: 'Genomic Analysis Pipeline',
      description: 'Bioinformatics pipeline for genomic sequence analysis',
      readme: 'Computational biology tool for analyzing DNA sequences and protein structures.',
      joss_metadata: { 'title' => 'Test Paper 3' },
      keywords: ['genomic', 'bioinformatics', 'analysis']
    )
    
    # Create non-JOSS projects
    @non_joss_project = Project.create!(
      url: 'https://github.com/test/webapp',
      name: 'Web Application',
      description: 'A web app for managing tasks',
      readme: 'Simple todo list application with user authentication and database storage.'
    )
    
    @scientific_non_joss = Project.create!(
      url: 'https://github.com/test/science-tool',
      name: 'Data Analysis Framework',
      description: 'Statistical computation and simulation framework',
      readme: 'This framework provides algorithms for numerical analysis and empirical research.'
    )
  end

  test "build_joss_corpus returns documents for JOSS projects" do
    documents = JossIdfAnalyzer.build_joss_corpus
    
    assert_not_empty documents
    assert_equal 3, documents.length
    assert documents.all? { |doc| doc.is_a?(TfIdfSimilarity::Document) }
  end

  test "calculate_joss_idf returns IDF scores" do
    idf_scores = JossIdfAnalyzer.calculate_joss_idf
    
    assert_not_empty idf_scores
    assert idf_scores.is_a?(Hash)
    
    # Check that scientific terms are present
    terms = idf_scores.keys
    assert terms.any? { |t| t.include?('algorithm') || t.include?('analysis') || t.include?('computational') }
    
    # All IDF scores should be positive
    assert idf_scores.values.all? { |score| score >= 0 }
  end

  test "calculate_joss_idf uses cache on subsequent calls" do
    # First call calculates and caches
    idf_scores1 = JossIdfAnalyzer.calculate_joss_idf
    timestamp1 = JossIdfAnalyzer.class_variable_get(:@@joss_idf_timestamp)
    
    # Second call should use cache
    idf_scores2 = JossIdfAnalyzer.calculate_joss_idf
    timestamp2 = JossIdfAnalyzer.class_variable_get(:@@joss_idf_timestamp)
    
    assert_equal idf_scores1, idf_scores2
    assert_equal timestamp1, timestamp2
    
    # Force refresh should update cache
    idf_scores3 = JossIdfAnalyzer.calculate_joss_idf(force_refresh: true)
    timestamp3 = JossIdfAnalyzer.class_variable_get(:@@joss_idf_timestamp)
    
    assert_not_equal timestamp1, timestamp3
  end

  test "identify_scientific_indicators returns common JOSS terms" do
    indicators = JossIdfAnalyzer.identify_scientific_indicators
    
    assert_not_empty indicators
    assert indicators.is_a?(Hash)
    
    # Should filter out very short terms
    assert indicators.keys.all? { |term| term.length > 2 }
    
    # Terms should have reasonable IDF scores (not too high, not too low)
    assert indicators.values.all? { |score| score > 0.1 }
  end

  test "score_project returns higher score for scientific content" do
    # Non-JOSS scientific project should score higher than non-scientific
    scientific_score = JossIdfAnalyzer.score_project(@scientific_non_joss)
    non_scientific_score = JossIdfAnalyzer.score_project(@non_joss_project)
    
    assert scientific_score > 0
    assert non_scientific_score >= 0
    assert scientific_score > non_scientific_score, 
           "Scientific project (#{scientific_score}) should score higher than non-scientific (#{non_scientific_score})"
  end

  test "score_project returns 0 for nil project" do
    score = JossIdfAnalyzer.score_project(nil)
    assert_equal 0.0, score
  end

  test "score_project returns normalized score between 0 and 100" do
    score1 = JossIdfAnalyzer.score_project(@scientific_non_joss)
    score2 = JossIdfAnalyzer.score_project(@non_joss_project)
    
    [score1, score2].each do |score|
      assert score >= 0, "Score should be >= 0, got #{score}"
      assert score <= 100, "Score should be <= 100, got #{score}"
    end
  end

  test "compare_term_distributions identifies scientific signals" do
    # Need more projects for meaningful comparison
    5.times do |i|
      Project.create!(
        url: "https://github.com/test/regular#{i}",
        name: "Regular Project #{i}",
        description: "A regular software project",
        readme: "This is a web application with user interface and backend services."
      )
    end
    
    comparison = JossIdfAnalyzer.compare_term_distributions(top_n: 10)
    
    assert_not_nil comparison
    assert comparison.is_a?(Array)
    
    if comparison.any?
      first_signal = comparison.first
      assert first_signal.key?(:term)
      assert first_signal.key?(:joss_idf)
      assert first_signal.key?(:non_joss_idf)
      assert first_signal.key?(:difference)
      
      # Scientific terms should have lower IDF in JOSS than non-JOSS
      assert first_signal[:joss_idf] < first_signal[:non_joss_idf]
    end
  end

  test "joss_idf_score method works on Project instance" do
    score = @scientific_non_joss.joss_idf_score
    
    assert_not_nil score
    assert score >= 0
    assert score <= 100
  end

  test "clear_cache removes cached values" do
    # Calculate to populate cache
    JossIdfAnalyzer.calculate_joss_idf
    
    assert_not_nil JossIdfAnalyzer.class_variable_get(:@@joss_idf_cache)
    
    JossIdfAnalyzer.clear_cache!
    
    assert_nil JossIdfAnalyzer.class_variable_get(:@@joss_idf_cache)
    assert_nil JossIdfAnalyzer.class_variable_get(:@@joss_idf_timestamp)
  end
end