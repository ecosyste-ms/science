class UniquelyIndexReleaseTags < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :releases, [:project_id, :tag_name], unique: true,
      name: "index_releases_on_unique_project_tag", algorithm: :concurrently
    remove_index :releases, name: "index_releases_on_project_id_and_tag_name", algorithm: :concurrently
  end

  def down
    add_index :releases, [:project_id, :tag_name], algorithm: :concurrently
    remove_index :releases, name: "index_releases_on_unique_project_tag", algorithm: :concurrently
  end
end
