require 'test_helper'

class ProjectTest < ActiveSupport::TestCase
  def setup
    %w[edu ac.uk ethz.ch nasa.gov].each do |domain|
      create_research_organization_domain(domain, version: "project")
    end
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  def teardown
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "issue_associations handles missing sub-keys in issues_stats" do
    p = Project.new(url: "https://github.com/x/y", issues_stats: { 'issue_author_associations_count' => { 'OWNER' => 1 } })
    assert_equal ['OWNER'], p.issue_associations

    p.issues_stats = { 'other' => 1 }
    assert_equal [], p.issue_associations

    p.issues_stats = nil
    assert_equal [], p.issue_associations
  end

  test "issues_this_year? and pull_requests_this_year? handle missing bot counts" do
    p = Project.new(url: "https://github.com/x/y", issues_stats: { 'past_year_issues_count' => 5, 'past_year_pull_requests_count' => 3 })
    assert p.issues_this_year?
    assert p.pull_requests_this_year?
  end

  test "commiter_domains handles committers with nil email" do
    p = Project.new(url: "https://github.com/x/y", commits: { 'committers' => [{ 'email' => nil }, { 'email' => 'a@stanford.edu' }] })
    assert_equal [['stanford.edu', 1]], p.commiter_domains
  end

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

  test "update_science_score persists the scientific dependency bonus" do
    project = Project.create!(
      url: 'https://github.com/test/scientific-dependencies',
      dependencies: [
        {
          'dependencies' => [
            { 'direct' => true, 'ecosystem' => 'pypi', 'package_name' => 'astropy' },
            { 'direct' => true, 'ecosystem' => 'pypi', 'package_name' => 'scipy' },
            { 'direct' => true, 'ecosystem' => 'cran', 'package_name' => 'sf' },
          ],
        },
      ]
    )

    project.update_science_score
    project.reload

    assert_equal 8.0, project.science_score
    assert_equal 8.0, project.science_score_breakdown.dig(
      :breakdown,
      :has_scientific_dependencies,
      :score
    )
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

  test "extracts normalized DOIs from README text" do
    project = Project.new(readme: <<~README)
      DOI: 10.1016/0021-9991(92)90370-E.
      https://doi.org/10.21105%2FJOSS.01453
      https://doi.org/10.5281/zenodo.5565455.svg
      https://doi.org/10.1000/PAPER.1?utm_source=readme
      https://doi.org/10.5281/zenodo.5565455.svg?download=1
      doi.org/10.1000/PAPER.2#abstract
      [![DOI](https://img.shields.io/badge/DOI-10.5281/zenodo.4642814-informational?logo=data:image/svg+xml;base64,LONG)](https://doi.org/10.5281/zenodo.4642814)
      <a href="https://example.com/10.9999/not-a-doi.pdf?token=LONG">Paper</a>
    README

    assert_equal [
      "10.1016/0021-9991(92)90370-e",
      "10.21105/joss.01453",
      "10.1000/paper.1",
      "10.1000/paper.2",
      "10.5281/zenodo.4642814",
    ], project.dois
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

  test "sync_releases ignores unknown and locally managed attributes" do
    project = Project.create!(
      url: 'https://github.com/test/release-sync',
      repository: { 'releases_url' => 'https://example.com/releases' }
    )
    other_project = Project.create!(url: 'https://github.com/test/other-project')
    response = stub(
      success?: true,
      body: [{
        'uuid' => 'release-1',
        'name' => 'Version 1',
        'immutable' => true,
        'project_id' => other_project.id
      }].to_json
    )
    project.stubs(:ecosystem_http_client).returns(stub(get: response))

    assert_nothing_raised { project.sync_releases }

    release = project.releases.find_by!(uuid: 'release-1')
    assert_equal 'Version 1', release.name
    assert_equal project.id, release.project_id
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

  test "import_mentions returns early if no packages" do
    project = Project.create!(url: 'https://github.com/test/project')
    project.packages = nil

    assert_no_difference ['Paper.count', 'Mention.count'] do
      project.import_mentions
    end
  end

  test "import_mentions creates papers and mentions for each package" do
    project = Project.create!(
      url: 'https://github.com/test/project',
      packages: [
        { 'ecosystem' => 'pypi', 'name' => 'test-package' }
      ]
    )

    mentions_response = [
      { 'paper_url' => 'https://papers.ecosyste.ms/api/v1/papers/10.1234%2Fexample1' }
    ]

    paper_response = {
      'doi' => '10.1234/example1',
      'openalex_id' => 'W123456',
      'title' => 'Test Paper',
      'publication_date' => '2023-01-01',
      'openalex_data' => { 'type' => 'article' }
    }

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/projects/pypi/test-package/mentions?page=1&per_page=1000")
      .to_return(status: 200, body: mentions_response.to_json)

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/papers/10.1234%2Fexample1")
      .to_return(status: 200, body: paper_response.to_json)

    assert_difference 'Paper.count', 1 do
      assert_difference 'Mention.count', 1 do
        project.import_mentions
      end
    end

    paper = Paper.last
    assert_equal '10.1234/example1', paper.doi
    assert_equal 'Test Paper', paper.title

    mention = Mention.last
    assert_equal paper, mention.paper
    assert_equal project, mention.project

    project.reload
    assert_equal 1, project.mentions_count
  end

  test "import_mentions handles multiple packages" do
    project = Project.create!(
      url: 'https://github.com/test/project',
      packages: [
        { 'ecosystem' => 'pypi', 'name' => 'package1' },
        { 'ecosystem' => 'npm', 'name' => 'package2' }
      ]
    )

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/projects/pypi/package1/mentions?page=1&per_page=1000")
      .to_return(status: 200, body: [
        { 'paper_url' => 'https://papers.ecosyste.ms/api/v1/papers/10.1%2Fpaper1' }
      ].to_json)

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/projects/npm/package2/mentions?page=1&per_page=1000")
      .to_return(status: 200, body: [
        { 'paper_url' => 'https://papers.ecosyste.ms/api/v1/papers/10.2%2Fpaper2' }
      ].to_json)

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/papers/10.1%2Fpaper1")
      .to_return(status: 200, body: {
        'doi' => '10.1/paper1',
        'title' => 'Paper 1'
      }.to_json)

    stub_request(:get, "https://papers.ecosyste.ms/api/v1/papers/10.2%2Fpaper2")
      .to_return(status: 200, body: {
        'doi' => '10.2/paper2',
        'title' => 'Paper 2'
      }.to_json)

    assert_difference 'Paper.count', 2 do
      assert_difference 'Mention.count', 2 do
        project.import_mentions
      end
    end

    project.reload
    assert_equal 2, project.mentions_count
  end

  test "import_mentions skips packages without ecosystem or name" do
    project = Project.create!(
      url: 'https://github.com/test/project',
      packages: [
        { 'ecosystem' => 'pypi' },
        { 'name' => 'package2' },
        {}
      ]
    )

    assert_no_difference ['Paper.count', 'Mention.count'] do
      project.import_mentions
    end
  end

  test "find_or_create_host creates new host" do
    project = Project.create!(
      url: 'https://github.com/test/project',
      repository: {
        'host' => {
          'name' => 'GitHub',
          'url' => 'https://github.com',
          'kind' => 'git'
        }
      }
    )

    assert_difference 'Host.count', 1 do
      project.find_or_create_host
    end

    project.reload
    assert_equal 'GitHub', project.host.name
    assert_equal 'https://github.com', project.host.url
    assert_equal 'git', project.host.kind
  end

  test "find_or_create_host finds existing host" do
    host = Host.create!(name: 'GitHub', url: 'https://github.com', kind: 'git')
    project = Project.create!(
      url: 'https://github.com/test/project',
      repository: {
        'host' => {
          'name' => 'GitHub',
          'url' => 'https://github.com',
          'kind' => 'git'
        }
      }
    )

    assert_no_difference 'Host.count' do
      project.find_or_create_host
    end

    project.reload
    assert_equal host, project.host
  end

  test "find_or_create_host returns early if repository is missing" do
    project = Project.create!(url: 'https://github.com/test/project')

    assert_no_difference 'Host.count' do
      project.find_or_create_host
    end

    assert_nil project.host
  end

  test "find_or_create_owner creates new owner" do
    host = Host.create!(name: 'GitHub')
    project = Project.create!(url: 'https://github.com/test/project', host: host)
    project.update_column(:owner, {
      'login' => 'testuser',
      'name' => 'Test User',
      'uuid' => '123',
      'kind' => 'user',
      'description' => 'A test user',
      'email' => 'test@example.com',
      'website' => 'https://example.com',
      'location' => 'San Francisco',
      'twitter' => 'testuser',
      'company' => 'Test Company',
      'icon_url' => 'https://example.com/icon.png',
      'repositories_count' => 10,
      'metadata' => { 'key' => 'value' },
      'total_stars' => 100,
      'followers' => 50,
      'following' => 25,
      'hidden' => false
    })

    assert_difference 'Owner.count', 1 do
      project.find_or_create_owner
    end

    project.reload
    assert_equal 'testuser', project.owner_record.login
    assert_equal 'Test User', project.owner_record.name
    assert_equal '123', project.owner_record.uuid
    assert_equal 'user', project.owner_record.kind
    assert_equal host, project.owner_record.host
  end

  test "find_or_create_owner finds existing owner by login (case insensitive)" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'testuser')
    project = Project.create!(url: 'https://github.com/test/project', host: host)
    project.update_column(:owner, {
      'login' => 'TestUser',
      'name' => 'Test User Updated'
    })

    assert_no_difference 'Owner.count' do
      project.find_or_create_owner
    end

    project.reload
    assert_equal owner, project.owner_record
    assert_equal 'Test User Updated', project.owner_record.name
  end

  test "find_or_create_owner returns early if owner json is missing" do
    host = Host.create!(name: 'GitHub')
    project = Project.create!(url: 'https://github.com/test/project', host: host)

    assert_no_difference 'Owner.count' do
      project.find_or_create_owner
    end

    assert_nil project.owner
  end

  test "find_or_create_owner returns early if host is missing" do
    project = Project.create!(url: 'https://github.com/test/project')
    project.update_column(:owner, { 'login' => 'testuser' })

    assert_no_difference 'Owner.count' do
      project.find_or_create_owner
    end

    project.reload
    assert_nil project.owner_id
  end

  test "does not create a project for a hidden owner" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    Owner.create!(host: host, login: "hidden-owner", hidden: true)

    project = Project.new(url: "https://github.com/HIDDEN-OWNER/project")

    assert_not project.valid?
    assert_includes project.errors[:url], "belongs to a hidden owner"
  end

  test "visible excludes projects belonging to hidden owners" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "hidden-owner")
    project = Project.create!(
      host: host,
      owner_record: owner,
      url: "https://github.com/hidden-owner/project"
    )
    owner.update!(hidden: true)

    assert_not_includes Project.visible, project
  end

  test "visible includes projects without an owner record" do
    project = Project.create!(url: "https://github.com/unknown-owner/project")

    assert_includes Project.visible, project
  end

  test "does not enqueue or sync projects belonging to hidden owners" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "hidden-owner")
    project = Project.create!(
      host: host,
      owner_record: owner,
      url: "https://github.com/hidden-owner/project"
    )
    owner.update!(hidden: true)

    assert_no_difference -> { SyncProjectWorker.jobs.size } do
      project.sync_async
    end
    assert_not_requested :get, project.url
    assert_nil project.sync
  end

  test "find_or_create_owner preserves a hidden tombstone" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "hidden-owner", hidden: true)
    project = Project.create!(url: "https://github.com/other-owner/project", host: host)
    project.update_column(:owner, {
      "login" => "hidden-owner",
      "hidden" => false,
      "name" => "Hidden Owner"
    })

    project.find_or_create_owner

    assert owner.reload.hidden?
    assert_nil owner.name
    assert_equal owner, project.reload.owner_record
    assert_equal 0, owner.projects_count
  end

  test "owner project count tracks the scientific threshold" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "science-owner")
    project = Project.create!(
      url: "https://github.com/science-owner/project",
      owner_record: owner,
      science_score: 19.9
    )

    assert_equal 0, owner.reload.projects_count

    project.update!(science_score: 20)
    assert_equal 1, owner.reload.projects_count

    project.update!(science_score: 19.9)
    assert_equal 0, owner.reload.projects_count
  end

  test "owner project count repair counts only scientific projects" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "repair-owner")
    Project.create!(
      url: "https://github.com/repair-owner/scientific",
      owner_record: owner,
      science_score: 20
    )
    Project.create!(
      url: "https://github.com/repair-owner/below-threshold",
      owner_record: owner,
      science_score: 19.9
    )
    owner.update_column(:projects_count, 10)

    changes = Project.counter_culture_fix_counts(only: :owner_record)

    assert_equal 1, owner.reload.projects_count
    assert_equal 1, changes.length
  end

  test "packages_sorted_ids returns cached sorted project ids" do
    project1 = Project.create!(
      url: 'https://github.com/test/project1',
      science_score: 50,
      packages: [{ 'name' => 'pkg1', 'downloads' => 1000 }]
    )
    project2 = Project.create!(
      url: 'https://github.com/test/project2',
      science_score: 75,
      packages: [{ 'name' => 'pkg2', 'downloads' => 5000 }]
    )
    project3 = Project.create!(
      url: 'https://github.com/test/project3',
      science_score: 0,
      packages: [{ 'name' => 'pkg3', 'downloads' => 10000 }]
    )

    Rails.cache.clear
    ids = Project.packages_sorted_ids

    assert_includes ids, project1.id
    assert_includes ids, project2.id
    assert_not_includes ids, project3.id
    assert_equal project2.id, ids.first
  end

  test "packages_sorted returns projects in correct order" do
    project1 = Project.create!(
      url: 'https://github.com/test/project1',
      science_score: 50,
      packages: [{ 'name' => 'pkg1', 'downloads' => 1000 }]
    )
    project2 = Project.create!(
      url: 'https://github.com/test/project2',
      science_score: 75,
      packages: [{ 'name' => 'pkg2', 'downloads' => 5000 }]
    )

    Rails.cache.clear
    projects = Project.packages_sorted

    assert_equal 2, projects.length
    assert_equal project2.id, projects.first.id
    assert_equal project1.id, projects.last.id
  end

  test "all_package_and_project_names returns unique lowercase names" do
    Project.create!(
      url: 'https://github.com/test/project1',
      name: 'Climate Tool',
      science_score: 50,
      packages: [{ 'name' => 'climate-pkg' }, { 'name' => 'Weather-Lib' }]
    )
    Project.create!(
      url: 'https://github.com/test/project2',
      name: 'Weather System',
      science_score: 75,
      packages: [{ 'name' => 'weather-lib' }, { 'name' => 'climate-pkg' }]
    )

    Rails.cache.clear
    names = Project.all_package_and_project_names

    assert_includes names, 'climate-pkg'
    assert_includes names, 'weather-lib'
    assert_includes names, 'climate tool'
    assert_includes names, 'weather system'
    assert_equal names, names.uniq
    assert_equal names, names.sort
  end

  test "cff_to_codemeta converts citation file to codemeta format" do
    project = Project.create!(url: 'https://github.com/test/cff-project')
    cff_content = <<~CFF
      cff-version: 1.2.0
      message: "If you use this software, please cite it as below."
      title: "Test Software"
      authors:
        - family-names: "Doe"
          given-names: "John"
          email: "john@example.com"
      abstract: "A test software package"
      version: "1.0.0"
      license: MIT
      repository-code: "https://github.com/test/cff-project"
      keywords:
        - testing
        - software
    CFF
    project.update(citation_file: cff_content)

    codemeta = project.cff_to_codemeta

    assert_not_nil codemeta
    assert_equal "Test Software", codemeta["name"]
    assert_equal "A test software package", codemeta["description"]
    assert_equal "1.0.0", codemeta["softwareVersion"]
    assert_equal "https://github.com/test/cff-project", codemeta["codeRepository"]
    assert_includes codemeta["keywords"], "testing"
  end

  test "exportable_metadata returns codemeta when available" do
    project = Project.create!(url: 'https://github.com/test/exportable')
    codemeta_json = { "@type" => "SoftwareSourceCode", "name" => "Test" }
    project.update(codemeta: codemeta_json.to_json)

    metadata = project.exportable_metadata

    assert_not_nil metadata
    assert_equal "Test", metadata["name"]
  end

  test "exportable_metadata falls back to converted CFF" do
    project = Project.create!(url: 'https://github.com/test/fallback')
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Fallback Test"
      authors:
        - family-names: "Smith"
          given-names: "Jane"
    CFF
    project.update(citation_file: cff_content)

    metadata = project.exportable_metadata

    assert_not_nil metadata
    assert_equal "Fallback Test", metadata["name"]
  end

  test "exportable_metadata returns nil when no metadata available" do
    project = Project.create!(url: 'https://github.com/test/no-metadata')

    metadata = project.exportable_metadata

    assert_nil metadata
  end

  test "export_citation generates bibtex from CFF" do
    project = Project.create!(url: 'https://github.com/test/export')
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Export Test"
      authors:
        - family-names: "Author"
          given-names: "Test"
    CFF
    project.update(citation_file: cff_content)

    bibtex = project.export_citation(format: 'bibtex')

    assert_not_nil bibtex
    assert_match(/@software/, bibtex)
  end

  test "export_citation generates apalike from CFF" do
    project = Project.create!(url: 'https://github.com/test/export-apa')
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Export Test"
      authors:
        - family-names: "Author"
          given-names: "Test"
    CFF
    project.update(citation_file: cff_content)

    apalike = project.export_citation(format: 'apalike')

    assert_not_nil apalike
    assert_match(/Export Test/, apalike)
  end

  test "export_citation returns nil when no metadata available" do
    project = Project.create!(url: 'https://github.com/test/no-export')

    result = project.export_citation(format: 'bibtex')

    assert_nil result
  end
end
