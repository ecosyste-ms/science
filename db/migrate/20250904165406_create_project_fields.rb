class CreateProjectFields < ActiveRecord::Migration[8.0]
  def change
    create_table :project_fields do |t|
      t.references :project, null: false, foreign_key: true
      t.references :field, null: false, foreign_key: true
      t.float :confidence_score, null: false, default: 0.0
      t.jsonb :match_signals, default: {}

      t.timestamps
    end
    
    add_index :project_fields, [:project_id, :field_id], unique: true
    add_index :project_fields, :confidence_score
  end
end
