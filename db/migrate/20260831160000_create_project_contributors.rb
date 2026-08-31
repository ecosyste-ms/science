class CreateProjectContributors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :project_contributors do |t|
      t.references :project,
        null: false,
        foreign_key: { on_delete: :cascade }
      t.references :owner,
        foreign_key: { on_delete: :nullify }
      t.string :source, null: false
      t.string :source_key, null: false
      t.text :name
      t.citext :email
      t.citext :login
      t.string :provider_uuid
      t.string :account_kind, null: false
      t.string :classification_reason
      t.bigint :contributions_count, null: false, default: 0
      t.string :source_digest, null: false
      t.jsonb :raw_data, null: false, default: {}
      t.timestamps
    end

    add_index :project_contributors,
      %i[project_id source source_key],
      unique: true,
      name: "index_project_contributors_on_source_key"
    add_index :project_contributors,
      :email,
      where: "email IS NOT NULL"
    add_index :project_contributors,
      :login,
      where: "login IS NOT NULL"
    add_index :project_contributors,
      :provider_uuid,
      where: "provider_uuid IS NOT NULL"

    add_column :projects, :contributors_indexed_at, :datetime
    add_column :projects, :contributors_index_error, :text
    add_column :projects, :contributors_index_version, :integer
    add_column :projects, :contributors_source_digest, :string

    candidate = <<~SQL.squish
      science_score >= 20 AND (
        (
          commits IS NOT NULL
          AND json_typeof(commits -> 'committers') = 'array'
        )
        OR contributors_source_digest IS NOT NULL
      )
    SQL
    add_index :projects,
      :id,
      where: "contributors_indexed_at IS NULL " \
        "AND contributors_index_error IS NULL AND (#{candidate})",
      algorithm: :concurrently,
      name: "index_projects_pending_contributors"
    add_index :projects,
      %i[contributors_index_version id],
      where: candidate,
      algorithm: :concurrently,
      name: "index_projects_on_contributor_version"
  end
end
