class IndexFailedProjectDependencyIdentities < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :project_dependencies,
      :purl,
      where: "package_id IS NULL AND purl IS NOT NULL AND package_resolution_error IS NOT NULL",
      algorithm: :concurrently,
      name: "index_project_dependencies_failed_purl_resolution"
    add_index :project_dependencies,
      %i[ecosystem package_name],
      where: "package_id IS NULL AND purl IS NULL AND package_resolution_error IS NOT NULL",
      algorithm: :concurrently,
      name: "index_project_dependencies_failed_name_resolution"
  end
end
