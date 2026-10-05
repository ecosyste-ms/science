class IndexResearchOrganizationLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :research_organizations, "((metadata -> 'links')::text) gin_trgm_ops",
      using: :gin, algorithm: :concurrently, name: "index_research_organizations_on_links"
  end
end
