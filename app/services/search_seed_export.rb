require "digest"
require "fileutils"
require "tempfile"

class SearchSeedExport
  SCHEMA_VERSION = 2
  BATCH_SIZE = 250
  COLUMNS = {
    projects: %i[project_id repository_url science_score updated_at last_synced_at],
    packages: %i[project_id package_id purl registry ecosystem],
    seeds: %i[project_id package_entry_id type value normalized_value source relation],
    project_fields: %i[project_id openalex_id name domain confidence_score],
    project_contexts: %i[project_id data],
  }.freeze

  attr_reader :output, :limit, :batch_size, :progress, :database, :statements

  def initialize(output: nil, limit: nil, batch_size: BATCH_SIZE, progress: nil)
    @output = File.expand_path(output.presence || Rails.root.join(
      "tmp", "search-seeds-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.sqlite3"
    ))
    @limit = positive_integer(limit, "LIMIT") if limit.present?
    @batch_size = positive_integer(batch_size, "batch size")
    @progress = progress
    @statements = {}
  end

  def export
    require "sqlite3"

    raise Errno::EEXIST, output if File.exist?(output) || File.symlink?(output)

    FileUtils.mkdir_p(File.dirname(output))
    Tempfile.create([".search-seeds-", ".sqlite3"], File.dirname(output)) do |file|
      write_database(file.path)
      File.link(file.path, output)
    end
    { output: output, snapshot_id: @snapshot_id, counts: @counts }
  end

  def write_database(path)
    @database = SQLite3::Database.new(path)
    database.execute_batch(File.read(Rails.root.join("db/search_seeds.sql")))
    prepare_statements
    @snapshot_id = SecureRandom.uuid
    database.transaction do
      write_metadata("schema_version", SCHEMA_VERSION)
      write_metadata("snapshot_id", @snapshot_id)
      write_metadata("started_at", Time.current.utc.iso8601(6))
      write_metadata("selection", {
        visible: true,
        minimum_science_score: Project::SCIENCE_SCORE_THRESHOLD,
        order: "project_id ASC",
        limit: limit,
      })
      write_metadata("extractor_sha256", Digest::SHA256.file(
        Rails.root.join("app/services/project_search_seeds.rb")
      ).hexdigest)
      write_metadata("context_extractor_sha256", Digest::SHA256.file(
        Rails.root.join("app/services/project_search_context.rb")
      ).hexdigest)
      write_metadata("package_extractor_sha256", Digest::SHA256.file(
        Rails.root.join("app/services/project_package_entries.rb")
      ).hexdigest)
      write_metadata("source_isolation", "repeatable_read, read_only")
      export_projects
      @counts = coverage_counts
      write_metadata("counts", @counts)
      write_metadata("completed_at", Time.current.utc.iso8601(6))
    end
    database.execute("ANALYZE")
    raise "SQLite integrity check failed" unless database.get_first_value("PRAGMA quick_check") == "ok"
    raise "SQLite foreign key check failed" if database.execute("PRAGMA foreign_key_check").any?
  ensure
    statements.each_value(&:close)
    @statements = {}
    database&.close
  end

  def export_projects
    Project.transaction(isolation: :repeatable_read) do
      Project.connection.execute("SET TRANSACTION READ ONLY")
      Project.uncached do
        scope = ProjectSearchSeeds.scope.select(*ProjectSearchContext::PROJECT_COLUMNS)
          .reorder(nil).preload(:direct_project_dependencies, project_fields: :field)
        scope = scope.limit(limit) if limit
        count = 0
        scope.find_in_batches(batch_size: batch_size) do |projects|
          projects.each { |project| write_project(project) }
          count += projects.length
          progress&.call("Exported #{count} projects")
        end
      end
    end
  end

  def write_project(project)
    record = ProjectSearchSeeds.new(project).as_json
    insert(:projects, record)
    insert(:project_contexts, project_id: project.id, data: ProjectSearchContext.new(project).to_json)
    record.fetch(:seeds).each do |seed|
      insert(:seeds, seed.merge(project_id: project.id, package_entry_id: nil))
    end
    record.fetch(:packages).each do |package|
      insert(:packages, package.merge(project_id: project.id))
      package_entry_id = database.last_insert_row_id
      package.fetch(:seeds).each do |seed|
        insert(:seeds, seed.merge(project_id: project.id, package_entry_id: package_entry_id))
      end
    end
    project.project_fields.each do |assignment|
      field = assignment.field
      next if field.openalex_id.blank?

      insert(:project_fields, {
        project_id: project.id, openalex_id: field.openalex_id,
        name: field.name, domain: field.domain, confidence_score: assignment.confidence_score,
      })
    end
  end

  def prepare_statements
    COLUMNS.each do |table, columns|
      statements[table] = database.prepare(
        "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{(['?'] * columns.length).join(', ')})"
      )
    end
  end

  def insert(table, record)
    values = COLUMNS.fetch(table).map do |column|
      value = record.fetch(column)
      value.respond_to?(:iso8601) ? value.iso8601(6) : value
    end
    statements.fetch(table).execute(*values)
  end

  def write_metadata(key, value)
    database.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", [key, JSON.generate(value)])
  end

  def coverage_counts
    {
      projects: database.get_first_value("SELECT COUNT(*) FROM projects"),
      package_entries: database.get_first_value("SELECT COUNT(*) FROM packages"),
      seeds: database.get_first_value("SELECT COUNT(*) FROM seeds"),
      projects_without_packages: database.get_first_value(<<~SQL),
        SELECT COUNT(*) FROM projects p
        WHERE NOT EXISTS (SELECT 1 FROM packages WHERE project_id = p.project_id)
      SQL
      projects_without_dois: database.get_first_value(<<~SQL),
        SELECT COUNT(*) FROM projects p
        WHERE NOT EXISTS (SELECT 1 FROM seeds WHERE project_id = p.project_id AND type = 'doi')
      SQL
      projects_without_fields: database.get_first_value(<<~SQL),
        SELECT COUNT(*) FROM projects p
        WHERE NOT EXISTS (SELECT 1 FROM project_fields WHERE project_id = p.project_id)
      SQL
      package_entries_without_package_id: database.get_first_value("SELECT COUNT(*) FROM packages WHERE package_id IS NULL"),
      package_entries_without_purl: database.get_first_value("SELECT COUNT(*) FROM packages WHERE purl IS NULL"),
      shared_names: database.get_first_value("SELECT COUNT(*) FROM name_collisions"),
    }
  end

  def positive_integer(value, name)
    number = Integer(value, exception: false)
    raise ArgumentError, "#{name} must be a positive integer" unless number&.positive?

    number
  end
end
