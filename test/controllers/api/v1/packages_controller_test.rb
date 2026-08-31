require "test_helper"

class Api::V1::PackagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @pypi = create_registry("pypi.org", "pypi", "pypi")
    @cran = create_registry("cran.r-project.org", "cran", "cran")
    @medicine = Field.create!(
      name: "Medicine",
      domain: "Health Sciences",
      openalex_id: "https://openalex.org/fields/27"
    )
    @physics = Field.create!(
      name: "Physics and Astronomy",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/31"
    )
    @medicine_project = create_project("medicine", @medicine)
    @physics_project = create_project("physics", @physics)
    @numpy = create_package(
      @pypi,
      "numpy",
      dependent_repositories_count: 1_000,
      top_percentage: 0.05
    )
    @sf = create_package(
      @cran,
      "sf",
      dependent_repositories_count: 50,
      top_percentage: 0.16
    )
    create_dependency(@medicine_project, @numpy)
    create_dependency(@physics_project, @numpy)
    create_dependency(@medicine_project, @sf)
    @numpy.update!(published_by_project: @physics_project)
  end

  test "index returns package usage and upstream ranking data" do
    get api_v1_packages_url

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@numpy.id, @sf.id], packages.map { |package| package.fetch("id") }

    numpy = packages.first
    assert_equal "pkg:pypi/numpy", numpy.fetch("purl")
    assert_equal "pypi", numpy.dig("registry", "ecosystem")
    assert_equal 2, numpy.fetch("scientific_projects_count")
    assert_equal 1_000, numpy.fetch("dependent_repositories_count")
    assert_in_delta 0.05, numpy.fetch("dependent_repositories_top_percentage")
    assert_in_delta 1.05, numpy.fetch("average_top_percentage")
    assert_in_delta 1.05, numpy.fetch("science_relevance_top_percentage")
    assert_in_delta 70.0, numpy.fetch("repository_science_score")
    assert_in_delta 0.9826, numpy.fetch("science_relevance_score")
    assert_in_delta 0.2, numpy.fetch("science_usage_percentage")
    assert_equal @physics_project.id, numpy.dig("published_by_project", "id")
    assert_equal api_v1_project_url(@physics_project),
      numpy.dig("published_by_project", "api_url")
    assert_equal "2", response.headers.fetch("total-count")
  end

  test "index applies ecosystem and field filters" do
    get api_v1_packages_url, params: {
      ecosystem: "cran",
      field: @medicine.to_param,
    }

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@sf.id], packages.map { |package| package.fetch("id") }
    assert_equal 1, packages.first.fetch("scientific_projects_count")
  end

  test "index accepts the API page size" do
    get api_v1_packages_url, params: { per_page: 1 }

    assert_response :success
    assert_equal 1, JSON.parse(response.body).length
    assert_equal "2", response.headers.fetch("total-count")
  end

  test "index excludes packages published by a zero-score project" do
    publisher = Project.create!(
      url: "https://github.com/test/non-scientific-publisher",
      science_score: 0
    )
    package = create_package(
      @pypi,
      "non-scientific-package",
      dependent_repositories_count: 1,
      top_percentage: 1.0
    )
    create_dependency(@medicine_project, package)
    package.update!(published_by_project: publisher)

    get api_v1_packages_url

    assert_response :success
    package_ids = JSON.parse(response.body).map { |record| record.fetch("id") }
    assert_not_includes package_ids, package.id
    assert_equal "2", response.headers.fetch("total-count")
  end

  test "index orders by science relevance when requested" do
    @sf.update!(
      metadata: @sf.metadata.deep_merge(
        "rankings" => { "average" => 5.0 }
      )
    )

    get api_v1_packages_url, params: { sort: "science_relevance" }

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@sf.id, @numpy.id],
      packages.map { |package| package.fetch("id") }
    assert_in_delta 1.0, packages.first.fetch("science_relevance_score")
    assert_in_delta 0.9826, packages.second.fetch("science_relevance_score")
  end

  test "index orders by linked repository science score when requested" do
    @medicine_project.update!(science_score: 85)
    @sf.update!(published_by_project: @medicine_project)

    get api_v1_packages_url, params: { sort: "science_score" }

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@sf.id, @numpy.id],
      packages.map { |package| package.fetch("id") }
    assert_in_delta 85.0, packages.first.fetch("repository_science_score")
    assert_in_delta 70.0, packages.second.fetch("repository_science_score")
  end

  test "index ignores an unknown package ordering" do
    get api_v1_packages_url, params: { sort: "science_relevance DESC" }

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@numpy.id, @sf.id],
      packages.map { |package| package.fetch("id") }
  end

  test "index applies domain filters and recalculates project counts" do
    get api_v1_packages_url, params: { domain: "health-sciences" }

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@numpy.id, @sf.id], packages.map { |package| package.fetch("id") }
    assert packages.all? do |package|
      package.fetch("scientific_projects_count") == 1
    end
  end

  def create_registry(name, ecosystem, purl_type)
    PackageRegistry.create!(
      name: name,
      url: "https://#{name}",
      ecosystem: ecosystem,
      purl_type: purl_type,
      default: true
    )
  end

  def create_project(name, field)
    project = Project.create!(
      url: "https://github.com/test/api-package-#{name}",
      name: name.titleize,
      science_score: 70
    )
    ProjectField.create!(
      project: project,
      field: field,
      confidence_score: 0.8
    )
    project
  end

  def create_package(
    registry,
    name,
    dependent_repositories_count:,
    top_percentage:
  )
    Package.create!(
      package_registry: registry,
      name: name,
      purl: "pkg:#{registry.purl_type}/#{name}",
      metadata: {
        "description" => "#{name} description",
        "dependent_repos_count" => dependent_repositories_count,
        "rankings" => {
          "dependent_repos_count" => top_percentage,
          "average" => top_percentage + 1,
        },
      }
    )
  end

  def create_dependency(project, package)
    ProjectDependency.create!(
      project: project,
      package: package,
      ecosystem: package.package_registry.ecosystem,
      package_name: package.name,
      purl: package.purl,
      direct: true
    )
  end
end
