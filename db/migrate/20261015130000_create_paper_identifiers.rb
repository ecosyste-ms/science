class CreatePaperIdentifiers < ActiveRecord::Migration[8.1]
  def change
    create_table :paper_identifiers do |t|
      t.references :paper, null: false, foreign_key: true
      t.string :source, null: false
      t.string :identifier, null: false
      t.timestamps
    end
    add_index :paper_identifiers, [:source, :identifier], unique: true
  end
end
