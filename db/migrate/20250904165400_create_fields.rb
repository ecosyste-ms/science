class CreateFields < ActiveRecord::Migration[8.0]
  def change
    create_table :fields do |t|
      t.string :name, null: false
      t.string :domain, null: false
      t.string :openalex_id
      t.text :description
      t.text :keywords, array: true, default: []
      t.text :packages, array: true, default: []
      t.text :indicators, array: true, default: []

      t.timestamps
    end
    
    add_index :fields, :name, unique: true
    add_index :fields, :domain
    add_index :fields, :openalex_id, unique: true
  end
end