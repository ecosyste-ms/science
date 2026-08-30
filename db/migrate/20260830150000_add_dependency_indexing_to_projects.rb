class AddDependencyIndexingToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :projects, :dependencies_indexed_at, :datetime
    add_column :projects, :dependencies_index_error, :text

    add_index :projects,
      :id,
      where: "(dependencies IS NOT NULL OR brief ? 'dependencies') AND dependencies_indexed_at IS NULL AND dependencies_index_error IS NULL",
      algorithm: :concurrently,
      name: "index_projects_pending_dependency_index"
  end
end
