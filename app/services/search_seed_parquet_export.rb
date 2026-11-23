require "tmpdir"

class SearchSeedParquetExport
  QUERIES = {
    clues: <<~SQL,
      SELECT id, value, case_sensitive, ambiguous, shared_name, ordinary_word, short_name,
             punctuation_only, non_specific_url, generic_name, word_evidence, suggested_start_year
      FROM clues
    SQL
    candidates: <<~SQL,
      SELECT clue_id, project_id, repository_url, package_entry_id, package_id, purl,
             suggested_start_year, search_year, fork, fork_source_name, mirror_url
      FROM clue_candidate_details
    SQL
    provenance: <<~SQL,
      SELECT cs.clue_id, s.id AS seed_id, cs.variant, s.project_id, s.package_entry_id,
             s.type, s.value, s.normalized_value, s.source, s.relation, s.name_evidence, s.identifier_evidence
      FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
    SQL
  }.freeze
  INTEGERS = %w[id clue_id project_id package_entry_id package_id seed_id case_sensitive ambiguous
                shared_name ordinary_word short_name punctuation_only non_specific_url generic_name
                suggested_start_year fork].freeze

  def initialize(output: nil, limit: nil, progress: nil)
    @output = File.expand_path(output.presence || Rails.root.join("tmp", "clues-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}"))
    @limit = limit
    @progress = progress
  end

  def export
    require "sqlite3"
    require "parquet"

    raise Errno::EEXIST, @output if File.exist?(@output) || File.symlink?(@output)

    parent = File.dirname(@output)
    FileUtils.mkdir_p(parent)
    Dir.mktmpdir(".clue-export-", parent) do |work|
      snapshot = File.join(work, "seeds.sqlite3")
      SearchSeedExport.new(limit: @limit, progress: @progress).write_database(snapshot)
      directory = File.join(work, "dataset")
      Dir.mkdir(directory)
      SQLite3::Database.new(snapshot, readonly: true) do |db|
        manifest = write_dataset(db, directory)
        File.rename(directory, @output)
        return { output: @output, snapshot_id: manifest.fetch("snapshot_id"), files: manifest.fetch("files") }
      end
    end
  end

  def write_dataset(db, directory)
    files = QUERIES.to_h do |name, query|
      filename = "#{name}.parquet"
      path = File.join(directory, filename)
      # Replacing a private staging file uses rename even on filesystems without hard links.
      FileUtils.touch(path)
      db.prepare(query) do |statement|
        schema = statement.columns.map { |column| { column => INTEGERS.include?(column) ? "int64" : "string" } }
        Parquet.write_rows(statement.enum_for(:each), schema: schema, write_to: path,
          batch_size: 4096, compression: "zstd")
      end
      [filename, Parquet.metadata(path).fetch("num_rows")]
    end
    metadata = db.execute("SELECT key, value FROM metadata").to_h.transform_values { |value| JSON.parse(value) }
    metadata["files"] = files
    File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(metadata))
    metadata
  end
end
