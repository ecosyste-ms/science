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

  test "calculate_science_score_breakdown returns score and breakdown" do
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

    result = project.calculate_science_score_breakdown

    assert_not_nil result[:score]
    assert_not_nil result[:breakdown]
    assert result[:score] > 0
    assert result[:breakdown][:has_citation_file][:present]
    assert result[:breakdown][:has_codemeta][:present]
    assert result[:breakdown][:has_doi_in_readme][:present]
  end

  test "calculate_science_score_breakdown handles missing data gracefully" do
    project = Project.create!(url: 'https://github.com/test/basic-project')

    result = project.calculate_science_score_breakdown

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

  test "should_sync scope includes projects never synced" do
    project = Project.create!(
      url: 'https://github.com/test/never-synced',
      last_synced_at: nil,
      science_score: nil
    )

    assert_includes Project.should_sync, project
  end

  test "should_sync scope includes projects with positive science score" do
    project = Project.create!(
      url: 'https://github.com/test/scientific-project',
      last_synced_at: 1.day.ago,
      science_score: 75.5
    )

    assert_includes Project.should_sync, project
  end

  test "should_sync scope excludes projects with zero science score that have been synced" do
    project = Project.create!(
      url: 'https://github.com/test/non-scientific',
      last_synced_at: 1.day.ago,
      science_score: 0
    )

    assert_not_includes Project.should_sync, project
  end

  test "should_sync scope includes projects with nil science score that have been synced" do
    project = Project.create!(
      url: 'https://github.com/test/unknown-science',
      last_synced_at: 1.day.ago,
      science_score: nil
    )

    assert_includes Project.should_sync, project
  end

  test "filtered_commiter_domains returns top 20 plus academic domains" do
    project = Project.create!(url: 'https://github.com/test/project')

    # Create 25 domains: 20 non-academic, 5 academic
    committers = []

    # Add 20 non-academic domains with decreasing counts
    20.times do |i|
      count = 100 - i
      count.times do
        committers << { 'email' => "user#{i}@company#{i}.com" }
      end
    end

    # Add 5 academic domains with low counts (would be outside top 20)
    3.times { committers << { 'email' => 'researcher@mit.edu' } }
    2.times { committers << { 'email' => 'scientist@ox.ac.uk' } }
    1.times { committers << { 'email' => 'prof@ethz.ch' } }

    project.commits = { 'committers' => committers }

    filtered = project.filtered_commiter_domains
    domain_names = filtered.map(&:first)

    # Should have top 20 companies plus 3 academic domains = 23 total
    assert_equal 23, filtered.length
    assert_includes domain_names, 'mit.edu'
    assert_includes domain_names, 'ox.ac.uk'
    assert_includes domain_names, 'ethz.ch'
    assert_includes domain_names, 'company0.com'
    assert_includes domain_names, 'company19.com'
  end

  test "is_academic_domain? identifies academic domains" do
    project = Project.create!(url: 'https://github.com/test/project')

    assert project.is_academic_domain?('mit.edu')
    assert project.is_academic_domain?('oxford.ac.uk')
    assert project.is_academic_domain?('ethz.ch')
    assert project.is_academic_domain?('nasa.gov')

    assert_not project.is_academic_domain?('google.com')
    assert_not project.is_academic_domain?('microsoft.com')
  end
end