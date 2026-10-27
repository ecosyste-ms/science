class IndexProjectSearchNamesAndUrls < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :projects, :name, using: :gin, opclass: :gin_trgm_ops,
      where: "science_score > 0", name: "index_projects_on_search_name", algorithm: :concurrently
    add_index :projects, :url, using: :gin, opclass: :gin_trgm_ops,
      where: "science_score > 0", name: "index_projects_on_search_url", algorithm: :concurrently
  end
end
