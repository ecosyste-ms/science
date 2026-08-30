require "test_helper"

class PackagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @pypi = create_registry("pypi.org", "pypi", "pypi")
    @cran = create_registry("cran.r-project.org", "cran", "cran")
    @npm = create_registry("npmjs.org", "npm", "npm")
    @computer_science = Field.create!(
      name: "Computer Science",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/17"
    )
    @medicine = Field.create!(
      name: "Medicine",
      domain: "Health Sciences",
      openalex_id: "https://openalex.org/fields/27"
    )
    @computing_project = create_project("computing", @computer_science)
    @medicine_project = create_project("medicine", @medicine)
    @non_scientific_project = Project.create!(
      url: "https://github.com/test/non-scientific-package-user",
      science_score: Project::SCIENCE_SCORE_THRESHOLD - 1
    )
    @numpy = create_package(@pypi, "numpy", "Numerical arrays")
    @scipy = create_package(@pypi, "scipy", "Scientific computing")
    @sf = create_package(@cran, "sf", "Simple features")
    @frontend = create_package(@npm, "frontend-only", "Not science")
    create_dependency(@computing_project, @numpy)
    create_dependency(@medicine_project, @numpy)
    create_dependency(@computing_project, @scipy)
    create_dependency(@medicine_project, @sf)
    create_dependency(@non_scientific_project, @frontend)
    @numpy.update!(
      published_by_project: @computing_project,
      repository_url: "https://github.com/numpy/numpy"
    )
    @scipy.update!(repository_url: "https://github.com/scipy/scipy")
  end

  test "index ranks packages by distinct scientific projects" do
    get packages_url

    assert_response :success
    assert_select "h1", text: "Scientific Packages"
    assert_select "a[href='#{packages_path}']", text: "Packages"
    assert_select "[data-package-id='#{@numpy.id}'] [data-dependent-projects-count='2']"
    assert_select "[data-package-id='#{@scipy.id}'] [data-dependent-projects-count='1']"
    assert_select "[data-package-id='#{@sf.id}'] [data-dependent-projects-count='1']"
    assert_select "[data-package-id='#{@numpy.id}'] h3 a[href='#{project_path(@computing_project)}']",
      text: @numpy.name
    assert_select "[data-package-id='#{@numpy.id}'] a[href='#{@numpy.repository_url}']",
      count: 0
    assert_select "[data-package-id='#{@scipy.id}'] h3 a[href='#{@scipy.repository_url}']",
      text: @scipy.name
    assert_no_match @frontend.name, response.body
    assert_select "[data-package-id]" do |elements|
      assert_equal [@numpy.id, @scipy.id, @sf.id],
        elements.map { |element| element["data-package-id"].to_i }
    end
  end

  test "ecosystem filter keeps packages from the selected ecosystem" do
    get packages_url, params: { ecosystem: "pypi" }

    assert_response :success
    assert_match @numpy.name, response.body
    assert_match @scipy.name, response.body
    assert_no_match @sf.name, response.body
  end

  test "domain filter recalculates counts for projects in that domain" do
    get packages_url, params: { domain: "physical-sciences" }

    assert_response :success
    assert_select "[data-package-id='#{@numpy.id}'] [data-dependent-projects-count='1']"
    assert_select "[data-package-id='#{@scipy.id}'] [data-dependent-projects-count='1']"
    assert_no_match @sf.name, response.body
  end

  test "field filter limits packages to projects classified in that field" do
    get packages_url, params: { field: @medicine.to_param }

    assert_response :success
    assert_select "[data-package-id='#{@numpy.id}'] [data-dependent-projects-count='1']"
    assert_select "[data-package-id='#{@sf.id}'] [data-dependent-projects-count='1']"
    assert_no_match @scipy.name, response.body
  end

  test "index escapes package metadata" do
    @numpy.update!(metadata: { "description" => "<script>alert(1)</script>" })

    get packages_url

    assert_response :success
    assert_no_match "<script>alert", response.body
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
      url: "https://github.com/test/#{name}-package-user",
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

  def create_package(registry, name, description)
    Package.create!(
      package_registry: registry,
      name: name,
      purl: "pkg:#{registry.purl_type}/#{name}",
      metadata: { "description" => description }
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
