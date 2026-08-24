class AddBriefToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :brief, :jsonb
  end
end
