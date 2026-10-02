class AddExternalRepositoryDiscovery < ActiveRecord::Migration[8.1]
  def change
    add_column :external_software_records, :next_discovery_at, :datetime, default: -> { "CURRENT_TIMESTAMP" }
    add_column :external_software_records, :discovered_at, :datetime
    add_column :external_software_records, :discovery_result, :jsonb, null: false, default: {}
    add_column :external_software_records, :discovery_error, :text
    add_index :external_software_records, [:next_discovery_at, :id],
      where: "status = 'ok' AND next_discovery_at IS NOT NULL", name: :index_external_records_pending_discovery

    create_table :external_project_syncs do |t|
      t.references :project, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.datetime :requested_at, null: false
      t.datetime :completed_at
      t.datetime :next_attempt_at, null: false
      t.string :lease_token
      t.datetime :lease_expires_at
      t.text :last_error
    end
    add_index :external_project_syncs, [:next_attempt_at, :id],
      where: "completed_at IS NULL OR requested_at > completed_at", name: :index_external_project_syncs_pending
  end
end
