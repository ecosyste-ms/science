class CreateCatalogueAdmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :catalogue_admissions do |t|
      t.references :project, index: { unique: true }, foreign_key: { on_delete: :nullify }
      t.references :source_discovery, foreign_key: { to_table: :jev_discoveries, on_delete: :nullify }
      t.string :repository_url, null: false
      t.string :decision, null: false
      t.text :reason, null: false
      t.string :reviewed_by, null: false
      t.datetime :reviewed_at, null: false
      t.jsonb :evidence, default: {}, null: false
      t.jsonb :history, default: [], null: false
      t.timestamps
    end
    add_index :catalogue_admissions, [:decision, :project_id]
  end
end
