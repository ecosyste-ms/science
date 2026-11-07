class IndexJevRepositoryIdentity < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :jev_discoveries, "jev_run_id, (evidence #>> '{repository_identity,status}')",
      name: "index_jev_discoveries_identity", algorithm: :concurrently
  end
end
