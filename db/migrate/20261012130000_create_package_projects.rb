class CreatePackageProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :package_projects do |t|
      t.references :package, null: false, foreign_key: true, index: false
      t.references :project, null: false, foreign_key: true
      t.string :role, null: false
      t.jsonb :evidence, null: false, default: []
      t.timestamps
    end
    add_index :package_projects, [:package_id, :project_id, :role], unique: true
  end
end
