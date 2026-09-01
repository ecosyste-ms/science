class CreateJossPublicationAuthors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :mention_sources do |t|
      t.references :mention,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.string :source, null: false
      t.string :source_identifier, null: false
      t.string :source_digest, null: false
      t.jsonb :raw_data, null: false, default: {}
      t.timestamps
    end
    add_index :mention_sources,
      %i[mention_id source],
      unique: true
    add_index :mention_sources,
      %i[source source_identifier],
      unique: true

    create_table :paper_authors do |t|
      t.references :paper,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :author,
        foreign_key: { on_delete: :nullify },
        index: false
      t.string :source, null: false
      t.string :role, null: false
      t.integer :position, null: false
      t.text :display_name
      t.text :given_names
      t.text :family_names
      t.citext :email
      t.string :orcid
      t.text :affiliation
      t.string :source_path, null: false
      t.string :source_digest, null: false
      t.string :author_match_kind
      t.jsonb :raw_data, null: false, default: {}
      t.timestamps
    end
    add_index :paper_authors,
      %i[paper_id source role position],
      unique: true,
      name: "index_paper_authors_on_snapshot_position"
    add_index :paper_authors,
      %i[author_id paper_id role],
      where: "author_id IS NOT NULL"
    add_index :paper_authors,
      :orcid,
      where: "orcid IS NOT NULL"
    add_index :paper_authors,
      :email,
      where: "email IS NOT NULL"

    add_column :projects, :joss_publication_indexed_at, :datetime
    add_column :projects, :joss_publication_index_error, :text
    add_column :projects, :joss_publication_index_version, :integer
    add_column :projects, :joss_publication_source_digest, :string
    add_column :mentions, :created_by_source, :string

    candidate = <<~SQL.squish
      joss_metadata IS NOT NULL
      OR joss_publication_source_digest IS NOT NULL
    SQL
    add_index :projects,
      :id,
      where: "joss_publication_indexed_at IS NULL " \
        "AND joss_publication_index_error IS NULL AND (#{candidate})",
      algorithm: :concurrently,
      name: "index_projects_pending_joss_publications"
    add_index :projects,
      %i[joss_publication_index_version id],
      where: candidate,
      algorithm: :concurrently,
      name: "index_projects_on_joss_publication_version"

    add_index :mentions,
      %i[paper_id project_id],
      algorithm: :concurrently,
      name: "index_mentions_on_paper_and_project"
    remove_index :mentions,
      name: "index_mentions_on_paper_id",
      algorithm: :concurrently
    add_index :papers,
      "LOWER(doi)",
      where: "doi IS NOT NULL",
      algorithm: :concurrently,
      name: "index_papers_on_lower_doi"

    remove_index :projects,
      name: "index_projects_pending_author_identities",
      algorithm: :concurrently
    remove_index :projects,
      name: "index_projects_on_author_identity_version",
      algorithm: :concurrently
    identity_candidate = <<~SQL.squish
      science_score >= 20 AND (
        citation_authors_source_digest IS NOT NULL
        OR contributors_source_digest IS NOT NULL
        OR joss_publication_source_digest IS NOT NULL
        OR author_identities_source_digest IS NOT NULL
      )
    SQL
    add_index :projects,
      :id,
      where: "author_identities_indexed_at IS NULL " \
        "AND author_identities_index_error IS NULL AND (#{identity_candidate})",
      algorithm: :concurrently,
      name: "index_projects_pending_author_identities"
    add_index :projects,
      %i[author_identities_index_version id],
      where: identity_candidate,
      algorithm: :concurrently,
      name: "index_projects_on_author_identity_version"
  end

  def down
    remove_index :projects,
      name: "index_projects_pending_author_identities",
      algorithm: :concurrently,
      if_exists: true
    remove_index :projects,
      name: "index_projects_on_author_identity_version",
      algorithm: :concurrently,
      if_exists: true

    old_identity_candidate = <<~SQL.squish
      science_score >= 20 AND (
        citation_authors_source_digest IS NOT NULL
        OR contributors_source_digest IS NOT NULL
        OR author_identities_source_digest IS NOT NULL
      )
    SQL
    add_index :projects,
      :id,
      where: "author_identities_indexed_at IS NULL " \
        "AND author_identities_index_error IS NULL AND (#{old_identity_candidate})",
      algorithm: :concurrently,
      if_not_exists: true,
      name: "index_projects_pending_author_identities"
    add_index :projects,
      %i[author_identities_index_version id],
      where: old_identity_candidate,
      algorithm: :concurrently,
      if_not_exists: true,
      name: "index_projects_on_author_identity_version"

    remove_index :papers,
      name: "index_papers_on_lower_doi",
      algorithm: :concurrently,
      if_exists: true
    add_index :mentions,
      :paper_id,
      algorithm: :concurrently,
      if_not_exists: true,
      name: "index_mentions_on_paper_id"
    remove_index :mentions,
      name: "index_mentions_on_paper_and_project",
      algorithm: :concurrently,
      if_exists: true

    remove_index :projects,
      name: "index_projects_on_joss_publication_version",
      algorithm: :concurrently,
      if_exists: true
    remove_index :projects,
      name: "index_projects_pending_joss_publications",
      algorithm: :concurrently,
      if_exists: true

    remove_column :mentions, :created_by_source if column_exists?(
      :mentions,
      :created_by_source
    )
    remove_column :projects, :joss_publication_source_digest if column_exists?(
      :projects,
      :joss_publication_source_digest
    )
    remove_column :projects, :joss_publication_index_version if column_exists?(
      :projects,
      :joss_publication_index_version
    )
    remove_column :projects, :joss_publication_index_error if column_exists?(
      :projects,
      :joss_publication_index_error
    )
    remove_column :projects, :joss_publication_indexed_at if column_exists?(
      :projects,
      :joss_publication_indexed_at
    )

    drop_table :paper_authors, if_exists: true
    drop_table :mention_sources, if_exists: true
  end
end
