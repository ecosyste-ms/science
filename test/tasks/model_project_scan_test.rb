require "test_helper"
require "rake"
require "tempfile"
require_relative "../support/model_repository"

class ModelProjectScanTest < ActiveSupport::TestCase
  include ModelRepository

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:collect_huggingface")
    @original_file = ENV["FILE"]
    @original_output = ENV.delete("OUTPUT")
    @file = Tempfile.new(["model-versions", ".json"])
    ENV["FILE"] = @file.path
    build_model_repository
    registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    @package = registry.packages.create!(name: "Example/Model", purl: "pkg:huggingface/Example/Model", ecosystems_id: 123,
      metadata: { "id" => 123, "purl" => "pkg:huggingface/Example/Model", "repository_url" => nil,
        "latest_release_number" => @revision, "keywords" => [], "versions_url" => "https://packages.ecosyste.ms/api/v1/registries/huggingface.co/packages/Example%2FModel/versions" })
    @version = @package.package_versions.create!(number: @revision, purl: "#{@package.purl}@#{@revision}", ecosystems_id: 456, fetched_at: Time.current)
    @origin = "https://huggingface.co/Example/Model"
  end

  teardown do
    ENV["FILE"] = @original_file
    ENV["OUTPUT"] = @original_output
    @file.close!
    FileUtils.remove_entry(@repository_directory)
  end

  def collect(purls = [@version.purl])
    File.write(@file.path, purls.to_json)
    Rake::Task["packages:collect_huggingface"].reenable
    JSON.parse(capture_io { Rake::Task["packages:collect_huggingface"].invoke }.first)
  end

  test "task scans a pinned checkout onto a model project and reuses Brief for candidates" do
    original_version = @version.attributes
    original_metadata = @package.metadata.deep_dup
    use_local_model_checkout(@origin)
    assert_difference "Project.count", 1 do
      assert_no_difference ["Package.count", "PackageVersion.count", "Paper.count", "PackagePaper.count", "PackageProject.count", "Mention.count"] do
        @report = collect([@version.purl, @version.purl])
      end
    end
    assert_equal({ "complete" => 1 }, @report["counts"])
    row = @report["versions"].sole
    project = @package.reload.published_by_project
    assert_equal @origin, project.url
    assert project.model_project?
    assert project.last_synced_at
    assert_equal project.id, row["project_id"]
    assert_equal @revision, project.brief["revision"]
    assert_equal "README.md", project.readme_file_name
    assert_includes project.readme, "Research model"
    assert_equal "numpy", project.brief["dependencies"].sole["name"]
    assert_equal "Research model", project.brief.dig("resources", "readme_bibtex", "entries", 0, "title")
    assert_equal original_version, @version.reload.attributes
    assert_nil @package.repository_url
    assert_equal original_metadata, @package.metadata
    assert Project.eligible_for_brief.exists?(project.id)
    assert Package.version_importable.exists?(@package.id)
    RepositoryBriefScan.expects(:call).never
    candidates = PackageCitationCandidates.new.call(@report)
    assert_equal "10.1234/model", candidates["candidates"].sole["identifier"]
    assert_not_requested :any, /.*/
  end

  test "Project sync refreshes model metadata without service lookups or rescanning the same revision" do
    project = PackageRepository.link!(@package)
    project.update!(dependencies_indexed_at: 1.day.ago, dependencies_index_error: "old")
    use_local_model_checkout(@origin)
    SyncProjectWorker.new.perform(project.id)
    project.reload
    assert_equal @revision, project.brief["revision"]
    assert_nil project.dependencies_indexed_at
    assert_nil project.dependencies_index_error
    assert project.last_synced_at
    assert_equal "HuggingFace.co", project.host.name
    assert_nil @package.reload.repository_url
    RepositoryCheckout.expects(:new).never
    SyncProjectWorker.new.perform(project.id)
    assert_equal @revision, project.reload.brief["revision"]
    assert_not_requested :any, /.*/
  end

  test "collection maps card and Brief evidence into normal project fields" do
    @package.update!(metadata: @package.metadata.merge("downloads" => 100, "keywords_array" => ["research"],
      "metadata" => { "pipeline_tag" => "feature-extraction", "library_name" => "transformers",
        "created_at" => "2024-01-01T00:00:00Z", "last_modified" => "2024-02-01T00:00:00Z" }))
    File.write(File.join(@repository_directory, "model.py"), "import numpy\n")
    update_readme("---\nlanguage: [en, fr]\nlicense: mit\ntags: [embeddings]\nmodel_name: Research encoder\n---\n# Model card for Encoder\n\nAn encoder for comparing scientific abstracts across multiple languages.\n")
    use_local_model_checkout(@origin)

    assert_no_difference ["Mention.count", "PackagePaper.count", "PackageProject.count"] do
      assert_equal({ "complete" => 1 }, collect["counts"])
    end
    project = @package.reload.published_by_project
    assert_equal "Research encoder", project.to_s
    assert_equal "An encoder for comparing scientific abstracts across multiple languages.", project.description
    assert_equal "Python", project.language
    assert_equal "mit", project.repository_license
    assert_equal ["research", "embeddings"], project.keywords
    assert_equal ["en", "fr"], project.repository.dig("metadata", "details", "supported_languages")
    assert_equal ["feature-extraction"], project.repository.dig("metadata", "details", "tasks")
    assert_equal ["transformers"], project.repository.dig("metadata", "details", "libraries")
    assert_equal "2024-01-01T00:00:00Z", project.repository["created_at"]
    assert_in_delta Math.log(100), project.score

    project.update!(name: "Curated name", description: "Curated description")
    RepositoryCheckout.expects(:new).never
    SyncProjectWorker.new.perform(project.id)
    assert_equal "Curated name", project.reload.to_s
    assert_equal "Curated description", project.description
    assert_in_delta Math.log(100), project.score
    assert_not_requested :any, /.*/
  end

  test "task preserves UTF-8 resource text through scanning and persistence" do
    content = "# Modèle scientifique\nEmbeddings multilingues: 日本語\n"
    update_readme(content)
    use_local_model_checkout(@origin)

    row = collect["versions"].sole

    assert_equal "complete", row["status"]
    file = row["files"].find { |resource| resource["path"] == "README.md" }
    assert_equal content, file["content"]
    project = @package.reload.published_by_project
    assert_equal content, project.readme
    assert_equal "Modèle scientifique", project.readme_name
  end

  test "repository scan worker uses the same metadata extractor for ordinary projects" do
    project = Project.create!(url: "https://github.com/example/library", science_score: 1,
      repository: { "html_url" => "https://github.com/example/library", "topics" => [],
        "host" => { "name" => "GitHub" }, "owner" => "example" },
      readme: "# Scientific library\n\nA library for comparing measurements from independent scientific experiments.\n")
    checkout = RepositoryCheckout.new(@local_origin)
    RepositoryCheckout.expects(:new).with(project.url, revision: nil, skip_lfs: false).returns(checkout)

    RepositoryScanWorker.new.perform(project.id)

    assert_equal "A library for comparing measurements from independent scientific experiments.", project.reload.description
    assert_equal "Scientific library", project.repository["name"]
    assert_equal "Scientific library", project.name
    assert project.brief["dependencies"].any?
    assert_not_requested :any, /.*/
  end

  test "task rejects invalid UTF-8 resources without storing their content" do
    update_readme("# Model\nInvalid: \xFF\n".b)
    use_local_model_checkout(@origin)

    row = collect["versions"].sole

    assert_equal "partial", row["status"]
    file = row["files"].find { |resource| resource["path"] == "README.md" }
    assert_equal "Expected UTF-8 text", file["error"]
    assert_nil @package.reload.published_by_project.readme
  end

  def update_readme(content)
    File.binwrite(File.join(@repository_directory, "README.md"), content)
    git("-C", @repository_directory, "add", ".")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Update README")
    @revision = git("-C", @repository_directory, "rev-parse", "HEAD").strip
    @package.update!(metadata: @package.metadata.merge("latest_release_number" => @revision))
    @version.update!(number: @revision, purl: "#{@package.purl}@#{@revision}")
  end

  test "a new package revision refreshes existing Project scan data and invalidates old SWHIDs" do
    project = PackageRepository.link!(@package)
    use_local_model_checkout(@origin)
    SyncProjectWorker.new.perform(project.id)
    project.reload.update!(swhids: { "commit" => @revision, "status" => "success", "history_archive" => { "complete" => true } })
    File.write(File.join(@repository_directory, "README.md"), "# Updated model\n")
    git("-C", @repository_directory, "add", ".")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Update model")
    revision = git("-C", @repository_directory, "rev-parse", "HEAD").strip
    @package.reload.update!(metadata: @package.metadata.merge("latest_release_number" => revision))
    use_local_model_checkout(@origin, revision: revision)
    SyncProjectWorker.new.perform(project.id)
    project.reload
    assert_equal revision, project.brief["revision"]
    assert_equal "# Updated model\n", project.readme
    assert_nil project.swhids["history_archive"]
    assert_nil project.brief.dig("resources", "readme_bibtex")
    assert_equal "#{@origin}/blob/#{revision}/README.md", project.readme_url
  end

  test "metadata refresh retains the model publisher and separate implementation relationship" do
    project = PackageRepository.link!(@package)
    implementation = Project.create!(url: "https://github.com/example/code")
    link = PackageProject.create!(package: @package, project: implementation, role: "model_implementation",
      evidence: [{ "source" => "review", "url" => implementation.url }])
    attributes = link.attributes
    @package.record_ecosystems_match!(@package.metadata.merge("description" => "Updated package description", "repository_url" => implementation.url))
    assert_equal project.id, @package.reload.published_by_project_id
    assert_equal attributes, link.reload.attributes
    assert_equal implementation.url, @package.repository_url
    assert_equal "Updated package description", project.reload.description
    assert_equal "Updated package description", project.packages.sole["description"]
  end

  test "does not replace an existing publishing project" do
    implementation = Project.create!(url: "https://github.com/example/existing")
    @package.update!(published_by_project: implementation)
    RepositoryCheckout.expects(:new).never
    assert_no_difference "Project.count" do
      assert_equal "error", collect["versions"].sole["status"]
    end
    assert_equal implementation.id, @package.reload.published_by_project_id
  end

  test "missing revision records a scan error without falling back to HEAD" do
    missing = "a" * 40
    @version.update!(number: missing, purl: "#{@package.purl}@#{missing}")
    use_local_model_checkout(@origin, revision: missing)
    row = collect["versions"].sole
    assert_equal "error", row["status"]
    assert_empty row["files"]
    project = @package.reload.published_by_project
    assert project.brief["error"]
    assert_nil project.readme
  end

  test "validates all selected identities before creating projects or cloning" do
    RepositoryCheckout.expects(:new).never
    [[], [@version.purl, @package.purl], [@version.purl, "pkg:huggingface/unknown/model@#{@revision}"], Array.new(26, @version.purl)].each do |input|
      assert_no_difference "Project.count" do
        assert_raises(ArgumentError) { collect(input) }
      end
    end
  end

  test "writes a reusable JSON report separately from task logging" do
    Tempfile.create(["model-report", ".json"]) do |output|
      ENV["OUTPUT"] = output.path
      File.write(@file.path, [@version.purl].to_json)
      use_local_model_checkout(@origin)
      Rake::Task["packages:collect_huggingface"].reenable
      capture_io { Rake::Task["packages:collect_huggingface"].invoke }
      assert_equal({ "complete" => 1 }, JSON.parse(File.read(output.path))["counts"])
      ENV["OUTPUT"] = @file.path
      Rake::Task["packages:collect_huggingface"].reenable
      assert_raises(ArgumentError) { Rake::Task["packages:collect_huggingface"].invoke }
    end
  end
end
