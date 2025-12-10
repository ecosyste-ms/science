class AddZenodoToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :zenodo, :text
  end
end
