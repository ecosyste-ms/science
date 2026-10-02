class CreateExternalSoftwareRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :external_software_records do |t|
      t.string :source, null: false
      t.string :identifier, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :metadata, null: false, default: {}
      t.datetime :retrieved_at
      t.datetime :attempted_at
      t.datetime :next_refresh_at, null: false
      t.text :last_error
      t.timestamps
    end
    add_index :external_software_records, [:source, :identifier], unique: true
    add_index :external_software_records, [:source, :next_refresh_at, :id], name: "index_external_software_records_on_refresh"

    create_table :project_external_software_records do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :external_software_record, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :relationship, null: false
      t.string :match_status, null: false
      t.jsonb :evidence, null: false, default: []
      t.timestamps
    end
    add_index :project_external_software_records, [:project_id, :id], name: "index_project_external_records_on_project"
    add_index :project_external_software_records, [:external_software_record_id, :project_id], unique: true,
      name: "index_project_external_records_on_record_and_project"
  end
end
