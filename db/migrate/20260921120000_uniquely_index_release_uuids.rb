class UniquelyIndexReleaseUuids < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :releases, [:project_id, :uuid], unique: true,
      where: "uuid IS NOT NULL AND uuid <> ''",
      name: "index_releases_on_unique_project_uuid", algorithm: :concurrently
    remove_index :releases, name: "index_releases_on_project_id_and_uuid", algorithm: :concurrently
  end

  def down
    add_index :releases, [:project_id, :uuid], algorithm: :concurrently
    remove_index :releases, name: "index_releases_on_unique_project_uuid", algorithm: :concurrently
  end
end
