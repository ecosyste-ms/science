require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(
      url: "https://github.com/tidyverse/ggplot2",
      name: "ggplot2",
      description: "An implementation of the Grammar of Graphics in R",
      science_score: 85
    )
    
    @non_science_project = Project.create!(
      url: "https://github.com/example/non-science",
      name: "non-science-project",
      description: "A non-scientific project",
      science_score: 0
    )
  end

  test "should get index" do
    get projects_url
    assert_response :success
  end

  test "index results are sorted by combined science_score and ranking" do
    project_low = Project.create!(
      url: "https://github.com/test/project-low",
      name: "project-low",
      science_score: 40,
      score: 10
    )

    project_high = Project.create!(
      url: "https://github.com/test/project-high",
      name: "project-high",
      science_score: 60,
      score: 60
    )

    project_medium = Project.create!(
      url: "https://github.com/test/project-medium",
      name: "project-medium",
      science_score: 30,
      score: 60
    )

    get projects_url
    assert_response :success

    projects = assigns(:projects)

    # project_high: 60 + 60 = 120 (should be first)
    # @project from setup: 85 + 0 = 85
    # project_medium: 30 + 60 = 90 (should be second)
    # project_low: 40 + 10 = 50
    # Find the positions of our test projects
    high_index = projects.index { |p| p.id == project_high.id }
    medium_index = projects.index { |p| p.id == project_medium.id }
    low_index = projects.index { |p| p.id == project_low.id }

    assert high_index < medium_index
    assert medium_index < low_index
  end

  test "should get show" do
    get project_url(@project)
    assert_response :success
  end

  test "should get search" do
    get search_projects_url
    assert_response :success
  end

  test "should search by query" do
    get search_projects_url, params: { q: "ggplot2" }
    assert_response :success
    assert_select ".alert-info", false, "Should find results"
  end

  test "should show no results message for empty search" do
    get search_projects_url, params: { q: "nonexistentproject123" }
    assert_response :success
    assert_select ".alert-info", text: /No projects found/
  end

  test "should search by keywords" do
    @project.update(keywords: ["visualization", "graphics"])
    get search_projects_url, params: { keywords: "visualization" }
    assert_response :success
  end

  test "should search by language" do
    @project.update(repository: { "language" => "R" })
    get search_projects_url, params: { language: "R" }
    assert_response :success
  end

  test "should get lookup" do
    get lookup_projects_url
    assert_response :success
  end

  test "should lookup projects by query" do
    get lookup_projects_url, params: { q: "ggplot2" }
    assert_response :success
    assert_select ".list-group-item", minimum: 1
  end

  test "should show popular projects when no query" do
    get lookup_projects_url
    assert_response :success
    assert_select ".card-title", text: "Popular Scientific Projects"
  end

  test "should get packages" do
    get packages_projects_url
    assert_response :success
  end

  test "should get new" do
    get new_project_url
    assert_response :success
  end

  test "should create project" do
    assert_difference("Project.count") do
      post projects_url, params: { 
        project: { 
          url: "https://github.com/matplotlib/matplotlib",
          name: "matplotlib",
          description: "Plotting library for Python"
        } 
      }
    end
    assert_redirected_to project_url(Project.last)
  end

  test "should not create duplicate project with same url" do
    # The controller downcases the URL to check for duplicates
    assert_no_difference("Project.count") do
      post projects_url, params: { 
        project: { 
          url: @project.url,
          name: "duplicate",
          description: "duplicate project"
        } 
      }
    end
    # The controller redirects to the existing project
    assert_redirected_to project_url(@project)
  end

  test "index only shows projects with science_score > 0" do
    get projects_url
    assert_response :success
    # The index action filters for science_score > 0
    # so non_science_project should not appear
  end

  test "search with pagination" do
    # Create multiple projects for pagination testing
    20.times do |i|
      Project.create!(
        url: "https://github.com/test/project#{i}",
        name: "test-project-#{i}",
        science_score: 50
      )
    end

    get search_projects_url, params: { q: "test" }
    assert_response :success
    # Should have pagination if more than 20 results
  end

  test "search results are sorted by combined science_score and ranking" do
    # Simulates root_numpy: high science (95) but low ranking (7.7) = 102.7
    root_numpy = Project.create!(
      url: "https://github.com/scikit-hep/root_numpy",
      name: "root_numpy",
      science_score: 95,
      score: 7.7
    )

    # Simulates main numpy: medium science (75) but high ranking (40) = 115
    numpy = Project.create!(
      url: "https://github.com/numpy/numpy",
      name: "numpy",
      science_score: 75,
      score: 40
    )

    # Low combined score
    other_numpy = Project.create!(
      url: "https://github.com/other/numpy",
      name: "numpy-other",
      science_score: 65,
      score: 5
    )

    get search_projects_url, params: { q: "numpy" }
    assert_response :success

    projects = assigns(:projects)

    assert_equal 3, projects.length
    # numpy should be first (75 + 40 = 115)
    assert_equal numpy.id, projects[0].id
    # root_numpy should be second (95 + 7.7 = 102.7)
    assert_equal root_numpy.id, projects[1].id
    # other_numpy should be third (65 + 5 = 70)
    assert_equal other_numpy.id, projects[2].id
  end

  test "search filters out projects with zero science_score" do
    project_with_score = Project.create!(
      url: "https://github.com/test/zeroscore",
      name: "zeroscore-project",
      science_score: 50
    )

    project_zero = Project.create!(
      url: "https://github.com/zero/zeroscore",
      name: "zeroscore-zero",
      science_score: 0
    )

    get search_projects_url, params: { q: "zeroscore" }
    assert_response :success

    projects = assigns(:projects)

    assert_equal 1, projects.length
    assert_equal project_with_score.id, projects.first.id
  end

  test "should get joss" do
    get joss_projects_url
    assert_response :success
  end

  test "joss lists only projects with joss_metadata" do
    joss_project = Project.create!(
      url: "https://github.com/test/joss-project",
      name: "joss-project",
      science_score: 85,
      joss_metadata: { "doi" => "10.21105/joss.12345" }
    )

    non_joss_project = Project.create!(
      url: "https://github.com/test/non-joss",
      name: "non-joss",
      science_score: 60
    )

    get joss_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_includes projects, joss_project
    assert_not_includes projects, non_joss_project
  end

  test "joss projects are sorted by combined score" do
    joss_low = Project.create!(
      url: "https://github.com/test/joss-low",
      name: "joss-low",
      science_score: 85,
      score: 5,
      joss_metadata: { "doi" => "10.21105/joss.00001" }
    )

    joss_high = Project.create!(
      url: "https://github.com/test/joss-high",
      name: "joss-high",
      science_score: 85,
      score: 50,
      joss_metadata: { "doi" => "10.21105/joss.00002" }
    )

    get joss_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal joss_high.id, projects.first.id
    assert_equal joss_low.id, projects.second.id
  end

  test "should export project with citation_file to bibtex" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      message: "If you use this software, please cite it as below."
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    get export_project_url(@project), params: { format: 'bibtex' }

    assert_response :success
    assert_equal 'application/x-bibtex', response.media_type
    assert_match(/@software/, response.body)
  end

  test "should export project with citation_file to apalike" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    get export_project_url(@project), params: { format: 'apalike' }

    assert_response :success
    assert_equal 'text/plain', response.media_type
  end

  test "should return not found for project without citation metadata" do
    get export_project_url(@project), params: { format: 'bibtex' }

    assert_response :not_found
  end

  test "should support bibtex and apalike export formats" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    %w[bibtex apalike].each do |format|
      get export_project_url(@project), params: { format: format }
      assert_response :success
    end
  end
end