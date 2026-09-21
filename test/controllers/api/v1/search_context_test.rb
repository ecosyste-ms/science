require "test_helper"

class Api::V1::SearchContextTest < ActionDispatch::IntegrationTest
  test "returns sourced context and indexed direct dependencies for a candidate project" do
    project = create_project(
      description: "Data analysis tools",
      repository: { "description" => "Scientific tables", "language" => "Python" },
      brief: { "languages" => [{ "name" => "Python" }, { "name" => "Cython" }] },
      codemeta: {
        "description" => "Tabular data analysis",
        "programmingLanguage" => ["Python", { "name" => "C" }],
      }.to_json,
      packages: [
        { "name" => "Tables", "purl" => "pkg:pypi/tables@1.0", "description" => "Older description" },
        { "name" => "r-tables", "ecosystem" => "conda", "description" => "Conda package" },
      ],
      dependencies: [{
        "filepath" => "pyproject.toml", "ecosystem" => "PyPI",
        "dependencies" => [
          { "package_name" => "numpy", "purl" => "pkg:pypi/numpy@2.0", "direct" => true, "requirements" => ">=2", "kind" => "runtime" },
          { "package_name" => "indirect", "direct" => false },
        ],
      }]
    )
    registry = create_registry("pypi")
    package = Package.create!(
      name: "tables", purl: "pkg:pypi/tables", package_registry: registry,
      published_by_project: project,
      metadata: { "description" => "Tables package", "language" => "Python" }
    )
    dependency_package = Package.create!(name: "numpy", purl: "pkg:pypi/numpy", package_registry: registry)
    ProjectDependencyIndexer.new(project).sync!
    dependency = project.project_dependencies.sole
    dependency.update!(package: dependency_package)
    project.project_dependencies.create!(ecosystem: "pypi", package_name: "transitive", direct: false)

    get search_context_api_v1_project_url(project)

    assert_response :success
    record = response.parsed_body
    assert_equal project.id, record.fetch("project_id")
    assert_equal project.repository_url, record.fetch("repository_url")
    assert_equal ["project.description", "repository.description", "codemeta.description"], record.fetch("descriptions").pluck("source")
    assert_equal "Data analysis tools", record.fetch("descriptions").first.fetch("value")
    assert_includes record.fetch("languages"), { "value" => "Cython", "source" => "brief.languages.name" }
    assert_includes record.fetch("languages"), { "value" => "C", "source" => "codemeta.programmingLanguage.name" }
    packages = record.fetch("packages")
    assert_equal [package.id, nil], packages.pluck("package_id")
    assert_equal "pkg:pypi/tables", packages.first.fetch("purl")
    assert_equal ["tables", "Tables"], packages.first.fetch("names").pluck("value")
    assert_equal ["Tables package", "Older description"], packages.first.fetch("descriptions").pluck("value")
    assert_equal ["package.description", "project.packages[0].description"], packages.first.fetch("descriptions").pluck("source")
    assert_equal [{ "value" => "Python", "source" => "package.language" }], packages.first.fetch("languages")
    assert_equal "conda", packages.last.fetch("ecosystem")
    assert record.fetch("dependencies_indexed_at").present?
    direct = record.fetch("direct_dependencies").sole
    assert_equal dependency.id, direct.fetch("dependency_id")
    assert_equal dependency_package.id, direct.fetch("package_id")
    assert_equal "numpy", direct.fetch("name")
    assert_equal "pkg:pypi/numpy", direct.fetch("purl")
    assert_equal "repos_manifests", direct.fetch("source")
    assert_equal "pyproject.toml", direct.fetch("occurrences").sole.fetch("filepath")
    assert_equal ">=2", direct.fetch("occurrences").sole.fetch("requirements")
    assert_equal "runtime", direct.fetch("occurrences").sole.fetch("kind")

    get search_seeds_api_v1_projects_url

    seeds = response.parsed_body.sole
    assert_not seeds.key?("descriptions")
    assert_not seeds.key?("direct_dependencies")
    assert_equal %w[ecosystem package_id purl registry seeds], seeds.fetch("packages").first.keys.sort
    assert seeds.fetch("packages").none? { |item| item["purl"] == "pkg:pypi/numpy" }
  end

  test "ignores malformed optional context without fetching or indexing metadata" do
    project = create_project(
      repository: [], brief: { "languages" => [nil, 42, { "name" => [] }] },
      codemeta: "[]", packages: [nil, "bad", { "description" => "No identity" }],
      dependencies: [{ "dependencies" => [{ "package_name" => "unindexed", "ecosystem" => "npm", "direct" => true }] }]
    )
    ProjectDependencyIndexer.any_instance.expects(:sync!).never
    Project.any_instance.expects(:sync_async).never

    get search_context_api_v1_project_url(project)

    assert_response :success
    record = response.parsed_body
    %w[descriptions languages packages direct_dependencies].each { |key| assert_empty record.fetch(key) }
    assert_nil record.fetch("dependencies_indexed_at")
    assert_nil record.fetch("last_synced_at")
  end

  test "keeps unresolved dependencies and Brief provenance" do
    project = create_project(brief: { "dependencies" => [
      { "name" => "stats", "purl" => "pkg:npm/stats@2", "direct" => true, "scope" => "development", "optional" => true },
    ] })
    ProjectDependencyIndexer.new(project).sync!

    get search_context_api_v1_project_url(project)

    assert_response :success
    dependency = response.parsed_body.fetch("direct_dependencies").sole
    assert_nil dependency.fetch("package_id")
    assert_equal "pkg:npm/stats", dependency.fetch("purl")
    assert_equal "brief", dependency.fetch("source")
    assert_equal "development", dependency.fetch("occurrences").sole.fetch("kind")
    assert_equal true, dependency.fetch("occurrences").sole.fetch("optional")
  end

  test "returns not found for hidden, below threshold and missing projects" do
    hidden = create_project
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden", hidden: true)
    hidden.update_columns(owner_id: owner.id)
    below_threshold = create_project(science_score: Project::SCIENCE_SCORE_THRESHOLD - 1)

    [hidden.id, below_threshold.id, 0].each do |id|
      get search_context_api_v1_project_url(id)
      assert_response :not_found
    end
  end

  test "keeps same-name registry packages and fork context separate" do
    project = create_project(repository: { "archived" => true })
    fork = create_project(repository: { "fork" => true, "language" => "R" })
    %w[pypi cran].each do |ecosystem|
      Package.create!(
        name: "stats", purl: "pkg:#{ecosystem}/stats", package_registry: create_registry(ecosystem),
        published_by_project: project, metadata: { "description" => "#{ecosystem} package" }
      )
    end

    get search_context_api_v1_project_url(project)

    assert_response :success
    assert_equal %w[pkg:pypi/stats pkg:cran/stats], response.parsed_body.fetch("packages").pluck("purl")

    get search_context_api_v1_project_url(fork)

    assert_response :success
    assert_empty response.parsed_body.fetch("packages")
    assert_equal [{ "value" => "R", "source" => "repository.language" }], response.parsed_body.fetch("languages")
  end

  def create_project(**attributes)
    Project.create!({ url: "https://github.com/context/#{SecureRandom.hex(6)}", science_score: 50 }.merge(attributes))
  end

  def create_registry(ecosystem)
    PackageRegistry.create!(name: "#{ecosystem}.example", url: "https://#{ecosystem}.example", ecosystem: ecosystem, purl_type: ecosystem)
  end
end
