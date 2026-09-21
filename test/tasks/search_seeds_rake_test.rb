require "test_helper"
require "rake"
require "sqlite3"
require "tmpdir"

class SearchSeedsRakeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("search_seeds:export")
    Rake::Task["search_seeds:export"].reenable
    @original_env = %w[OUTPUT LIMIT].to_h { |key| [key, ENV[key]] }
    @directory = Dir.mktmpdir("search-seeds-test")
    ENV["OUTPUT"] = File.join(@directory, "snapshot.sqlite3")
    ENV.delete("LIMIT")
    @records = []
  end

  teardown do
    @records.each { |record| record.destroy! if record.persisted? }
    @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@directory)
  end

  test "rake task writes queryable identities, provenance, coverage and snapshot metadata" do
    project = create(Project,
      url: "https://github.com/export/climate", name: "Climate's Tools\nLab", science_score: 50,
      repository: { "archived" => true, "previous_names" => ["export/ClimateLegacy"] },
      packages: [{ "name" => "STATS", "ecosystem" => "conda" }],
      codemeta: { "identifier" => "10.1234/climate" }.to_json
    )
    other = create(Project, url: "https://github.com/export/stats", name: "Stats", science_score: 50)
    create(Project, url: "https://github.com/export/below-threshold", science_score: 19)
    host = create(Host, name: "Export GitHub")
    owner = create(Owner, host: host, login: "hidden", hidden: true)
    hidden = create(Project, url: "https://github.com/export/hidden", science_score: 50)
    hidden.update_columns(owner_id: owner.id)
    registry = create(PackageRegistry,
      name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi"
    )
    package = create(Package,
      name: "Stats", package_registry: registry, published_by_project: project, purl: "pkg:pypi/stats"
    )
    field = create(Field, name: "Export Physics", domain: "Physical Sciences", openalex_id: "fields/31")
    create(ProjectField, project: project, field: field, confidence_score: 0.8)

    output, progress = capture_io { Rake::Task["search_seeds:export"].invoke }

    result = JSON.parse(output)
    assert_equal ENV.fetch("OUTPUT"), result.fetch("output")
    assert_equal 2, result.dig("counts", "projects")
    assert_includes progress, "Exported 2 projects"
    SQLite3::Database.new(result.fetch("output")) do |db|
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      assert_empty db.execute("PRAGMA foreign_key_check")
      assert_equal [project.id, other.id], db.execute("SELECT project_id FROM projects ORDER BY project_id").flatten
      assert_equal "Climate's Tools\nLab", db.get_first_value("SELECT value FROM seeds WHERE source = 'project.name' AND project_id = ?", project.id)
      assert_equal [package.id, "pkg:pypi/stats"], db.get_first_row("SELECT package_id, purl FROM packages WHERE package_id IS NOT NULL")
      assert_equal ["10.1234/climate", "codemeta.identifier", "software"], db.get_first_row("SELECT normalized_value, source, relation FROM seeds WHERE type = 'doi'")
      assert_equal 2, db.get_first_value("SELECT projects FROM name_collisions WHERE normalized_value = 'stats'")
      assert_equal 1, db.get_first_value("SELECT projects FROM field_coverage WHERE openalex_id = 'fields/31'")
      assert_equal 1, db.get_first_value("SELECT package_entries FROM registry_coverage WHERE registry = 'PyPI.ORG'")
      assert_equal 1, db.get_first_value("SELECT entries_without_purl FROM registry_coverage WHERE ecosystem = 'CONDA'")
      assert_equal 1, db.get_first_value("PRAGMA user_version")
      metadata = db.execute("SELECT key, value FROM metadata").to_h.transform_values { |value| JSON.parse(value) }
      assert_equal result.fetch("snapshot_id"), metadata.fetch("snapshot_id")
      assert_equal 20, metadata.dig("selection", "minimum_science_score")
      assert_nil metadata.dig("selection", "limit")
      assert_equal "repeatable_read, read_only", metadata.fetch("source_isolation")
      assert_equal 1, metadata.dig("counts", "projects_without_packages")
      assert_equal 1, metadata.dig("counts", "projects_without_dois")
      assert_equal 1, metadata.dig("counts", "projects_without_fields")
      assert_equal 1, metadata.dig("counts", "package_entries_without_package_id")
      assert_equal 1, metadata.dig("counts", "package_entries_without_purl")
      assert_match(/\A[0-9a-f]{64}\z/, metadata.fetch("extractor_sha256"))
      assert_operator Time.iso8601(metadata.fetch("completed_at")), :>=, Time.iso8601(metadata.fetch("started_at"))
      plan = db.execute("EXPLAIN QUERY PLAN SELECT * FROM seeds WHERE type = 'name' AND normalized_value = 'stats'").flatten.join(" ")
      assert_includes plan, "seeds_lookup"
    end
  end

  test "rake task honours an explicit limit and records the subset" do
    first = create(Project, url: "https://github.com/export/first", science_score: 20)
    create(Project, url: "https://github.com/export/second", science_score: 20)
    ENV["LIMIT"] = "1"

    capture_io { Rake::Task["search_seeds:export"].invoke }

    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      assert_equal [first.id], db.execute("SELECT project_id FROM projects").flatten
      assert_equal 1, JSON.parse(db.get_first_value("SELECT value FROM metadata WHERE key = 'selection'")).fetch("limit")
    end
  end

  test "invalid limits fail before creating a file" do
    ENV["LIMIT"] = "0"

    error = assert_raises(ArgumentError) { Rake::Task["search_seeds:export"].invoke }

    assert_includes error.message, "LIMIT must be a positive integer"
    assert_empty Dir.children(@directory)
  end

  test "existing output is preserved" do
    File.write(ENV.fetch("OUTPUT"), "existing snapshot")

    assert_raises(Errno::EEXIST) { Rake::Task["search_seeds:export"].invoke }

    assert_equal "existing snapshot", File.read(ENV.fetch("OUTPUT"))
    assert_equal ["snapshot.sqlite3"], Dir.children(@directory)
  end

  test "a failed export leaves no partial snapshot" do
    create(Project, url: "https://github.com/export/failure", science_score: 20)
    ProjectSearchSeeds.any_instance.stubs(:as_json).raises("source failure")

    error = assert_raises(RuntimeError) { Rake::Task["search_seeds:export"].invoke }

    assert_equal "source failure", error.message
    assert_empty Dir.children(@directory)
  end

  test "source snapshot is read only and consistent across batches" do
    first = create(Project, url: "https://github.com/export/consistent-first", name: "First", science_score: 20)
    second = create(Project, url: "https://github.com/export/consistent-second", name: "Before", science_score: 20)
    changed = false
    progress = lambda do |_message|
      assert_equal "on", Project.connection.select_value("SHOW transaction_read_only")
      assert_equal "repeatable read", Project.connection.select_value("SHOW transaction_isolation")
      next if changed

      Thread.new do
        Project.connection_pool.with_connection do
          Project.where(id: second.id).update_all(name: "After")
        end
      end.value
      changed = true
    end

    SearchSeedExport.new(output: ENV.fetch("OUTPUT"), batch_size: 1, progress: progress).export

    assert_equal "After", second.reload.name
    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      assert_equal [[first.id, "First"], [second.id, "Before"]], db.execute(
        "SELECT project_id, value FROM seeds WHERE source = 'project.name' ORDER BY project_id"
      )
    end
  end

  def create(model, **attributes)
    model.create!(attributes).tap { |record| @records.unshift(record) }
  end
end
