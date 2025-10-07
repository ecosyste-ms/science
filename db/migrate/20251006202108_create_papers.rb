class CreatePapers < ActiveRecord::Migration[8.0]
  def change
    create_table :papers do |t|
      t.string :doi
      t.string :openalex_id
      t.string :title
      t.datetime :publication_date
      t.json :openalex_data
      t.integer :mentions_count, default: 0
      t.datetime :last_synced_at
      t.text :urls, array: true, default: []

      t.timestamps
    end

    add_index :papers, :doi
  end
end
