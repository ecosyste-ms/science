require "test_helper"
require "tmpdir"
require "open3"
require "sqlite3"

class Api::V1::DependencyEvidenceTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @directory = Dir.mktmpdir("dependency-evidence-test-")
    @records = []
    @registry = create(PackageRegistry, name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi", default: true)
  end

  teardown do
    @records.each { |record| record.destroy! if record.persisted? }
    FileUtils.remove_entry(@directory)
  end

  test "scan manifest occurrences survive indexing HTTP context and export" do
    source = File.join(@directory, "source")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "pyproject.toml"), "[project]\nname = \"analysis\"\nversion = \"0.0.0\"\ndependencies = [\"astropy>=6\"]\n")
    File.write(File.join(source, "requirements.txt"), "astropy>=6\n")
    [["git", "init", source], ["git", "-C", source, "add", "."],
      ["git", "-C", source, "-c", "user.name=Test", "-c", "user.email=test@example.org", "-c", "commit.gpgsign=false", "commit", "-m", "Dependency input"]].each do |command|
      output, status = Open3.capture2e(*command)
      assert status.success?, output
    end
    project = create(Project, url: "https://github.com/evidence/scan", science_score: 1,
      repository: { "clone_url" => source })
    JossVocabularyAnalyzer.stubs(:analyze_project).returns(score: 0, terms: [], model_id: nil)

    RepositoryScanWorker.new.perform(project.id)
    assert_equal %w[pyproject.toml requirements.txt], project.reload.brief.fetch("dependencies").pluck("manifest").sort
    assert_equal 1, Project.sync_dependencies(limit: 1).fetch(:indexed)
    dependency = project.project_dependencies.sole
    assert_equal %w[pyproject.toml requirements.txt], dependency.metadata.fetch("occurrences").pluck("filepath")
    project.update!(science_score: 50)

    get search_context_api_v1_project_url(project)

    assert_response :success
    context = response.parsed_body
    assert_equal %w[pyproject.toml requirements.txt], context.fetch("direct_dependencies").sole.fetch("occurrences").pluck("filepath")
    assert_equal context, exported_context(project)
  end

  test "batches expose resolved identity lookup state and retained metadata across HTTP and export" do
    project = create(Project, url: "https://github.com/evidence/packages", science_score: 50,
      dependencies: [{ "filepath" => "requirements.txt", "ecosystem" => "pypi", "dependencies" => %w[astropy scipy biopython].map { |name| { "package_name" => name, "direct" => true } } }])
    Project.sync_dependencies(limit: 1)
    ProjectDependencyResolver.resolve_batch!(limit: 10)
    packages = project.project_dependencies.includes(:package).map(&:package)
    packages.each { |package| @records.unshift(package) }
    packages.each_with_index do |package, index|
      stub_metadata(package, [{ "id" => index + 100, "name" => package.name, "purl" => package.purl,
        "registry" => { "name" => @registry.name }, "description" => "Stored description",
        "updated_at" => "2026-10-22T12:00:00Z" }])
    end
    client = PackagesApiClient.new(retry_requests: false)
    assert_equal 3, PackageMetadataSync.sync_batch!(client: client, limit: 10).fetch(:matched)
    packages.each { |package| package.reload.update!(ecosystems_checked_at: 31.days.ago) }
    stub_metadata(packages.find { |package| package.name == "scipy" }, [])
    stub_metadata(packages.find { |package| package.name == "biopython" }, [], status: 503)
    outcome = PackageMetadataSync.sync_batch!(client: client, limit: 10)
    assert_equal 1, outcome.fetch(:matched)
    assert_equal 1, outcome.fetch(:unavailable)
    assert_equal 1, outcome.fetch(:transient_error)

    get search_context_api_v1_project_url(project)

    assert_response :success
    context = response.parsed_body
    expected = { "astropy" => "matched", "scipy" => "unavailable", "biopython" => "transient_error" }
    context.fetch("direct_dependencies").each do |dependency|
      assert_nil dependency.fetch("purl")
      resolved = dependency.fetch("resolved_package")
      assert_equal "pkg:pypi/#{dependency.fetch('name')}", resolved.fetch("purl")
      assert_equal "pypi.org", resolved.dig("registry", "name")
      lookup = resolved.fetch("metadata_lookup")
      assert_equal expected.fetch(dependency.fetch("name")), lookup.fetch("status")
      assert lookup.fetch("checked_at").present?
      assert_equal "https://packages.ecosyste.ms/api/v1/registries/pypi.org/packages/#{dependency.fetch('name')}", lookup.fetch("source_url")
      assert_equal Time.utc(2026, 10, 22, 12), Time.iso8601(lookup.fetch("source_updated_at"))
    end
    biopython = packages.find { |package| package.name == "biopython" }.reload
    assert_equal "Stored description", biopython.metadata.fetch("description")
    assert biopython.ecosystems_retry_at.present?
    post bulk_lookup_api_v1_packages_url, params: { purls: packages.map(&:purl) }, as: :json
    assert_response :success
    response.parsed_body.each do |package|
      dependency = context.fetch("direct_dependencies").find { |row| row["package_id"] == package.fetch("id") }
      assert_equal dependency.dig("resolved_package", "metadata_lookup"), package.fetch("metadata_lookup")
    end
    assert_equal context, exported_context(project)
    loaded = ProjectSearchContext.scope.strict_loading.find(project.id)
    assert_equal context, JSON.parse(ProjectSearchContext.new(loaded).to_json)
  end

  test "context keeps source claims separate and includes unchecked and stopped lookup states" do
    project = create(Project, url: "https://github.com/evidence/states", science_score: 50)
    [nil, "missing", "ambiguous", "failed"].each do |status|
      name = status || "unchecked"
      package = create(Package, name: name, purl: "pkg:pypi/#{name}", package_registry: @registry,
        ecosystems_sync_status: status, ecosystems_checked_at: status && Time.current)
      project.project_dependencies.create!(ecosystem: "pypi", package_name: "declared-#{name}", purl: "pkg:pypi/declared-#{name}", package: package, direct: true)
    end
    project.project_dependencies.create!(ecosystem: "pypi", package_name: "unresolved", direct: true)

    get search_context_api_v1_project_url(project)

    assert_response :success
    response.parsed_body.fetch("direct_dependencies").each do |dependency|
      if dependency.fetch("name") == "unresolved"
        assert_nil dependency.fetch("resolved_package")
        next
      end
      name = dependency.fetch("name").delete_prefix("declared-")
      assert_equal "pkg:pypi/declared-#{name}", dependency.fetch("purl")
      resolved = dependency.fetch("resolved_package")
      assert_equal "pkg:pypi/#{name}", resolved.fetch("purl")
      assert_equal name, resolved.dig("metadata_lookup", "status")
      assert_nil resolved.dig("metadata_lookup", "source_url")
    end
    assert_not_requested :any, /.*/
  end

  def stub_metadata(package, records, status: 200)
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/packages/lookup").with(query: { purl: package.purl })
      .to_return(status: status, body: records.to_json, headers: { "Content-Type" => "application/json" })
  end

  def exported_context(project)
    result = SearchSeedExport.new(output: File.join(@directory, "snapshot.sqlite3")).export
    context = nil
    SQLite3::Database.new(result.fetch(:output)) do |database|
      context = JSON.parse(database.get_first_value("SELECT data FROM project_contexts WHERE project_id = ?", project.id))
    end
    context
  end

  def create(model, **attributes)
    model.create!(attributes).tap { |record| @records.unshift(record) }
  end
end
