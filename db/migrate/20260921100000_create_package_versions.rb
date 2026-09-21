class CreatePackageVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :package_versions do |t|
      t.references :package, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :release, foreign_key: { on_delete: :nullify }
      t.string :release_match_method
      t.bigint :ecosystems_id, null: false
      t.string :number, null: false
      t.datetime :published_at
      t.datetime :ecosystems_created_at
      t.datetime :ecosystems_updated_at
      t.datetime :fetched_at, null: false
      t.text :licenses
      t.text :integrity
      t.string :status
      t.boolean :immutable
      t.text :download_url
      t.text :registry_url
      t.text :documentation_url
      t.text :purl
      t.jsonb :metadata, default: {}, null: false
      t.jsonb :related_tag
      t.timestamps
    end

    add_index :package_versions, [:package_id, :ecosystems_id], unique: true
    add_index :package_versions, "package_id, lower(number)", unique: true,
      name: "index_package_versions_on_package_and_number"
    add_index :package_versions, "package_id, published_at DESC NULLS LAST, id DESC",
      name: "index_package_versions_on_package_and_date"
    add_column :packages, :version_sync_state, :jsonb, default: {}, null: false
  end
end
