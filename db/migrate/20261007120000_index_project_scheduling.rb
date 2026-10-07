class IndexProjectScheduling < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :projects, "last_synced_at ASC NULLS FIRST, id ASC",
      name: "index_projects_on_sync_schedule", algorithm: :concurrently
    add_index :projects, :id, name: "index_projects_pending_brief", algorithm: :concurrently,
      where: "repository IS NOT NULL AND (brief IS NULL OR (NOT (brief ? 'dependencies') AND NOT (brief ? 'error')))"
  end
end
