class AddPendingRecordsToExternalSoftwareImports < ActiveRecord::Migration[8.1]
  def change
    add_column :external_software_imports, :pending_records, :jsonb, null: false, default: []
    add_column :external_software_imports, :pending_next_cursor, :string
    add_column :external_software_imports, :page_retrieved_at, :datetime
  end
end
