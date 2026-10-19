class MakePaperIdentifierIndexesNonPartial < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The planner only uses expression statistics from non-partial indexes; without
  # them it estimates ~0.5% of rows per identifier and picks seq scans under LIMIT.
  def change
    remove_index :papers, "lower((doi)::text)", name: "index_papers_on_lower_doi",
      where: "doi IS NOT NULL", algorithm: :concurrently
    add_index :papers, "lower((doi)::text)", name: "index_papers_on_lower_doi", algorithm: :concurrently

    remove_index :papers, "lower((openalex_id)::text)", name: "index_papers_on_lower_openalex_id",
      where: "openalex_id IS NOT NULL", algorithm: :concurrently
    add_index :papers, "lower((openalex_id)::text)", name: "index_papers_on_lower_openalex_id", algorithm: :concurrently

    reversible { |direction| direction.up { execute "ANALYZE papers" } }
  end
end
