class AddSoftwareSearchToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    enable_extension "pg_trgm"
    add_column :projects, :search_identifiers, :jsonb
    add_column :projects, :search_names, :text
    add_column :projects, :search_indexed_at, :datetime
    add_index :projects, :search_identifiers, using: :gin, opclass: :jsonb_path_ops,
      algorithm: :concurrently
    add_index :projects, :search_names, using: :gin, opclass: :gin_trgm_ops,
      algorithm: :concurrently
  end
end
