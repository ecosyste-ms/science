class AddPackageResolutionToProjectDependencies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :project_dependencies, :package_resolution_attempted_at, :datetime
    add_column :project_dependencies, :package_resolution_error, :text

    add_index :project_dependencies,
      :purl,
      where: "package_id IS NULL AND purl IS NOT NULL AND package_resolution_attempted_at IS NULL",
      algorithm: :concurrently,
      name: "index_project_dependencies_pending_purl_resolution"
    add_index :project_dependencies,
      %i[ecosystem package_name],
      where: "package_id IS NULL AND purl IS NULL AND package_resolution_attempted_at IS NULL",
      algorithm: :concurrently,
      name: "index_project_dependencies_pending_name_resolution"
  end
end
