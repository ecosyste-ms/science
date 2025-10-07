class AddHostAndOwnerToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :host_id, :integer
    add_column :projects, :owner_id, :integer

    add_index :projects, :host_id
    add_index :projects, :owner_id
  end
end
