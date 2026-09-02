class ExpandCffCandidateIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    replace_indexes(expanded_candidate)
  end

  def down
    replace_indexes(original_candidate)
  end

  def replace_indexes(candidate)
    remove_index :projects,
      name: "index_projects_pending_citation_authors",
      algorithm: :concurrently
    remove_index :projects,
      name: "index_projects_on_citation_author_version",
      algorithm: :concurrently

    add_index :projects,
      :id,
      where: "citation_authors_indexed_at IS NULL " \
        "AND citation_authors_index_error IS NULL AND (#{candidate})",
      algorithm: :concurrently,
      name: "index_projects_pending_citation_authors"
    add_index :projects,
      %i[citation_authors_index_version id],
      where: candidate,
      algorithm: :concurrently,
      name: "index_projects_on_citation_author_version"
  end

  def expanded_candidate
    <<~SQL.squish
      science_score >= 20 AND (
        citation_file ~ '^[[:space:]]*cff-version:'
        OR (
          NULLIF(citation_file, '') IS NOT NULL
          AND (repository #>> '{metadata,files,citation}') ~* '[.]cff$'
        )
        OR citation_authors_source_digest IS NOT NULL
      )
    SQL
  end

  def original_candidate
    <<~SQL.squish
      science_score >= 20 AND (
        citation_file ~ '^[[:space:]]*cff-version:'
        OR citation_authors_source_digest IS NOT NULL
      )
    SQL
  end
end
