class CreateResearchOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :research_organization_imports do |t|
      t.string :source_version, null: false
      t.string :checksum, null: false
      t.jsonb :source_metadata, null: false, default: {}
      t.datetime :retrieved_at, null: false
      t.bigint :byte_offset, null: false, default: 0
      t.integer :records_processed, null: false, default: 0
      t.boolean :current, null: false, default: false
      t.datetime :completed_at
      t.string :lease_token
      t.datetime :lease_expires_at
      t.text :last_error
      t.bigint :owner_cursor, null: false, default: 0
      t.bigint :owner_upper_bound
      t.jsonb :owner_counts, null: false, default: {}
      t.datetime :backfill_completed_at
      t.timestamps
    end
    add_index :research_organization_imports, :source_version, unique: true
    add_index :research_organization_imports, :current, unique: true, where: "current = true"
    add_index :research_organization_imports, "(1)", unique: true,
      where: "completed_at IS NULL", name: "index_research_organization_imports_on_unfinished"

    create_table :research_organizations do |t|
      t.string :ror_id, null: false
      t.references :current_import, foreign_key: { to_table: :research_organization_imports }
      t.references :pending_import, foreign_key: { to_table: :research_organization_imports }
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :pending_metadata
      t.text :matching_domains, null: false, default: [], array: true
      t.text :pending_domains, null: false, default: [], array: true
      t.timestamps
    end
    add_index :research_organizations, :ror_id, unique: true
    add_index :research_organizations, :matching_domains, using: :gin

    create_table :research_organization_relationships do |t|
      t.references :research_organization_import, null: false, foreign_key: true, index: false
      t.string :ror_id, null: false
      t.string :related_ror_id, null: false
      t.string :kind, null: false
      t.timestamps
    end
    add_index :research_organization_relationships,
      [:research_organization_import_id, :ror_id, :kind, :related_ror_id], unique: true,
      name: "index_research_organization_relationships_on_identity"
    add_index :research_organization_relationships,
      [:research_organization_import_id, :related_ror_id, :kind],
      name: "index_research_organization_relationships_on_target"

    create_table :owner_research_organizations do |t|
      t.references :owner, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :research_organization, null: false, foreign_key: true
      t.string :source, null: false
      t.string :relationship, null: false, default: "repository_owner"
      t.string :match_method, null: false
      t.string :match_status, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :owner_research_organizations,
      [:owner_id, :research_organization_id, :source, :relationship], unique: true,
      name: "index_owner_research_organizations_on_identity"
  end
end
