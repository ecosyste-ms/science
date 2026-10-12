class CreatePackagePapers < ActiveRecord::Migration[8.1]
  def change
    create_table :package_papers do |t|
      t.references :package, null: false, foreign_key: true, index: false
      t.references :paper, null: false, foreign_key: true
      t.string :role, null: false
      t.jsonb :evidence, null: false, default: []
      t.timestamps
    end
    add_index :package_papers, [:package_id, :paper_id, :role], unique: true
  end
end
