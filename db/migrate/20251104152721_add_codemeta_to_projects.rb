class AddCodemetaToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :codemeta, :text
  end
end
