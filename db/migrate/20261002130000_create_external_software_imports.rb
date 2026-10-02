class CreateExternalSoftwareImports < ActiveRecord::Migration[8.1]
  def change
    create_table :external_software_imports do |t|
      t.string :source, null: false
      t.string :cursor
      t.integer :page_size, null: false, default: 100
      t.jsonb :pending_ids, null: false, default: []
      t.integer :pages_processed, null: false, default: 0
      t.integer :items_processed, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :next_run_at, null: false
      t.string :lease_token
      t.datetime :lease_expires_at
      t.text :last_error
      t.timestamps
    end
    add_index :external_software_imports, :source, unique: true
  end
end
