class AddSoftwareDoiEnrichment < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :external_software_records, :concept_identifier, :string
    add_index :projects, :id, where: "search_identifiers ? 'doi'", algorithm: :concurrently,
      name: :index_projects_with_doi_seeds
  end
end
