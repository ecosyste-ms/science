class AddPublicEvidenceCountToAuthors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :authors,
      :public_evidence_count,
      :integer,
      null: false,
      default: 0
    add_index :authors,
      "LOWER(COALESCE(NULLIF(BTRIM(display_name), ''), canonical_key::text)), id",
      where: "public_evidence_count > 0",
      algorithm: :concurrently,
      name: "index_authors_on_public_alphabetical"
  end
end
