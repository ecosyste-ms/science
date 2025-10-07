class CreateOwners < ActiveRecord::Migration[8.0]
  def change
    create_table :owners do |t|
      t.integer :host_id
      t.string :login
      t.string :name
      t.string :uuid
      t.string :kind
      t.string :description
      t.string :email
      t.string :website
      t.string :location
      t.string :twitter
      t.string :company
      t.string :icon_url
      t.integer :repositories_count, default: 0
      t.datetime :last_synced_at
      t.json :metadata, default: {}
      t.bigint :total_stars
      t.integer :followers
      t.integer :following
      t.boolean :hidden

      t.timestamps
    end

    add_index :owners, "host_id, lower((login)::text)", name: "index_owners_on_host_id_lower_login", unique: true
    add_index :owners, [:host_id, :uuid], name: "index_owners_on_host_id_uuid", unique: true
    add_index :owners, :last_synced_at
  end
end
