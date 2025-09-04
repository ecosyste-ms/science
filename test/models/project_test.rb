require 'test_helper'

class ProjectTest < ActiveSupport::TestCase
  test "update_science_score sets science_score attribute" do
    project = Project.create!(url: 'https://github.com/test/science-project')
    project.repository = {
      'metadata' => {
        'files' => {
          'citation' => 'CITATION.cff'
        }
      }
    }
    project.citation_file = 'test citation content'
    
    project.update_science_score
    
    assert_not_nil project.science_score
    assert project.science_score > 0
  end

  test "science_score_breakdown returns score and breakdown" do
    project = Project.create!(url: 'https://github.com/test/science-project')
    project.repository = {
      'metadata' => {
        'files' => {
          'citation' => 'CITATION.cff',
          'codemeta' => 'codemeta.json'
        }
      }
    }
    project.citation_file = 'test citation content'
    project.readme = 'This paper has DOI: 10.1234/example'
    
    result = project.science_score_breakdown
    
    assert_not_nil result[:score]
    assert_not_nil result[:breakdown]
    assert result[:score] > 0
    assert result[:breakdown][:has_citation_file][:present]
    assert result[:breakdown][:has_codemeta][:present]
    assert result[:breakdown][:has_doi_in_readme][:present]
  end

  test "science_score_breakdown handles missing data gracefully" do
    project = Project.create!(url: 'https://github.com/test/basic-project')
    
    result = project.science_score_breakdown
    
    assert_not_nil result[:score]
    assert_equal 0.0, result[:score]
    assert_not result[:breakdown][:has_citation_file][:present]
    assert_not result[:breakdown][:has_doi_in_readme][:present]
  end
  test "github_pages_to_repo_url" do
    project = Project.new
    repo_url = project.github_pages_to_repo_url('https://foo.github.io/bar')
    assert_equal 'https://github.com/foo/bar', repo_url
  end

  test "github_pages_to_repo_url with trailing slash" do
    project = Project.new(url: 'https://foo.github.io/bar/')
    repo_url = project.repository_url
    assert_equal 'https://github.com/foo/bar', repo_url
  end

  test "calculate_idf class method returns array of hashes" do
    project1 = Project.create!(
      url: 'https://github.com/test/project1',
      name: 'Climate Monitoring Tool',
      description: 'A tool for monitoring climate change data',
      readme: 'This project helps track environmental metrics'
    )
    
    project2 = Project.create!(
      url: 'https://github.com/test/project2',
      name: 'Weather Analysis System',
      description: 'System for analyzing weather patterns',
      readme: 'Advanced weather pattern analysis and prediction'
    )

    result = Project.calculate_idf([project1, project2])
    
    assert_kind_of Array, result
    assert result.all? { |item| item.is_a?(Hash) }
    assert result.all? { |item| item.key?(:term) && item.key?(:score) }
  end

  test "calculate_idf class method sorts by score descending" do
    project1 = Project.create!(
      url: 'https://github.com/test/project3',
      name: 'Unique Specialized Tool',
      description: 'Common software application',
      readme: 'Common code common features'
    )
    
    project2 = Project.create!(
      url: 'https://github.com/test/project4',
      name: 'Common Software Tool',
      description: 'Common software application',
      readme: 'Common code common features'
    )

    result = Project.calculate_idf([project1, project2])
    
    scores = result.map { |item| item[:score] }
    assert_equal scores.sort.reverse, scores
  end

  test "calculate_idf class method returns empty array for empty input" do
    result = Project.calculate_idf([])
    assert_equal [], result
  end

  test "calculate_idf instance method returns IDF for single project" do
    project = Project.create!(
      url: 'https://github.com/test/project5',
      name: 'Environmental Monitoring',
      description: 'Monitoring environmental conditions',
      readme: 'Track and analyze environmental data'
    )

    result = project.calculate_idf
    
    assert_kind_of Array, result
    assert result.all? { |item| item.is_a?(Hash) }
    assert result.all? { |item| item.key?(:term) && item.key?(:score) }
  end

  test "calculate_idf filters stopwords" do
    project = Project.create!(
      url: 'https://github.com/test/project6',
      name: 'The Climate Tool',
      description: 'This is a tool for the climate',
      readme: 'And it will be very useful'
    )

    result = project.calculate_idf
    terms = result.map { |item| item[:term] }
    
    # Common stopwords should be filtered out
    assert_not_includes terms, 'the'
    assert_not_includes terms, 'is'
    assert_not_includes terms, 'a'
    assert_not_includes terms, 'for'
    assert_not_includes terms, 'and'
    assert_not_includes terms, 'it'
    assert_not_includes terms, 'be'
    assert_not_includes terms, 'very'
    
    # These should NOT be filtered (not stopwords)
    assert_includes terms, 'will'
    assert_includes terms, 'useful'
    assert_includes terms, 'climate'
    assert_includes terms, 'tool'
  end

  test "calculate_idf handles missing fields gracefully" do
    project = Project.create!(
      url: 'https://github.com/test/project7',
      name: 'Minimal Project'
      # No description or readme
    )

    result = project.calculate_idf
    
    assert_kind_of Array, result
    assert_not_empty result
  end
end