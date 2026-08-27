class AddProjectSyncLookupIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :contributors, :email, algorithm: :concurrently
    add_index :releases, [:project_id, :uuid], algorithm: :concurrently
  end
end
