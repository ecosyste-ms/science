class AddRepositoryFactsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :model, :boolean, default: false, null: false
    add_column :projects, :language, :string
    add_column :projects, :archived, :boolean
  end
end
