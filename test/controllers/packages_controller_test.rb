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

  test "index lists packages from scientific publishers ordered by science score" do
    @medicine_project.update!(science_score: 85)
    @scipy.update!(published_by_project: @medicine_project)
    @frontend.update!(published_by_project: @non_scientific_project)

    get packages_url

    assert_response :success
    assert_select "h1", text: "Scientific Packages"
    assert_select "a[href='#{packages_path}']", text: "Packages"
    assert_select "[data-package-id='#{@numpy.id}'] h3 a[href='#{project_path(@computing_project)}']",
      text: @numpy.name
    assert_select "[data-dependent-projects-count]", count: 0
    assert_select "form[action='#{packages_path}']", count: 0
    assert_no_match @frontend.name, response.body
    assert_no_match @sf.name, response.body
    assert_select "[data-package-id]" do |elements|
      assert_equal [@scipy.id, @numpy.id],
        elements.map { |element| element["data-package-id"].to_i }
    end
  end

  test "index displays package papers and publisher references once per paper" do
    paper = Paper.create!(title: "Array methods", openalex_id: "https://openalex.org/W1234")
    evidence = [{ "source" => "readme", "url" => @computing_project.url }]
    @numpy.package_papers.create!(paper: paper, role: "reference", evidence: evidence)
    @computing_project.project_papers.create!(paper: paper, role: "reference", evidence: evidence)
    get packages_url
    assert_response :success
    assert_select "[data-package-id='#{@numpy.id}'] [data-related-paper-id='#{paper.id}']", count: 1
    assert_select "[data-package-id='#{@numpy.id}'] a[href='https://openalex.org/W1234']", text: "Array methods"
  end

  test "published project labels use the repository slug when the name is missing" do
    publisher = Project.create!(
      url: "https://github.com/test/unnamed-package-publisher",
      science_score: 60
    )
    @numpy.update!(published_by_project: publisher)

    get packages_url

    assert_response :success
    assert_select "[data-package-id='#{@numpy.id}'] p a", text: "unnamed-package-publisher"
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

  test "index renders a page past the last package" do
    get packages_url, params: { page: 99 }
    assert_response :success
  end
end
