require "test_helper"
require "rake"
require "tmpdir"

class ScienceCohortRakeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("science_cohort:export")
    Rake::Task["science_cohort:export"].reenable
    @environment = %w[OUTPUT BATCH_SIZE].to_h { |name| [name, ENV[name]] }
    @directory = Dir.mktmpdir("science-cohort-test-")
    ENV["OUTPUT"] = File.join(@directory, "cohort.jsonl")
    ENV["BATCH_SIZE"] = "1"
    @records = []
  end

  teardown do
    @records.each { |record| record.destroy! if record.persisted? }
    @environment.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    FileUtils.remove_entry(@directory)
  end

  test "rake export freezes project and ranked dependency records with dates and hashes" do
    project, package = cohort
    create(Project, url: "https://github.com/cohort/not-scientific", science_score: 1)
    create(Package, package_registry: package.package_registry, name: "unused", purl: "pkg:pypi/unused")
    output, = capture_io { Rake::Task["science_cohort:export"].invoke }
    result = JSON.parse(output)
    assert_equal({ "projects" => 1, "packages" => 1 }, result.fetch("counts"))
    assert_equal Digest::SHA256.file(ENV.fetch("OUTPUT")).hexdigest, result.fetch("sha256")
    records = File.foreach(ENV.fetch("OUTPUT")).map { |line| JSON.parse(line) }
    assert_equal %w[snapshot project package complete], records.pluck("type")
    assert_equal "repeatable_read, read_only", records.first.dig("data", "source_isolation")
    assert_equal project.id, records[1].dig("data", "project_id")
    assert_equal "unchecked", records[1].dig("data", "swhids", "status")
    assert_equal package.id, records[2].dig("data", "id")
    assert_equal 1, records[2].dig("data", "scientific_projects_count")
    assert_equal result.fetch("snapshot_id"), records.last.dig("data", "snapshot_id")
    assert_equal result.fetch("counts"), records.last.dig("data", "counts")
  end

  test "one source snapshot spans project and package batches" do
    project, package = cohort
    changed = false
    progress = lambda do |_counts|
      assert_equal "on", Project.connection.select_value("SHOW transaction_read_only")
      assert_equal "repeatable read", Project.connection.select_value("SHOW transaction_isolation")
      next if changed

      Thread.new do
        Project.connection_pool.with_connection do
          Project.where(id: project.id).update_all(science_score: 0)
          Package.where(id: package.id).update_all(repository_url: "https://github.com/cohort/changed")
        end
      end.value
      changed = true
    end
    ScienceCohortExport.new(output: ENV.fetch("OUTPUT"), batch_size: 1, progress: progress).export
    assert_equal 0, project.reload.science_score
    records = File.foreach(ENV.fetch("OUTPUT")).map { |line| JSON.parse(line) }
    exported = records.find { |row| row["type"] == "package" }.fetch("data")
    assert_equal "https://github.com/cohort/source", exported.fetch("repository_url")
    assert_equal 1, exported.fetch("scientific_projects_count")
  end

  test "invalid requests and failed exports leave no output and existing files survive" do
    ENV["BATCH_SIZE"] = "0"
    assert_raises(ArgumentError) { Rake::Task["science_cohort:export"].invoke }
    assert_empty Dir.children(@directory)
    ENV["BATCH_SIZE"] = "1"
    Rake::Task["science_cohort:export"].reenable
    cohort
    ProjectSearchSeeds.any_instance.stubs(:as_json).raises("source failure")
    assert_raises(RuntimeError) { capture_io { Rake::Task["science_cohort:export"].invoke } }
    assert_empty Dir.children(@directory)
    File.write(ENV.fetch("OUTPUT"), "existing")
    Rake::Task["science_cohort:export"].reenable
    assert_raises(Errno::EEXIST) { Rake::Task["science_cohort:export"].invoke }
    assert_equal "existing", File.read(ENV.fetch("OUTPUT"))
  end

  def cohort
    project = create(Project, url: "https://github.com/cohort/source", name: "Source", science_score: 40)
    registry = create(PackageRegistry, name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    package = create(Package, name: "source", purl: "pkg:pypi/source", package_registry: registry,
      repository_url: project.url, published_by_project: project)
    create(ProjectDependency, project: project, package: package, package_name: package.name, ecosystem: "pypi", direct: true)
    [project, package]
  end

  def create(model, **attributes)
    model.create!(attributes).tap { |record| @records.unshift(record) }
  end
end
