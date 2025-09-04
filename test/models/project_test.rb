require 'test_helper'

class ProjectTest < ActiveSupport::TestCase
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
    assert_not_includes terms, 'will'
    assert_not_includes terms, 'be'
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