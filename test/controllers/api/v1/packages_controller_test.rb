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
    @sf.update!(published_by_project: @medicine_project)
  end

  test "index returns packages from scientific publishers with upstream ranking data" do
    get api_v1_packages_url

    assert_response :success
    packages = JSON.parse(response.body)
    assert_equal [@numpy.id, @sf.id], packages.map { |package| package.fetch("id") }

    numpy = packages.first
    assert_equal "pkg:pypi/numpy", numpy.fetch("purl")
    assert_equal api_v1_package_versions_url(@numpy), numpy.fetch("versions_url")
    assert_equal api_v1_package_versions_url(@sf), packages.last.fetch("versions_url")
    assert_equal "pypi", numpy.dig("registry", "ecosystem")
    assert_equal 1_000, numpy.fetch("dependent_repositories_count")
    assert_in_delta 0.05, numpy.fetch("dependent_repositories_top_percentage")
    assert_in_delta 1.05, numpy.fetch("average_top_percentage")
    assert_not numpy.key?("scientific_projects_count")
    assert_equal @physics_project.id, numpy.dig("published_by_project", "id")
    assert_equal api_v1_project_url(@physics_project),
      numpy.dig("published_by_project", "api_url")
    assert_equal "2", response.headers.fetch("total-count")
  end

  test "index accepts the API page size" do
    get api_v1_packages_url, params: { per_page: 1 }

    assert_response :success
    assert_equal 1, JSON.parse(response.body).length
    assert_equal "2", response.headers.fetch("total-count")
  end

  test "index excludes packages published below the science score floor" do
    publisher = Project.create!(
      url: "https://github.com/test/non-scientific-publisher",
      science_score: 4.99
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

  test "index orders by the publishing project's science score" do
    @medicine_project.update!(science_score: 85)

    get api_v1_packages_url

    assert_response :success
    assert_equal [@sf.id, @numpy.id],
      JSON.parse(response.body).map { |package| package.fetch("id") }
  end

  test "bulk lookup includes unranked packages and has no write or job side effects" do
    publisher = Project.create!(url: "https://github.com/test/low-score", science_score: 1)
    unused = create_package(@pypi, "unused", dependent_repositories_count: 0, top_percentage: 1)
    unused.update!(published_by_project: publisher)
    before_jobs = Sidekiq::Worker.jobs.deep_dup
    assert_no_difference ["Package.count", "Project.count"] do
      post bulk_lookup_api_v1_packages_url, params: {
        purls: ["pkg:pypi/NumPy@2.0#src", "pkg:pypi/numpy", "pkg:pypi/unused", "pkg:pypi/missing"]
      }, as: :json
    end
    assert_response :success
    assert_equal [@numpy.id, unused.id].sort, response.parsed_body.pluck("id")
    assert_equal 2, response.parsed_body.first.fetch("scientific_projects_count")
    assert_equal 0, response.parsed_body.last.fetch("scientific_projects_count")
    assert_equal 1.0, response.parsed_body.last.fetch("repository_science_score")
    assert_equal before_jobs, Sidekiq::Worker.jobs
  end

  test "bulk lookup matches julia packages with or without the uuid qualifier" do
    julia = create_registry("juliahub.com", "julia", "julia")
    package = Package.create!(package_registry: julia, name: "Dates", purl: "pkg:julia/Dates?uuid=ade2ca70-3891-5945-98fb-dc099432e06a")
    assert_equal "pkg:julia/Dates", package.purl

    ["pkg:julia/Dates", "pkg:julia/Dates@1.9.0?uuid=ade2ca70-3891-5945-98fb-dc099432e06a"].each do |purl|
      post bulk_lookup_api_v1_packages_url, params: { purls: [purl] }, as: :json
      assert_response :success
      assert_equal [package.id], response.parsed_body.pluck("id")
    end
  end

  test "bulk lookup validates bounds and returns explicit empty matches" do
    [nil, [], "pkg:pypi/numpy", [nil], ["invalid"], ["x" * 2001], ["pkg:pypi/numpy"] * 101].each do |purls|
      post bulk_lookup_api_v1_packages_url, params: { purls: purls }, as: :json
      assert_response :bad_request
      assert response.parsed_body.fetch("error").present?
    end
    post bulk_lookup_api_v1_packages_url, params: { purls: ["pkg:pypi/missing"] * 100 }, as: :json
    assert_response :success
    assert_empty response.parsed_body
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
