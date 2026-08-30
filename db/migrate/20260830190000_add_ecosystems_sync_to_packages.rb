class AddEcosystemsSyncToPackages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :packages, :ecosystems_sync_status, :string
    add_column :packages, :ecosystems_checked_at, :datetime
    add_column :packages, :ecosystems_retry_at, :datetime
    add_column :packages, :ecosystems_sync_started_at, :datetime
    add_column :packages, :ecosystems_miss_count, :integer, null: false, default: 0
    add_column :packages, :ecosystems_error_count, :integer, null: false, default: 0
    add_column :packages, :ecosystems_error, :text
    add_column :packages, :repository_match_error, :text

    add_index :packages,
      :ecosystems_checked_at,
      where: "ecosystems_checked_at IS NULL",
      algorithm: :concurrently,
      name: "index_packages_pending_ecosystems_sync"
    add_index :packages,
      :ecosystems_retry_at,
      where: "ecosystems_retry_at IS NOT NULL",
      algorithm: :concurrently
    add_index :packages,
      :ecosystems_sync_started_at,
      where: "ecosystems_sync_started_at IS NOT NULL",
      algorithm: :concurrently
  end
end
