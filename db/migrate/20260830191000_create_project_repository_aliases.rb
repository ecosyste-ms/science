class CreateProjectRepositoryAliases < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :project_repository_aliases do |t|
      t.references :project, null: false, foreign_key: true
      t.citext :url, null: false
      t.timestamps
    end

    add_index :project_repository_aliases,
      %i[project_id url],
      unique: true,
      name: "index_project_repository_aliases_on_project_and_url"
    add_index :project_repository_aliases, :url

    add_column :projects, :repository_aliases_indexed_at, :datetime
    add_column :projects, :repository_aliases_index_error, :text
    add_index :projects,
      :id,
      where: "repository IS NOT NULL AND repository_aliases_indexed_at IS NULL",
      algorithm: :concurrently,
      name: "index_projects_pending_repository_aliases"
  end
end
