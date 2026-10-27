class IndexExternalProjectSyncRetries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :external_project_syncs, [:next_attempt_at, :id],
      where: "(completed_at IS NULL OR requested_at > completed_at) AND last_error IS NOT NULL",
      name: "index_external_project_syncs_retries", algorithm: :concurrently
  end
end
