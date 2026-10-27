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
      description: "Climate models",
      repository: { "archived" => true, "previous_names" => ["export/ClimateLegacy"], "language" => "Python",
        "fork" => false, "source_name" => nil, "mirror_url" => "https://example.org/climate", "last_synced_at" => "2026-10-23T12:00:00Z",
        "metadata" => { "r_package_descriptions" => [{ "path" => "r/DESCRIPTION", "revision" => "abc123", "sha256" => "digest",
          "fields" => { "Package" => "ClimateR", "Description" => "R climate tools", "URL" => "https://example.org/climate" } }] } },
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
    create(ProjectDependency, project: project, package_name: "numpy", ecosystem: "pypi", direct: true,
      metadata: { "source" => "repos_manifests", "occurrences" => [{ "filepath" => "requirements.txt" }] })

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
      assert_equal 2, db.get_first_value("PRAGMA user_version")
      assert_equal 2, db.get_first_value("SELECT COUNT(*) FROM project_contexts")
      context = JSON.parse(db.get_first_value("SELECT data FROM project_contexts WHERE project_id = ?", project.id))
      assert_equal "Climate models", context.fetch("descriptions").sole.fetch("value")
      assert_equal "Python", context.fetch("languages").sole.fetch("value")
      assert_equal "numpy", context.fetch("direct_dependencies").sole.fetch("name")
      assert_equal false, context.fetch("repository_provenance").fetch("fork").fetch("value")
      assert_nil context.fetch("repository_provenance").fetch("source_name").fetch("value")
      manifest = context.fetch("package_manifests").sole
      assert_equal "r/DESCRIPTION", manifest.fetch("path")
      assert_equal "ClimateR", manifest.fetch("names").sole.fetch("value")
      assert_equal "R climate tools", manifest.fetch("descriptions").sole.fetch("value")
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.get("/api/v1/projects/#{project.id}/search_context")
      assert_equal 200, session.response.status
      assert_equal session.response.parsed_body, context
      metadata = db.execute("SELECT key, value FROM metadata").to_h.transform_values { |value| JSON.parse(value) }
      assert_equal result.fetch("snapshot_id"), metadata.fetch("snapshot_id")
      assert_equal 2, metadata.fetch("schema_version")
      assert_equal 20, metadata.dig("selection", "minimum_science_score")
      assert_nil metadata.dig("selection", "limit")
      assert_equal "repeatable_read, read_only", metadata.fetch("source_isolation")
      assert_equal 1, metadata.dig("counts", "projects_without_packages")
      assert_equal 1, metadata.dig("counts", "projects_without_dois")
      assert_equal 1, metadata.dig("counts", "projects_without_fields")
      assert_equal 1, metadata.dig("counts", "package_entries_without_package_id")
      assert_equal 1, metadata.dig("counts", "package_entries_without_purl")
      assert_match(/\A[0-9a-f]{64}\z/, metadata.fetch("extractor_sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, metadata.fetch("context_extractor_sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, metadata.fetch("package_extractor_sha256"))
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

  test "literal clue export deduplicates evidence while preserving candidates matching rules and years" do
    first = create(Project, url: "https://github.com/clues/first", name: "Star", science_score: 50,
      repository: { "homepage" => "https://EXAMPLE.org/Docs", "releases_url" => "https://repos.example/first/releases" },
      release_sync_state: { "releases" => { "url" => "https://repos.example/first/releases", "page" => 1, "completed_at" => Time.current.iso8601 } },
      codemeta: { "name" => "Star", "alternateName" => ["Star", "Climate\t Lab"], "identifier" => "10.1234/Star" }.to_json,
      packages: [{ "name" => "Star", "purl" => "pkg:pypi/star", "first_release_published_at" => "2005-01-01T00:00:00Z" }])
    create(Release, project: first, tag_name: "v1", uuid: "first", published_at: "2011-01-01")
    second = create(Project, url: "https://github.com/clues/second", name: "Star", science_score: 50,
      repository: { "homepage" => "https://example.org/docs" }, codemeta: { "alternateName" => ["Climate\u00a0Lab"] }.to_json)
    create(Project, url: "https://github.com/clues/third", name: "Sage", science_score: 50)
    record = create(ExternalSoftwareRecord, source: "rrid", identifier: "SCR_002285", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 1.day.from_now)
    [first, second].each do |project|
      create(ProjectExternalSoftwareRecord, project: project, external_software_record: record,
        match_status: "matched", relationship: "source_code_repository", evidence: [{ "source_field" => "distributions.current" }])
    end
    duplicate = create(ExternalSoftwareRecord, source: "rrid", identifier: "RRID:SCR_002285", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 1.day.from_now)
    create(ProjectExternalSoftwareRecord, project: first, external_software_record: duplicate,
      match_status: "matched", relationship: "source_code_repository", evidence: [{ "source_field" => "distributions.alternate" }])
    { "wikidata" => "Q123", "biotools" => "ClimateTools", "ascl" => "2401.123", "swmath" => "123" }.each do |scheme, value|
      identifier = create(ExternalSoftwareRecord, source: scheme, identifier: value, status: "ok",
        retrieved_at: Time.current, next_refresh_at: 1.day.from_now)
      create(ProjectExternalSoftwareRecord, project: first, external_software_record: identifier,
        match_status: "matched", relationship: "source_code_repository")
    end

    capture_io { Rake::Task["search_seeds:export"].invoke }

    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      assert_empty db.execute("PRAGMA foreign_key_check")
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM clues WHERE value = 'star' AND case_sensitive = 0")
      assert_equal [1, 1, 1, nil], db.get_first_row("SELECT shared_name, ordinary_word, ambiguous, suggested_start_year FROM clues WHERE value = 'star'")
      candidates = db.execute("SELECT project_id, package_entry_id, suggested_start_year FROM clue_candidates WHERE clue_id = (SELECT id FROM clues WHERE value = 'star') ORDER BY project_id, package_entry_id")
      assert_equal [first.id, first.id, second.id], candidates.map(&:first)
      assert_equal [2010, 2004, nil], candidates.map(&:last)
      assert_equal [0, 1, 1], db.get_first_row("SELECT shared_name, ordinary_word, ambiguous FROM clues WHERE value = 'sage'")
      assert_equal [1, nil], db.get_first_row("SELECT shared_name, ordinary_word FROM clues WHERE value = 'climate lab'")
      assert_equal ["Climate\t Lab", "Climate\u00a0Lab"], db.execute(<<~SQL).flatten
        SELECT DISTINCT s.value FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
        JOIN clues c ON c.id = cs.clue_id WHERE c.value = 'climate lab' ORDER BY s.project_id
      SQL
      assert_equal 2, db.get_first_value("SELECT COUNT(*) FROM clues WHERE value IN ('example.org/Docs', 'example.org/docs') AND case_sensitive = 1")
      assert_equal 0, db.get_first_value("SELECT COUNT(*) FROM clues WHERE value LIKE 'https://example.org/%'")
      assert_equal ["10.1234/star"], db.execute("SELECT value FROM clues WHERE value LIKE '%10.1234/star' ORDER BY value").flatten
      assert_equal [first.id, second.id], db.execute("SELECT project_id FROM clue_candidates WHERE clue_id = (SELECT id FROM clues WHERE value = 'scr_002285') ORDER BY project_id").flatten
      assert_equal 3, db.get_first_value("SELECT COUNT(*) FROM clue_seeds WHERE clue_id = (SELECT id FROM clues WHERE value = 'scr_002285')")
      assert_equal ["ascl:2401.123", "climatetools", "https://ascl.net/2401.123", "https://zbmath.org/software/123", "q123", "swmath:123"], db.execute(<<~SQL).flatten
        SELECT DISTINCT c.value FROM clues c JOIN clue_seeds cs ON cs.clue_id = c.id
        JOIN seeds s ON s.id = cs.seed_id WHERE s.type IN ('ascl', 'biotools', 'wikidata', 'swmath') ORDER BY c.value
      SQL
      evidence = JSON.parse(db.get_first_value("SELECT identifier_evidence FROM seeds WHERE type = 'rrid' LIMIT 1"))
      assert_equal record.id, evidence.fetch("external_software_record_id")
      assert_equal "rrid", evidence.fetch("scheme")
      assert_equal [{ "source_field" => "distributions.current" }], evidence.fetch("evidence")
      assert_equal 0, db.get_first_value("SELECT COUNT(*) FROM seeds s WHERE NOT EXISTS (SELECT 1 FROM clue_seeds cs WHERE cs.seed_id = s.id)")
      assert_equal db.get_first_value("SELECT COUNT(*) FROM seeds"), db.get_first_value("SELECT COUNT(DISTINCT seed_id) FROM clue_seeds")
      assert_equal 2010, JSON.parse(db.get_first_value("SELECT search_year FROM projects WHERE project_id = ?", first.id)).fetch("suggested_start_year")
      metadata = JSON.parse(db.get_first_value("SELECT value FROM metadata WHERE key = 'literal_variants'"))
      assert_equal %w[identifier], metadata.fetch("rrid")
    end
  end

  test "export flags ordinary words and punctuation without removing names or source links" do
    project = create(Project, url: "https://github.com/clues/and", name: "AND", science_score: 50,
      packages: [{ "name" => "and", "ecosystem" => "cran" }],
      codemeta: { "alternateName" => ["Can", "based", "Fig", "Differences", "Survey", "Sample", "Patterns",
        "Method", "Content", "======", "***", "\u2026\u2014\u2026", "Δ", "目录", "123", "C++", "ClueTestName"] }.to_json)

    capture_io { Rake::Task["search_seeds:export"].invoke }

    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      %w[and can based fig differences survey sample patterns method content].each do |word|
        assert_equal [1, 0, 1], db.get_first_row(
          "SELECT ordinary_word, punctuation_only, ambiguous FROM clues WHERE value = ?", word), word
      end
      ["======", "***", "\u2026\u2014\u2026"].each do |value|
        assert_equal [0, 1, 1], db.get_first_row(
          "SELECT short_name, punctuation_only, ambiguous FROM clues WHERE value = ?", value), value
      end
      ["δ", "目录", "123", "c++", "cluetestname", "github.com/clues/and"].each do |value|
        assert_equal [nil, 0], db.get_first_row(
          "SELECT ordinary_word, punctuation_only FROM clues WHERE value = ?", value), value
      end
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM clues WHERE value = 'and'")
      assert_equal %w[project.name project.packages[0].name project.url], db.execute(<<~SQL).flatten.sort
        SELECT DISTINCT s.source FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
        JOIN clues c ON c.id = cs.clue_id WHERE c.value = 'and'
      SQL
      assert_equal [project.id], db.execute(<<~SQL).flatten
        SELECT DISTINCT project_id FROM clue_candidates
        WHERE clue_id = (SELECT id FROM clues WHERE value = 'and')
      SQL
      assert_equal 0, db.get_first_value("SELECT COUNT(*) FROM seeds s WHERE NOT EXISTS (SELECT 1 FROM clue_seeds cs WHERE cs.seed_id = s.id)")
    end
  end

  test "export records URL specificity word evidence name origins and subset collisions" do
    original = create(Project, url: "https://github.com/clues/original", name: "SharedTool", science_score: 50,
      repository: { "fork" => false, "homepage" => "https://project.example/" },
      codemeta: { "alternateName" => ["ice", "perception", "cross", "About", "ClueTestName"] }.to_json,
      packages: [{ "name" => "SharedTool", "ecosystem" => "cran" }])
    fork = create(Project, url: "https://github.com/clues/fork", name: "SharedTool", science_score: 50,
      repository: { "fork" => true, "source_name" => "clues/original", "homepage" => "https://GITHUB.com/" })
    create(Project, url: "https://github.com/clues/unassessed", name: "SharedTool", science_score: 50)
    outside = create(Project, url: "https://github.com/clues/outside", name: "SharedTool", science_score: 50)
    ENV["LIMIT"] = "3"

    capture_io { Rake::Task["search_seeds:export"].invoke }

    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      assert_equal [1, 1], db.get_first_row("SELECT non_specific_url, ambiguous FROM clues WHERE value='github.com/'")
      assert_equal 0, db.get_first_value("SELECT non_specific_url FROM clues WHERE value='project.example/'")
      %w[ice perception cross].each do |word|
        assert_equal 1, db.get_first_value("SELECT ordinary_word FROM clues WHERE value=?", word)
        evidence = JSON.parse(db.get_first_value("SELECT word_evidence FROM clues WHERE value=?", word))
        assert evidence.any? { |item| item['source'] == 'esdb' && item['language'] == 'en' && item['kind'] == 'dictionary' }
      end
      assert_nil db.get_first_value("SELECT ordinary_word FROM clues WHERE value='cluetestname'")
      assert_equal [], JSON.parse(db.get_first_value("SELECT word_evidence FROM clues WHERE value='cluetestname'"))
      assert_equal [1, 1], db.get_first_row("SELECT generic_name, ambiguous FROM clues WHERE value='about'")
      assert_equal 'unknown', JSON.parse(db.get_first_value("SELECT name_evidence FROM seeds WHERE project_id=? AND source='project.name'", original.id)).fetch('kind')
      assert_equal 'declared_metadata', JSON.parse(db.get_first_value("SELECT name_evidence FROM seeds WHERE normalized_value='about'")).fetch('kind')
      assert_equal [3, 1, 1, 1, 'exported_projects'], db.get_first_row(<<~SQL)
        SELECT project_candidates, package_candidates, fork_projects, unknown_fork_projects, count_scope
        FROM clue_candidate_summary WHERE clue_id=(SELECT id FROM clues WHERE value='sharedtool')
      SQL
      assert_equal [1, 'clues/original'], db.get_first_row(<<~SQL, fork.id)
        SELECT fork, fork_source_name FROM clue_candidate_details
        WHERE clue_id=(SELECT id FROM clues WHERE value='sharedtool') AND project_id=?
      SQL
      assert_nil db.get_first_value('SELECT project_id FROM projects WHERE project_id=?', outside.id)
      metadata = db.execute('SELECT key, value FROM metadata').to_h.transform_values { |v| JSON.parse(v) }
      assert_equal 'exported_projects', metadata.fetch('candidate_count_scope')
      assert_equal 'en', metadata.fetch('word_sources').find { |source| source['id'] == 'esdb' }.fetch('language')
      assert_includes metadata.fetch('word_sources').find { |source| source['id'] == 'esdb' }.fetch('copyright_notice'), 'Kevin Atkinson'
    end
  end

  test "URL flags respect hosting paths and preserve dedicated homepages" do
    urls = {
      'https://github.com/' => 1, 'https://GITHUB.com/owner' => 1,
      'https://github.com/search?q=owner/repo' => 1, 'https://github.com/owner/repo' => 0,
      'https://gitlab.com/group' => 1, 'https://gitlab.com/group/subgroup/repo' => 0,
      'https://codeberg.org/' => 1, 'https://bitbucket.org/team/' => 1,
      'https://project.example/' => 0, 'https://project.github.io/' => 0,
    }
    urls.each_with_index do |(url, _), i|
      create(Project, url: "https://github.com/url-test/project#{i}", science_score: 50, repository: { 'homepage' => url })
    end

    capture_io { Rake::Task['search_seeds:export'].invoke }

    SQLite3::Database.new(ENV.fetch('OUTPUT')) do |db|
      urls.each do |url, expected|
        literal = url.sub('https://', '').sub('GITHUB.com', 'github.com')
        assert_equal expected, db.get_first_value('SELECT non_specific_url FROM clues WHERE value=?', literal), url
      end
    end
  end

  test "shared clue year covers the earliest known candidate when all candidate bounds are known" do
    [2012, 2001].each_with_index do |year, index|
      create(Project, url: "https://github.com/clues/#{index}", name: "Project#{index}", science_score: 50,
        packages: [{ "name" => "SharedName", "first_release_published_at" => "#{year}-01-01T00:00:00Z" }])
    end

    capture_io { Rake::Task["search_seeds:export"].invoke }

    SQLite3::Database.new(ENV.fetch("OUTPUT")) do |db|
      assert_equal 2000, db.get_first_value("SELECT suggested_start_year FROM clues WHERE value = 'sharedname'")
      assert_equal [2000, 2011], db.execute("SELECT suggested_start_year FROM clue_candidates WHERE clue_id = (SELECT id FROM clues WHERE value = 'sharedname') ORDER BY suggested_start_year").flatten
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
