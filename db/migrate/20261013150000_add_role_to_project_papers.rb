class AddRoleToProjectPapers < ActiveRecord::Migration[8.1]
  def change
    add_column :project_papers, :role, :string, null: false, default: "implementation"
  end
end
