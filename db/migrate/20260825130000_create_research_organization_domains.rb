class CreateResearchOrganizationDomains < ActiveRecord::Migration[8.1]
  def change
    create_table :research_organization_domains do |t|
      t.citext :domain, null: false
      t.string :source, null: false
      t.string :source_version, null: false
      t.datetime :published_at
      t.boolean :active, null: false, default: false
      t.string :external_id, null: false
      t.string :organization_name
      t.text :organization_types, null: false, default: [], array: true
      t.float :strength, null: false, default: 1.0
      t.timestamps
    end

    add_index :research_organization_domains, :domain, where: "active = true"
    add_index :research_organization_domains, [:source, :active]
    add_index :research_organization_domains,
      [:source, :source_version, :domain, :external_id],
      unique: true,
      name: "index_research_domains_on_source_version_domain_id"

    add_column :owners, :institutional_domain, :citext

    add_index :owners, :institutional_domain, where: "institutional_domain IS NOT NULL"
  end
end
