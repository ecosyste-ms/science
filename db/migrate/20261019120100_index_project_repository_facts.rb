class IndexProjectRepositoryFacts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :projects, "last_synced_at DESC NULLS LAST, id DESC", include: :owner_id, where: "model",
      name: "index_projects_on_model_listing", algorithm: :concurrently
    add_index :projects, :language, algorithm: :concurrently
  end
end
