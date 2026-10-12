class CreateProjectPapers < ActiveRecord::Migration[8.1]
  def change
    create_table :project_papers do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.references :paper, null: false, foreign_key: true
      t.jsonb :evidence, null: false, default: []
      t.timestamps
    end
    add_index :project_papers, [:project_id, :paper_id], unique: true
    add_index :papers, "lower(openalex_id)",
      where: "openalex_id IS NOT NULL", name: "index_papers_on_lower_openalex_id"
  end
end
