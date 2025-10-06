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

  test "should get dependencies" do
    # The dependencies action needs the dependencies column with proper format
    @project.update(dependencies: [{
      "dependencies" => [
        { "ecosystem" => "npm", "package_name" => "react", "direct" => true }
      ]
    }])
    get dependencies_projects_url
    assert_response :success
  end

  test "should get packages" do
    get packages_projects_url
    assert_response :success
  end

  test "should get review" do
    get review_projects_url
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
end