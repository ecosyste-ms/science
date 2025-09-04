class AddJossMetadataToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :joss_metadata, :json
  end
end
