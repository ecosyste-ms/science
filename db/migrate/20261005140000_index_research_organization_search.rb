class IndexResearchOrganizationSearch < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :research_organizations, "((metadata -> 'names')::text) gin_trgm_ops",
      using: :gin, algorithm: :concurrently, name: "index_research_organizations_on_names"
    add_index :research_organizations,
      "jsonb_path_query_array(metadata, '$.locations[*].geonames_details.country_code')",
      using: :gin, algorithm: :concurrently, name: "index_research_organizations_on_countries"
  end
end
