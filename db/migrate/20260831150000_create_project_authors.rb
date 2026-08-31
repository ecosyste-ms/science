class CreateProjectAuthors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :project_authors do |t|
      t.references :project,
        null: false,
        foreign_key: { on_delete: :cascade }
      t.string :source, null: false
      t.string :authorship_kind, null: false
      t.string :author_kind, null: false
      t.integer :position, null: false
      t.text :display_name
      t.text :given_names
      t.text :family_names
      t.citext :email
      t.string :orcid
      t.text :affiliation
      t.string :source_path, null: false
      t.string :source_digest, null: false
      t.jsonb :raw_data, null: false, default: {}
      t.timestamps
    end

    add_index :project_authors,
      %i[project_id source authorship_kind position],
      unique: true,
      name: "index_project_authors_on_snapshot_position"
    add_index :project_authors,
      :email,
      where: "email IS NOT NULL"
    add_index :project_authors,
      :orcid,
      where: "orcid IS NOT NULL"

    add_column :projects, :citation_authors_indexed_at, :datetime
    add_column :projects, :citation_authors_index_error, :text
    add_column :projects, :citation_authors_index_version, :integer
    add_column :projects, :citation_authors_source_digest, :string

    candidate = <<~SQL.squish
      science_score >= 20 AND (
        citation_file ~ '^[[:space:]]*cff-version:'
        OR citation_authors_source_digest IS NOT NULL
      )
    SQL
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
end
