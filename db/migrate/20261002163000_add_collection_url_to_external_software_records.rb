class AddCollectionUrlToExternalSoftwareRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :external_software_records, :collection_url, :string
  end
end
