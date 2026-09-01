class CreateAuthorsAndDeveloperAccounts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :authors do |t|
      t.citext :canonical_key, null: false
      t.text :display_name
      t.timestamps
    end
    add_index :authors, :canonical_key, unique: true

    create_table :author_identifiers do |t|
      t.references :author,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.string :scheme, null: false
      t.citext :value, null: false
      t.boolean :publicly_visible, null: false, default: false
      t.timestamps
    end
    add_index :author_identifiers,
      %i[scheme value],
      unique: true
    add_index :author_identifiers,
      %i[author_id scheme value],
      name: "index_author_identifiers_on_author_and_value"

    create_table :developer_accounts do |t|
      t.references :host,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :owner,
        foreign_key: { on_delete: :nullify },
        index: false
      t.citext :canonical_key, null: false
      t.string :provider_uuid
      t.citext :login
      t.text :name
      t.citext :email
      t.string :account_kind, null: false
      t.timestamps
    end
    add_index :developer_accounts, :canonical_key, unique: true
    add_index :developer_accounts, %i[host_id login],
      where: "login IS NOT NULL"
    add_index :developer_accounts, :owner_id,
      unique: true,
      where: "owner_id IS NOT NULL"

    create_table :developer_account_identifiers do |t|
      t.references :developer_account,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :host,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.string :scheme, null: false
      t.citext :value, null: false
      t.timestamps
    end
    add_index :developer_account_identifiers,
      %i[host_id scheme value],
      unique: true,
      name: "index_developer_account_identifiers_on_host_and_value"
    add_index :developer_account_identifiers,
      %i[developer_account_id scheme value],
      name: "index_developer_account_identifiers_on_account_and_value"

    add_reference :project_authors, :author, index: false
    add_column :project_authors, :author_match_kind, :string
    add_foreign_key :project_authors, :authors,
      on_delete: :nullify,
      validate: false
    validate_foreign_key :project_authors, :authors
    add_index :project_authors,
      %i[author_id project_id],
      where: "author_id IS NOT NULL",
      algorithm: :concurrently

    add_reference :project_contributors, :author, index: false
    add_reference :project_contributors, :developer_account, index: false
    add_column :project_contributors, :author_match_kind, :string
    add_column :project_contributors, :developer_account_match_kind, :string
    add_foreign_key :project_contributors, :authors,
      on_delete: :nullify,
      validate: false
    add_foreign_key :project_contributors, :developer_accounts,
      on_delete: :nullify,
      validate: false
    validate_foreign_key :project_contributors, :authors
    validate_foreign_key :project_contributors, :developer_accounts
    add_index :project_contributors,
      %i[author_id project_id],
      where: "author_id IS NOT NULL",
      algorithm: :concurrently
    add_index :project_contributors,
      %i[developer_account_id project_id],
      where: "developer_account_id IS NOT NULL",
      algorithm: :concurrently,
      name: "index_project_contributors_on_account_and_project"

    create_table :author_developer_account_links do |t|
      t.references :author,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :developer_account,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :project,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :project_author,
        foreign_key: { on_delete: :cascade },
        index: false
      t.references :project_contributor,
        foreign_key: { on_delete: :cascade },
        index: false
      t.string :source, null: false
      t.string :source_key, null: false
      t.string :matching_method, null: false
      t.boolean :deterministic, null: false, default: true
      t.decimal :confidence, precision: 6, scale: 5
      t.string :source_digest, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :author_developer_account_links,
      %i[source source_key],
      unique: true,
      name: "index_author_account_links_on_source_key"
    add_index :author_developer_account_links,
      %i[author_id developer_account_id]
    add_index :author_developer_account_links,
      %i[developer_account_id author_id],
      name: "index_author_account_links_on_account_and_author"
    add_index :author_developer_account_links,
      %i[project_id source],
      where: "project_id IS NOT NULL"

    add_column :projects, :author_identities_indexed_at, :datetime
    add_column :projects, :author_identities_index_error, :text
    add_column :projects, :author_identities_index_version, :integer
    add_column :projects, :author_identities_source_digest, :string

    candidate = <<~SQL.squish
      science_score >= 20 AND (
        citation_authors_source_digest IS NOT NULL
        OR contributors_source_digest IS NOT NULL
        OR author_identities_source_digest IS NOT NULL
      )
    SQL
    add_index :projects,
      :id,
      where: "author_identities_indexed_at IS NULL " \
        "AND author_identities_index_error IS NULL AND (#{candidate})",
      algorithm: :concurrently,
      name: "index_projects_pending_author_identities"
    add_index :projects,
      %i[author_identities_index_version id],
      where: candidate,
      algorithm: :concurrently,
      name: "index_projects_on_author_identity_version"
  end
end
